import fs from "node:fs/promises";
import { constants as fsConstants, createReadStream, watch } from "node:fs";
import http from "node:http";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  WORKSPACE_DIRS,
  fileKind,
  joinWorkspacePath,
  resolveWorkspacePath,
  rootPathFromKey
} from "./lib/path-utils.mjs";
import {
  acceptWebSocket,
  createFrameDecoder,
  encodeWebSocketFrame
} from "./lib/websocket-utils.mjs";
import {
  createWorkspaceAgentEngine,
  ensureAgentWorkspaceState
} from "./lib/agent-engine.mjs";
import { buildWorkspaceContext } from "./lib/context-router.mjs";
import { buildIndex, readFileMetadata, readIndex } from "./lib/file-index.mjs";
import { renderCodeDocument, renderMarkdownDocument } from "./lib/render-service.mjs";
import { buildSearchIndex, globalSearch, searchStatus, searchWorkspace, updateSearchIndex } from "./lib/search-service.mjs";
import {
  annotationsPathForDocument,
  contentScopedAnnotationsPathForDocument,
  documentFolderAnnotationsPathForDocument,
  documentStateDirectory,
  ensureDocumentStateManifest,
  legacyAnnotationsPathForDocument,
  normalizePdfBinaryTextLayer,
  removeDocumentIngestCacheFiles
} from "./lib/document-ingest.mjs";
import { readAuditSummary } from "./lib/runtime/audit-log.mjs";
import {
  finishDocumentJob,
  listDocumentJobs,
  startDocumentJob,
  updateDocumentJob
} from "./lib/document-jobs.mjs";
import { createCodmesPdfPackage, readCodmesPdfPackage } from "./lib/codmes-pdf-package.mjs";
import { pdfThumbnailCacheFileName } from "./lib/pdf-thumbnail.mjs";
import {
  BUILTIN_PROVIDERS,
  listCredentialStatus,
  listProviderCredentialEntries,
  listProviderRegistry,
  providerBaseUrlKeys,
  providerEnvKeys,
  readCredentials,
  readRuntimeConfig,
  getMcpCredentialStatus,
  normalizeMcpServerConfig,
  removeProviderCredentialEntry,
  removeCredentialValue,
  selectProviderCredentialEntry,
  setCredentialValue,
  setDefaultModel,
  writeRuntimeConfig
} from "./lib/runtime/config-store.mjs";
import { readSecurityConfig, writeSecurityConfig } from "./lib/runtime/security-policy.mjs";
import { enableSkill, listSkills, readSkill } from "./lib/runtime/skill-registry.mjs";
import {
  cancelCodexOAuthLogin,
  discoverCodexModelIds,
  readCodexOAuthLogin,
  startCodexOAuthLogin
} from "./lib/runtime/codex-oauth.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_PORT = Number.parseInt(process.env.CODMES_PORT || process.env.PORT || "8787", 10);
const WORKSPACE_HOST = process.env.CODMES_HOST || process.env.WORKSPACE_HOST || process.env.HOST || "127.0.0.1";
const DEFAULT_WORKSPACE_ROOT = path.join(process.env.HOME || process.cwd(), "CodmesWorkspace");
const WORKSPACE_ROOT = path.resolve(process.env.CODMES_WORKSPACE_ROOT || DEFAULT_WORKSPACE_ROOT);
const SERVER_TOKEN = process.env.CODMES_SERVER_TOKEN || "";
const PDF_STREAM_CACHE_LIMIT_BYTES = Math.max(
  256 * 1024 * 1024,
  Number.parseInt(process.env.CODMES_PDF_STREAM_CACHE_BYTES || String(8 * 1024 * 1024 * 1024), 10)
);
const searchWatchers = [];
const pendingSearchUpdates = new Set();
let searchUpdateTimer = null;
let searchIndexUpdateChain = Promise.resolve();
const pdfStreamArtifactTasks = new Map();

const TEXT_FILE_LIMIT = 5 * 1024 * 1024;

async function main() {
  await ensureWorkspace();
  const server = http.createServer(handleRequest);
  server.on("upgrade", handleUpgrade);
  server.listen(DEFAULT_PORT, WORKSPACE_HOST, () => {
    console.log(`[codmes] listening on http://${WORKSPACE_HOST}:${DEFAULT_PORT}`);
    console.log(`[codmes] root ${WORKSPACE_ROOT}`);
  });
  await startSearchWatchers();
}

function handleUpgrade(req, socket) {
  const url = new URL(req.url || "/", "http://localhost");
  if (url.pathname !== "/api/live") {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!isAuthorized(req, url)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }
  try {
    acceptWebSocket(req, socket);
    startLiveBridge(socket);
  } catch (error) {
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.destroy(error);
  }
}

function startLiveBridge(socket) {
  const engine = createAgentEngine();
  let closed = false;
  const send = (value) => {
    if (closed || socket.destroyed) return;
    socket.write(encodeWebSocketFrame(value));
  };
  const close = () => {
    if (closed) return;
    closed = true;
    engine.close();
    try {
      socket.end();
    } catch {}
  };
  engine.on("event", (event) => send({ kind: "runtime.event", ...event }));
  engine.on("close", () => send({ kind: "runtime.close" }));
  socket.on("error", close);
  socket.on("close", close);
  const decode = createFrameDecoder(async (text) => {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      send({ kind: "error", error: "Client message must be JSON." });
      return;
    }
    try {
      const result = await handleLiveCommand(engine, message);
      send({ kind: "result", id: message.id ?? null, result });
    } catch (error) {
      send({ kind: "error", id: message.id ?? null, error: error?.message || "Live command failed." });
    }
  }, close);
  socket.on("data", decode);
  send({ kind: "ready", service: "codmes-live" });
}

function createAgentEngine() {
  return createWorkspaceAgentEngine({
    workspaceRoot: WORKSPACE_ROOT
  });
}

function isPublicRequest(req, url) {
  return req.method === "GET" && url.pathname === "/api/health";
}

function isAuthorized(req, url) {
  if (!SERVER_TOKEN) return true;
  const authorization = String(req.headers.authorization || "");
  const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  const queryToken = url.searchParams.get("token") || "";
  const headerToken = String(req.headers["x-codmes-token"] || "").trim();
  return bearer === SERVER_TOKEN || queryToken === SERVER_TOKEN || headerToken === SERVER_TOKEN;
}

async function handleLiveCommand(engine, message) {
  const command = String(message.command || message.type || "");
  const params = message.params || {};
  if (command === "connect") {
    await engine.connect();
    return { ok: true };
  }
  if (command === "session.create") {
    return await engine.createSession(params);
  }
  if (command === "session.resume") {
    const runtimeSessionId = await engine.resumeSession(String(params.sessionId || ""));
    return { ok: true, runtimeSessionId };
  }
  if (command === "prompt.submit") {
    return await engine.submitPrompt(params);
  }
  if (command === "approval.respond") {
    return await engine.respondToApproval(params);
  }
  if (command === "approval.inbox.list") {
    return await engine.listApprovals(params);
  }
  if (command === "approval.inbox.show") {
    return await engine.readApproval(String(params.approvalId || params.id || ""));
  }
  if (command === "approval.inbox.respond") {
    return await engine.respondToWorkspaceApproval(String(params.approvalId || params.id || ""), params);
  }
  if (command === "task.resume") {
    return await engine.resumeTask(String(params.taskId || params.id || ""), params);
  }
  if (command === "task.cancel") {
    return await engine.cancelTask(String(params.taskId || params.id || ""), params);
  }
  if (command === "config.accessMode") {
    await engine.setAccessMode(String(params.sessionId || ""), params.accessMode);
    return { ok: true };
  }
  if (command === "config.reasoning") {
    await engine.setReasoning(String(params.sessionId || ""), params.reasoningEffort);
    return { ok: true };
  }
  if (command === "code.task.create" || command === "code.inspect") {
    return await engine.inspectCodeTask(params);
  }
  if (command === "code.checks.run") {
    return await engine.runCodeTaskChecks(String(params.taskId || ""), params);
  }
  if (command === "code.patch.propose") {
    return await engine.proposeCodeTaskPatch(String(params.taskId || ""), params);
  }
  if (command === "code.patch.apply") {
    return await engine.applyCodeTaskPatch(String(params.taskId || ""), params);
  }
  if (command === "code.patch.reject") {
    return await engine.rejectCodeTaskPatch(String(params.taskId || ""), params);
  }
  throw Object.assign(new Error(`Unknown live command: ${command}`), { status: 400 });
}

async function ensureWorkspace() {
  await fs.mkdir(WORKSPACE_ROOT, { recursive: true });
  await ensureAgentWorkspaceState(WORKSPACE_ROOT);
  const { ensurePluginRuntime } = await import("./lib/runtime/plugin-runtime.mjs");
  await ensurePluginRuntime(WORKSPACE_ROOT);
  await fs.mkdir(path.join(WORKSPACE_ROOT, WORKSPACE_DIRS.notes), { recursive: true });
  await fs.mkdir(path.join(WORKSPACE_ROOT, WORKSPACE_DIRS.code), { recursive: true });
  await fs.mkdir(path.join(WORKSPACE_ROOT, WORKSPACE_DIRS.documents), { recursive: true });
  await fs.mkdir(path.join(WORKSPACE_ROOT, WORKSPACE_DIRS.attachments), { recursive: true });
  await writeJsonIfMissing(path.join(WORKSPACE_ROOT, ".codmes", "metadata.json"), {
    schemaVersion: 1,
    workspaceRoot: WORKSPACE_ROOT,
    createdAt: new Date().toISOString(),
    files: {},
    indexes: {}
  });
  try {
    const { archiveOverflowGeneralSessions } = await import("./lib/runtime/session-archive.mjs");
    await archiveOverflowGeneralSessions(WORKSPACE_ROOT, { limit: 30 });
  } catch {}
}

async function writeJsonIfMissing(filePath, value) {
  try {
    await fs.access(filePath);
  } catch {
    await fs.writeFile(filePath, JSON.stringify(value, null, 2) + "\n", "utf8");
  }
}

async function handleRequest(req, res) {
  try {
    const url = new URL(req.url || "/", "http://localhost");
    if (req.method === "OPTIONS") return sendNoContent(res);
    setCors(res);
    if (!isPublicRequest(req, url) && !isAuthorized(req, url)) {
      return sendJson(res, { ok: false, error: "Unauthorized." }, 401);
    }

    if (req.method === "GET" && url.pathname === "/api/health") {
      return sendJson(res, {
        ok: true,
        service: "codmes",
        authRequired: Boolean(SERVER_TOKEN)
      });
    }
    if (req.method === "GET" && url.pathname === "/api/workspace") {
      return sendJson(res, await workspaceInfo());
    }
    if (req.method === "GET" && url.pathname === "/api/plugins") {
      const { listPublicRuntimePlugins } = await import("./lib/runtime/plugin-runtime.mjs");
      return sendJson(res, { plugins: await listPublicRuntimePlugins(WORKSPACE_ROOT) });
    }
    if (req.method === "POST" && url.pathname === "/api/plugins/install") {
      const body = await readJsonBody(req);
      const { installPlugin } = await import("./lib/runtime/plugin-registry.mjs");
      return sendJson(res, await installPlugin(WORKSPACE_ROOT, body.path), 201);
    }
    const pluginConfigurationMatch = url.pathname.match(
      /^\/api\/plugins\/([^/]+)\/configuration$/
    );
    if (req.method === "POST" && pluginConfigurationMatch) {
      const { savePluginConfiguration } = await import("./lib/runtime/plugin-runtime.mjs");
      return sendJson(res, await savePluginConfiguration(
        WORKSPACE_ROOT,
        decodeURIComponent(pluginConfigurationMatch[1]),
        await readJsonBody(req)
      ));
    }
    if (req.method === "GET" && url.pathname === "/api/marketplace/plugins") {
      const { listMarketplacePlugins } = await import("./lib/runtime/plugin-marketplace.mjs");
      return sendJson(res, await listMarketplacePlugins(WORKSPACE_ROOT));
    }
    const marketplaceInstallMatch = url.pathname.match(
      /^\/api\/marketplace\/plugins\/([^/]+)\/(install|update)$/
    );
    if (req.method === "POST" && marketplaceInstallMatch) {
      const body = await readJsonBody(req);
      const { installMarketplacePlugin } = await import("./lib/runtime/plugin-marketplace.mjs");
      return sendJson(res, await installMarketplacePlugin(
        WORKSPACE_ROOT,
        decodeURIComponent(marketplaceInstallMatch[1]),
        {
          version: body.version || null,
          acceptedPermissions: Array.isArray(body.acceptedPermissions)
            ? body.acceptedPermissions
            : []
        }
      ), marketplaceInstallMatch[2] === "install" ? 201 : 200);
    }
    const pluginRollbackMatch = url.pathname.match(/^\/api\/plugins\/([^/]+)\/rollback$/);
    if (req.method === "POST" && pluginRollbackMatch) {
      const body = await readJsonBody(req);
      const { getPluginInstallState, rollbackPlugin } = await import("./lib/runtime/plugin-registry.mjs");
      const pluginId = decodeURIComponent(pluginRollbackMatch[1]);
      const state = await getPluginInstallState(WORKSPACE_ROOT, pluginId);
      const version = body.version || state?.previousVersion || null;
      if (state?.source?.type === "marketplace" && version) {
        const { assertMarketplaceVersionAllowed } = await import("./lib/runtime/plugin-marketplace.mjs");
        await assertMarketplaceVersionAllowed(pluginId, version);
      }
      return sendJson(res, await rollbackPlugin(
        WORKSPACE_ROOT,
        pluginId,
        version
      ));
    }
    const pluginCollectionMatch = url.pathname.match(/^\/api\/plugins\/([^/]+)\/collections\/([^/]+)$/);
    if (req.method === "GET" && pluginCollectionMatch) {
      const { readPluginCollection } = await import("./lib/runtime/plugin-collection-store.mjs");
      const manifest = await resolveCollectionProvider(
        decodeURIComponent(pluginCollectionMatch[1])
      );
      return sendJson(res, await readPluginCollection(
        WORKSPACE_ROOT,
        manifest,
        decodeURIComponent(pluginCollectionMatch[2])
      ));
    }
    if (req.method === "POST" && pluginCollectionMatch) {
      return sendJson(res, await mutateInstalledPluginCollection(
        decodeURIComponent(pluginCollectionMatch[1]),
        decodeURIComponent(pluginCollectionMatch[2]),
        "create",
        await readJsonBody(req)
      ));
    }
    const pluginCollectionItemMatch = url.pathname.match(
      /^\/api\/plugins\/([^/]+)\/collections\/([^/]+)\/([^/]+)$/
    );
    if (pluginCollectionItemMatch
        && (req.method === "PATCH" || req.method === "DELETE")) {
      const body = req.method === "PATCH" ? await readJsonBody(req) : {};
      return sendJson(res, await mutateInstalledPluginCollection(
        decodeURIComponent(pluginCollectionItemMatch[1]),
        decodeURIComponent(pluginCollectionItemMatch[2]),
        req.method === "PATCH" ? "update" : "delete",
        {
          ...body,
          id: decodeURIComponent(pluginCollectionItemMatch[3])
        }
      ));
    }
    const pluginRemoveMatch = url.pathname.match(/^\/api\/plugins\/([^/]+)$/);
    if (req.method === "DELETE" && pluginRemoveMatch) {
      const { removePlugin } = await import("./lib/runtime/plugin-registry.mjs");
      return sendJson(res, await removePlugin(WORKSPACE_ROOT, decodeURIComponent(pluginRemoveMatch[1])));
    }
    const pluginViewDocumentMatch = url.pathname.match(/^\/api\/plugins\/([^/]+)\/view-document$/);
    if (req.method === "GET" && pluginViewDocumentMatch) {
      return sendJson(
        res,
        await fetchPluginViewDocument(
          decodeURIComponent(pluginViewDocumentMatch[1]),
          url.searchParams.get("route")
        )
      );
    }
    const pluginAuthMatch = url.pathname.match(/^\/api\/plugins\/([^/]+)\/auth\/(status|login|logout)$/);
    if (pluginAuthMatch) {
      const pluginId = decodeURIComponent(pluginAuthMatch[1]);
      const action = pluginAuthMatch[2];
      if (req.method === "GET" && action === "status") {
        return sendJson(res, await pluginAuthStatus(pluginId));
      }
      if (req.method === "POST" && action === "login") {
        return sendJson(res, await loginPlugin(req, pluginId));
      }
      if (req.method === "DELETE" && action === "logout") {
        return sendJson(res, await logoutPlugin(pluginId));
      }
    }
    if (req.method === "GET" && url.pathname === "/api/tree") {
      return sendJson(res, await readTree(url));
    }
    if (req.method === "GET" && url.pathname === "/api/file") {
      return sendJson(res, await readTextFile(url));
    }
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/api/raw") {
      return streamRawFile(req, res, url);
    }
    if (req.method === "GET" && url.pathname === "/api/pdf-thumbnail") {
      return await streamPdfThumbnail(res, url);
    }
    if (req.method === "GET" && url.pathname === "/api/pdf/metadata") {
      return sendJson(res, await readPdfMetadata(url));
    }
    if (req.method === "GET" && url.pathname === "/api/pdf/skeleton") {
      return streamPdfSkeleton(res, url);
    }
    if (req.method === "GET" && url.pathname === "/api/pdf/page") {
      return streamPdfPage(res, url);
    }
    if (req.method === "PUT" && url.pathname === "/api/file") {
      return sendJson(res, await writeTextFile(req, url));
    }
    if (req.method === "POST" && url.pathname === "/api/file") {
      return sendJson(res, await createFile(req), 201);
    }
    if (req.method === "POST" && url.pathname === "/api/folder") {
      return sendJson(res, await createFolder(req), 201);
    }
    if (req.method === "PATCH" && url.pathname === "/api/file/move") {
      return sendJson(res, await movePath(req));
    }
    if (req.method === "POST" && url.pathname === "/api/file/copy") {
      return sendJson(res, await copyPath(req), 201);
    }
    if (req.method === "POST" && url.pathname === "/api/file/upload") {
      return sendJson(res, await uploadFile(req), 201);
    }
    if (req.method === "PUT" && url.pathname === "/api/file/binary") {
      return sendJson(res, await replaceBinaryFile(req));
    }
    if (req.method === "POST" && url.pathname === "/api/file/import-codmes-pdf") {
      return sendJson(res, await importCodmesPdf(req), 201);
    }
    if (req.method === "POST" && url.pathname === "/api/file/export-codmes-pdf") {
      return sendJson(res, await exportCodmesPdfPackage(req));
    }
    if (req.method === "POST" && url.pathname === "/api/file/import-codmes-pdf-package") {
      return sendJson(res, await importCodmesPdfPackage(req), 201);
    }
    if (req.method === "POST" && url.pathname === "/api/file/upload/start") {
      return sendJson(res, await startChunkedUpload(req), 201);
    }
    if (req.method === "POST" && url.pathname === "/api/file/upload/chunk") {
      return sendJson(res, await appendUploadChunk(req));
    }
    if (req.method === "POST" && url.pathname === "/api/file/upload/complete") {
      return sendJson(res, await completeChunkedUpload(req), 201);
    }
    if (req.method === "POST" && url.pathname === "/api/file/upload/cancel") {
      return sendJson(res, await cancelChunkedUpload(req));
    }
    if (req.method === "DELETE" && url.pathname === "/api/file") {
      return sendJson(res, await deletePath(url));
    }
    if (req.method === "GET" && url.pathname === "/api/file/metadata") {
      return sendJson(res, await fileMetadata(url));
    }
    if (req.method === "GET" && url.pathname === "/api/file/annotations") {
      return sendJson(res, await readFileAnnotations(url));
    }
    if (req.method === "PUT" && url.pathname === "/api/file/annotations") {
      return sendJson(res, await writeFileAnnotations(req, url));
    }
    if (req.method === "POST" && url.pathname === "/api/context") {
      return sendJson(res, await resolveContext(req));
    }
    if (req.method === "GET" && url.pathname === "/api/index/status") {
      return sendJson(res, await indexStatus());
    }
    if (req.method === "POST" && url.pathname === "/api/index/rebuild") {
      return sendJson(res, await rebuildIndex());
    }
    if (req.method === "GET" && url.pathname === "/api/search/status") {
      return sendJson(res, searchStatus(WORKSPACE_ROOT));
    }
    if (req.method === "GET" && url.pathname === "/api/document-jobs") {
      return sendJson(res, { jobs: listDocumentJobs({ includeCompleted: true }) });
    }
    if (req.method === "GET" && url.pathname === "/api/global-search") {
      return sendJson(res, await runGlobalSearch(url));
    }
    if (req.method === "POST" && url.pathname === "/api/search") {
      return sendJson(res, await runSearch(req));
    }
    if (req.method === "GET" && url.pathname === "/api/search/config") {
      return sendJson(res, await readSearchConfig());
    }
    if (req.method === "POST" && url.pathname === "/api/search/config") {
      return sendJson(res, await updateSearchConfig(req));
    }
    if (req.method === "GET" && url.pathname === "/api/skills") {
      return sendJson(res, await skillsList());
    }
    const skillMatch = url.pathname.match(/^\/api\/skills\/([^/]+)$/);
    if (skillMatch && req.method === "GET") {
      return sendJson(res, await skillDetail(skillMatch[1]));
    }
    const skillEnableMatch = url.pathname.match(/^\/api\/skills\/([^/]+)\/enable$/);
    if (skillEnableMatch && req.method === "POST") {
      return sendJson(res, await setSkillEnabled(skillEnableMatch[1], true));
    }
    const skillDisableMatch = url.pathname.match(/^\/api\/skills\/([^/]+)\/disable$/);
    if (skillDisableMatch && req.method === "POST") {
      return sendJson(res, await setSkillEnabled(skillDisableMatch[1], false));
    }
    if (req.method === "GET" && url.pathname === "/api/security") {
      return sendJson(res, await readSecurityConfig(WORKSPACE_ROOT));
    }
    if (req.method === "POST" && url.pathname === "/api/security") {
      return sendJson(res, await updateSecurity(req));
    }
    if (req.method === "GET" && url.pathname === "/api/mcp") {
      return sendJson(res, await listMcpServers());
    }
    if (req.method === "POST" && url.pathname === "/api/mcp") {
      return sendJson(res, await addMcpServer(req));
    }
    const mcpUpdateMatch = url.pathname.match(/^\/api\/mcp\/([^/]+)$/);
    if (mcpUpdateMatch && (req.method === "POST" || req.method === "PATCH")) {
      return sendJson(res, await updateMcpServer(mcpUpdateMatch[1], req));
    }
    const mcpEnableMatch = url.pathname.match(/^\/api\/mcp\/([^/]+)\/enable$/);
    if (mcpEnableMatch && req.method === "POST") {
      return sendJson(res, await setMcpEnabled(mcpEnableMatch[1], true));
    }
    const mcpDisableMatch = url.pathname.match(/^\/api\/mcp\/([^/]+)\/disable$/);
    if (mcpDisableMatch && req.method === "POST") {
      return sendJson(res, await setMcpEnabled(mcpDisableMatch[1], false));
    }
    const mcpDeleteMatch = url.pathname.match(/^\/api\/mcp\/([^/]+)$/);
    if (mcpDeleteMatch && req.method === "DELETE") {
      return sendJson(res, await removeMcpServer(mcpDeleteMatch[1]));
    }
    if (req.method === "GET" && url.pathname === "/api/doctor") {
      return sendJson(res, await doctorStatus());
    }
    if (req.method === "GET" && url.pathname === "/api/providers") {
      return sendJson(res, await listRuntimeProviders());
    }
    if (req.method === "POST" && url.pathname === "/api/providers/custom") {
      return sendJson(res, await createCustomProvider(req), 201);
    }
    const customProviderDeleteMatch = url.pathname.match(/^\/api\/providers\/custom\/([^/]+)$/);
    if (customProviderDeleteMatch && req.method === "DELETE") {
      return sendJson(res, await deleteCustomProvider(customProviderDeleteMatch[1]));
    }
    const providerModelsMatch = url.pathname.match(/^\/api\/providers\/([^/]+)\/models$/);
    if (providerModelsMatch && req.method === "GET") {
      return sendJson(res, await discoverProviderModels(providerModelsMatch[1]));
    }
    if (req.method === "GET" && url.pathname === "/api/auth") {
      return sendJson(res, await listRuntimeAuth());
    }
    if (req.method === "POST" && url.pathname === "/api/auth/openai-codex/login/start") {
      return sendJson(res, await startProviderOAuthLogin("openai-codex"), 201);
    }
    const codexLoginMatch = url.pathname.match(/^\/api\/auth\/openai-codex\/login\/([^/]+)$/);
    if (codexLoginMatch && req.method === "GET") {
      return sendJson(res, readCodexOAuthLogin(decodeURIComponent(codexLoginMatch[1])));
    }
    const codexLoginCancelMatch = url.pathname.match(/^\/api\/auth\/openai-codex\/login\/([^/]+)\/cancel$/);
    if (codexLoginCancelMatch && req.method === "POST") {
      return sendJson(res, cancelCodexOAuthLogin(decodeURIComponent(codexLoginCancelMatch[1])));
    }
    const authSelectMatch = url.pathname.match(/^\/api\/auth\/([^/]+)\/select$/);
    if (authSelectMatch && req.method === "POST") {
      return sendJson(res, await selectProviderAuth(authSelectMatch[1], req));
    }
    const authCredentialDeleteMatch = url.pathname.match(/^\/api\/auth\/([^/]+)\/credentials\/([^/]+)$/);
    if (authCredentialDeleteMatch && req.method === "DELETE") {
      return sendJson(res, await deleteProviderAuthCredential(authCredentialDeleteMatch[1], authCredentialDeleteMatch[2]));
    }
    const authProviderMatch = url.pathname.match(/^\/api\/auth\/([^/]+)$/);
    if (authProviderMatch && req.method === "GET") {
      return sendJson(res, await readProviderAuth(authProviderMatch[1]));
    }
    if (authProviderMatch && req.method === "POST") {
      return sendJson(res, await updateProviderAuth(authProviderMatch[1], req));
    }
    if (authProviderMatch && req.method === "DELETE") {
      return sendJson(res, await deleteProviderAuthAll(authProviderMatch[1]));
    }
    const authDeleteMatch = url.pathname.match(/^\/api\/auth\/([^/]+)\/([^/]+)$/);
    if (authDeleteMatch && req.method === "DELETE") {
      return sendJson(res, await deleteProviderAuth(authDeleteMatch[1], authDeleteMatch[2]));
    }
    if (req.method === "GET" && url.pathname === "/api/model/default") {
      return sendJson(res, await readDefaultModel());
    }
    if (req.method === "POST" && url.pathname === "/api/model/default") {
      return sendJson(res, await updateDefaultModel(req));
    }
    if (req.method === "GET" && url.pathname === "/api/agent/tasks") {
      return sendJson(res, await listAgentTasks(url));
    }
    const taskMatch = url.pathname.match(/^\/api\/agent\/tasks\/([^/]+)$/);
    if (taskMatch && req.method === "GET") {
      return sendJson(res, await readAgentTask(taskMatch[1]));
    }
    const taskResumeMatch = url.pathname.match(/^\/api\/agent\/tasks\/([^/]+)\/resume$/);
    if (taskResumeMatch && req.method === "POST") {
      return sendJson(res, await resumeAgentTask(taskResumeMatch[1], req));
    }
    const taskCancelMatch = url.pathname.match(/^\/api\/agent\/tasks\/([^/]+)\/cancel$/);
    if (taskCancelMatch && req.method === "POST") {
      return sendJson(res, await cancelAgentTask(taskCancelMatch[1], req));
    }
    if (req.method === "GET" && url.pathname === "/api/agent/approvals") {
      return sendJson(res, await listAgentApprovals(url));
    }
    const approvalMatch = url.pathname.match(/^\/api\/agent\/approvals\/([^/]+)$/);
    if (approvalMatch && req.method === "GET") {
      return sendJson(res, await readAgentApproval(approvalMatch[1]));
    }
    const approvalRespondMatch = url.pathname.match(/^\/api\/agent\/approvals\/([^/]+)\/respond$/);
    if (approvalRespondMatch && req.method === "POST") {
      return sendJson(res, await respondToAgentApproval(approvalRespondMatch[1], req));
    }
    if (req.method === "POST" && url.pathname === "/api/agent/code-task") {
      return sendJson(res, await createCodeTask(req), 201);
    }
    const codeChecksMatch = url.pathname.match(/^\/api\/agent\/code-task\/([^/]+)\/checks$/);
    if (codeChecksMatch && req.method === "POST") {
      return sendJson(res, await runCodeTaskChecks(codeChecksMatch[1], req));
    }
    const codeGitMatch = url.pathname.match(/^\/api\/agent\/code-task\/([^/]+)\/git$/);
    if (codeGitMatch && req.method === "POST") {
      return sendJson(res, await runCodeTaskGit(codeGitMatch[1], req));
    }
    const codePatchProposeMatch = url.pathname.match(/^\/api\/agent\/code-task\/([^/]+)\/patches$/);
    if (codePatchProposeMatch && req.method === "POST") {
      return sendJson(res, await proposeCodeTaskPatch(codePatchProposeMatch[1], req), 201);
    }
    const codePatchGenerateMatch = url.pathname.match(/^\/api\/agent\/code-task\/([^/]+)\/patches\/generate$/);
    if (codePatchGenerateMatch && req.method === "POST") {
      return sendJson(res, await generateCodeTaskPatch(codePatchGenerateMatch[1], req), 201);
    }
    const codePatchApplyMatch = url.pathname.match(/^\/api\/agent\/code-task\/([^/]+)\/patches\/([^/]+)\/apply$/);
    if (codePatchApplyMatch && req.method === "POST") {
      return sendJson(res, await applyCodeTaskPatch(codePatchApplyMatch[1], codePatchApplyMatch[2], req));
    }
    const codePatchRejectMatch = url.pathname.match(/^\/api\/agent\/code-task\/([^/]+)\/patches\/([^/]+)\/reject$/);
    if (codePatchRejectMatch && req.method === "POST") {
      return sendJson(res, await rejectCodeTaskPatch(codePatchRejectMatch[1], codePatchRejectMatch[2], req));
    }
    if (req.method === "POST" && url.pathname === "/api/render/markdown") {
      return sendJson(res, await renderMarkdown(req));
    }
    if (req.method === "POST" && url.pathname === "/api/render/code") {
      return sendJson(res, await renderCode(req));
    }
    // --- Tool Mode Routes ---
    if (req.method === "GET" && url.pathname === "/api/tool-modes") {
      const { loadToolModes } = await import("./lib/runtime/tool-mode-registry.mjs");
      return sendJson(res, await loadToolModes(WORKSPACE_ROOT));
    }
    const toolModeSurfaceMatch = url.pathname.match(/^\/api\/tool-modes\/([^/]+)$/);
    if (req.method === "POST" && toolModeSurfaceMatch) {
      const surface = decodeURIComponent(toolModeSurfaceMatch[1]);
      const body = await readJsonBody(req);
      const { saveToolModeOverride } = await import("./lib/runtime/tool-mode-registry.mjs");
      return sendJson(res, await saveToolModeOverride(WORKSPACE_ROOT, surface, body));
    }

    // --- Tool Discovery Routes ---
    if (req.method === "GET" && url.pathname === "/api/tools/available") {
      const { TOOL_REGISTRY } = await import("./lib/runtime/tool-discovery.mjs");
      return sendJson(res, { availableTools: TOOL_REGISTRY });
    }
    if (req.method === "POST" && url.pathname === "/api/tools/discover") {
      const body = await readJsonBody(req);
      const { executeToolDiscovery } = await import("./lib/runtime/tool-discovery.mjs");
      return sendJson(res, await executeToolDiscovery(WORKSPACE_ROOT, body.surface || "chat", body));
    }

    // --- Conversation Search & Read Routes ---
    if (req.method === "GET" && url.pathname === "/api/conversations/search") {
      const { executeConversationSearch } = await import("./lib/runtime/conversation-tools.mjs");
      return sendJson(res, await executeConversationSearch(WORKSPACE_ROOT, {
        query: url.searchParams.get("query") || "",
        timeRange: url.searchParams.get("timeRange") || "",
        scope: url.searchParams.get("scope") || "",
        folderId: url.searchParams.get("folderId") || "",
        projectId: url.searchParams.get("projectId") || "",
        includeArchived: url.searchParams.get("includeArchived") === "true",
        maxResults: parseInt(url.searchParams.get("maxResults") || "10", 10)
      }));
    }
    if (req.method === "POST" && url.pathname === "/api/conversations/search") {
      const body = await readJsonBody(req);
      const { executeConversationSearch } = await import("./lib/runtime/conversation-tools.mjs");
      return sendJson(res, await executeConversationSearch(WORKSPACE_ROOT, body));
    }
    if (req.method === "POST" && url.pathname === "/api/conversations/read") {
      const body = await readJsonBody(req);
      const { executeConversationRead } = await import("./lib/runtime/conversation-tools.mjs");
      return sendJson(res, await executeConversationRead(WORKSPACE_ROOT, body));
    }
    const convMsgMatch = url.pathname.match(/^\/api\/conversations\/([^/]+)\/messages$/);
    if (req.method === "GET" && convMsgMatch) {
      const sessionId = decodeURIComponent(convMsgMatch[1]);
      const engine = createAgentEngine();
      try {
        return sendJson(res, normalizeSessionMessagesResponse(await engine.getSessionMessages(sessionId)));
      } finally {
        engine.close();
      }
    }

    // --- Conversation Folders Routes ---
    if (req.method === "GET" && url.pathname === "/api/conversation-folders") {
      const { listFolders } = await import("./lib/runtime/conversation-folders.mjs");
      return sendJson(res, await listFolders(WORKSPACE_ROOT));
    }
    if (req.method === "POST" && url.pathname === "/api/conversation-folders") {
      const body = await readJsonBody(req);
      const { createFolder } = await import("./lib/runtime/conversation-folders.mjs");
      return sendJson(res, await createFolder(WORKSPACE_ROOT, body), 201);
    }
    const folderMatch = url.pathname.match(/^\/api\/conversation-folders\/([^/]+)$/);
    if (folderMatch) {
      const folderId = decodeURIComponent(folderMatch[1]);
      if (req.method === "PATCH") {
        const body = await readJsonBody(req);
        const { updateFolder } = await import("./lib/runtime/conversation-folders.mjs");
        return sendJson(res, await updateFolder(WORKSPACE_ROOT, folderId, body));
      }
      if (req.method === "DELETE") {
        const { deleteFolder } = await import("./lib/runtime/conversation-folders.mjs");
        return sendJson(res, await deleteFolder(WORKSPACE_ROOT, folderId));
      }
    }

    // --- Session Folder Move & Manual Archive/Unarchive ---
    const sessionMoveMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/move-to-folder$/);
    if (req.method === "POST" && sessionMoveMatch) {
      const sessionId = decodeURIComponent(sessionMoveMatch[1]);
      const body = await readJsonBody(req);
      const { moveSessionToFolder } = await import("./lib/runtime/conversation-folders.mjs");
      return sendJson(
        res,
        await moveSessionToFolder(
          WORKSPACE_ROOT,
          sessionId,
          body.folderId,
          body.projectId,
          body.projectTitle
        )
      );
    }
    const sessionPinMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/pin$/);
    if (req.method === "POST" && sessionPinMatch) {
      const sessionId = decodeURIComponent(sessionPinMatch[1]);
      const body = await readJsonBody(req);
      const { setSessionPinned } = await import("./lib/runtime/conversation-folders.mjs");
      return sendJson(res, await setSessionPinned(WORKSPACE_ROOT, sessionId, body.pinned));
    }
    const sessionArchiveMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/archive$/);
    if (req.method === "POST" && sessionArchiveMatch) {
      const sessionId = decodeURIComponent(sessionArchiveMatch[1]);
      const { archiveSession } = await import("./lib/runtime/session-archive.mjs");
      return sendJson(res, await archiveSession(WORKSPACE_ROOT, sessionId));
    }
    const sessionUnarchiveMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/unarchive$/);
    if (req.method === "POST" && sessionUnarchiveMatch) {
      const sessionId = decodeURIComponent(sessionUnarchiveMatch[1]);
      const { unarchiveSession } = await import("./lib/runtime/session-archive.mjs");
      return sendJson(res, await unarchiveSession(WORKSPACE_ROOT, sessionId));
    }
    if (req.method === "GET" && url.pathname === "/api/conversation-archive") {
      const { listArchivedSessions } = await import("./lib/runtime/session-archive.mjs");
      return sendJson(res, await listArchivedSessions(WORKSPACE_ROOT));
    }
    if (req.method === "POST" && url.pathname === "/api/sessions/archive-expired") {
      const body = await readJsonBody(req).catch(() => ({}));
      const { archiveOverflowGeneralSessions } = await import("./lib/runtime/session-archive.mjs");
      return sendJson(res, await archiveOverflowGeneralSessions(WORKSPACE_ROOT, {
        limit: body.limit || 30
      }));
    }
    const sessionSummarizeMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/summarize$/);
    if (req.method === "POST" && sessionSummarizeMatch) {
      return sendJson(res, await summarizeSession(sessionSummarizeMatch[1]));
    }

    // --- Long-Term Memory Search & CRUD ---
    if (req.method === "GET" && url.pathname === "/api/memory/search") {
      const query = url.searchParams.get("query") || "";
      const currentFolderId = url.searchParams.get("currentFolderId") || "";
      const currentProjectId = url.searchParams.get("currentProjectId") || "";
      const timeRange = url.searchParams.get("timeRange") || "";
      const maxResults = parseInt(url.searchParams.get("maxResults") || "10", 10);
      const { searchMemory } = await import("./lib/runtime/memory-retrieval.mjs");
      return sendJson(res, await searchMemory(WORKSPACE_ROOT, query, { currentFolderId, currentProjectId, timeRange, maxResults }));
    }
    if (req.method === "GET" && url.pathname === "/api/memory/settings") {
      const { readMemorySettings } = await import("./lib/runtime/memory-retrieval.mjs");
      return sendJson(res, await readMemorySettings(WORKSPACE_ROOT));
    }
    if (req.method === "POST" && url.pathname === "/api/memory/settings") {
      const body = await readJsonBody(req);
      const { writeMemorySettings } = await import("./lib/runtime/memory-retrieval.mjs");
      return sendJson(res, await writeMemorySettings(WORKSPACE_ROOT, body));
    }
    if (req.method === "GET" && url.pathname === "/api/memory/candidates") {
      const { listMemoryCandidates } = await import("./lib/runtime/memory-retrieval.mjs");
      return sendJson(res, { candidates: await listMemoryCandidates(WORKSPACE_ROOT) });
    }
    const memoryCandidateApproveMatch = url.pathname.match(/^\/api\/memory\/candidates\/([^/]+)\/approve$/);
    if (memoryCandidateApproveMatch && req.method === "POST") {
      const body = await readJsonBody(req).catch(() => ({}));
      const { approveMemoryCandidate } = await import("./lib/runtime/memory-retrieval.mjs");
      return sendJson(res, await approveMemoryCandidate(WORKSPACE_ROOT, decodeURIComponent(memoryCandidateApproveMatch[1]), body));
    }
    const memoryCandidateRejectMatch = url.pathname.match(/^\/api\/memory\/candidates\/([^/]+)\/reject$/);
    if (memoryCandidateRejectMatch && req.method === "POST") {
      const body = await readJsonBody(req).catch(() => ({}));
      const { rejectMemoryCandidate } = await import("./lib/runtime/memory-retrieval.mjs");
      return sendJson(res, await rejectMemoryCandidate(WORKSPACE_ROOT, decodeURIComponent(memoryCandidateRejectMatch[1]), body.reason || "Rejected by user."));
    }
    if (req.method === "POST" && url.pathname === "/api/memory") {
      const body = await readJsonBody(req);
      const memories = await getUserMemories();
      const newMemory = {
        id: body.id || `memory-${randomUUID()}`,
        content: body.content || "",
        createdAt: new Date().toISOString(),
        pinned: Boolean(body.pinned),
        sourceSessionIds: body.sourceSessionIds || []
      };
      memories.push(newMemory);
      await saveUserMemories(memories);
      return sendJson(res, newMemory, 201);
    }
    if (req.method === "POST" && url.pathname === "/api/memory/extract-from-session") {
      const body = await readJsonBody(req);
      return sendJson(res, await extractMemoryFromSession(body.sessionId));
    }
    const memoryMatch = url.pathname.match(/^\/api\/memory\/([^/]+)$/);
    if (memoryMatch) {
      const memoryId = decodeURIComponent(memoryMatch[1]);
      if (req.method === "GET") {
        const { readMemoryById } = await import("./lib/runtime/memory-retrieval.mjs");
        const memory = await readMemoryById(WORKSPACE_ROOT, memoryId);
        if (!memory) return sendJson(res, { ok: false, error: "Memory not found." }, 404);
        return sendJson(res, memory);
      }
      if (req.method === "PATCH") {
        const body = await readJsonBody(req);
        const memories = await getUserMemories();
        const idx = memories.findIndex(m => m.id === memoryId);
        if (idx === -1) {
          return sendJson(res, { ok: false, error: "Memory not found." }, 404);
        }
        memories[idx] = {
          ...memories[idx],
          ...body,
          updatedAt: new Date().toISOString()
        };
        await saveUserMemories(memories);
        return sendJson(res, memories[idx]);
      }
      if (req.method === "DELETE") {
        const memories = await getUserMemories();
        const deletedMemory = memories.find(m => m.id === memoryId);
        const filtered = memories.filter(m => m.id !== memoryId);
        await saveUserMemories(filtered);
        if (deletedMemory) {
          const { recordDeletedMemoryTombstone } = await import("./lib/runtime/memory-retrieval.mjs");
          await recordDeletedMemoryTombstone(WORKSPACE_ROOT, deletedMemory, "user_deleted");
        }
        return sendJson(res, { ok: true });
      }
    }

    // --- Workspace-owned session routes (no Hermes required) ---
    const wsSessionsPath = "/api/workspace/sessions";
    if (url.pathname === wsSessionsPath) {
      const engine = createAgentEngine();
      try {
        if (req.method === "GET") {
          return sendJson(res, await normalizeSessionsResponse(await engine.listSessions(200)));
        }
        if (req.method === "POST") {
          const body = await readJsonBody(req);
          return sendJson(res, await engine.createSession(body), 201);
        }
      } finally {
        engine.close();
      }
    }
    const wsSessionMsgMatch = url.pathname.match(/^\/api\/workspace\/sessions\/([^/]+)\/messages$/);
    if (wsSessionMsgMatch) {
      const engine = createAgentEngine();
      try {
        if (req.method === "GET") {
          const sessionId = decodeURIComponent(wsSessionMsgMatch[1]);
          return sendJson(res, normalizeSessionMessagesResponse(
            await engine.getSessionMessages(sessionId)
          ));
        }
      } finally {
        engine.close();
      }
    }
    const wsSessionSingleMatch = url.pathname.match(/^\/api\/workspace\/sessions\/([^/]+)$/);
    if (wsSessionSingleMatch) {
      const engine = createAgentEngine();
      try {
        if (req.method === "DELETE") {
          const sessionId = decodeURIComponent(wsSessionSingleMatch[1]);
          return sendJson(res, await engine.deleteSession(sessionId));
        }
      } finally {
        engine.close();
      }
    }
    // --- Codmes runtime routes ---
    if (
      url.pathname === "/api/models"
      || url.pathname === "/api/workspace/models"
      || url.pathname === "/api/sessions"
      || url.pathname.startsWith("/api/sessions/")
    ) {
      return handleRuntimeProxy(req, res, url);
    }

    throw Object.assign(new Error("Not found."), { status: 404 });
  } catch (error) {
    if (res.destroyed || res.writableEnded) return;
    sendError(res, error);
  }
}

async function workspaceInfo() {
  return {
    rootName: path.basename(WORKSPACE_ROOT),
    workspaceRoot: WORKSPACE_ROOT,
    roots: Object.entries(WORKSPACE_DIRS).map(([id, folder]) => ({
      id,
      name: folder,
      path: folder
    })),
    runtime: {
      status: "ok",
      owner: "codmes",
      configPath: ".codmes/config"
    },
    chatRuntime: {
      status: "ok",
      reason: ""
    },
    agent: {
      engine: "workspace-agent",
      statePath: ".codmes",
      runtimes: ["codmes-runtime", "chat", "models", "sessions", "code-agent"],
      taskEndpoint: "/api/agent/tasks",
      approvalEndpoint: "/api/agent/approvals",
      codeTaskEndpoint: "/api/agent/code-task",
      codePatchEndpoint: "/api/agent/code-task/:id/patches",
      codePatchRejectEndpoint: "/api/agent/code-task/:id/patches/:proposalId/reject",
      codeChecksEndpoint: "/api/agent/code-task/:id/checks",
      codeGitEndpoint: "/api/agent/code-task/:id/git"
    },
    search: searchStatus(WORKSPACE_ROOT)
  };
}

async function readTree(url) {
  const rootPath = rootPathFromKey(url.searchParams.get("root"));
  const nestedPath = url.searchParams.get("path") || "";
  const recursive = url.searchParams.get("recursive") === "true";
  const relativePath = joinWorkspacePath(rootPath, nestedPath);
  const { absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, relativePath);
  const children = await readTreeChildren(relativePath, absolutePath, recursive);
  return { path: relativePath, children };
}

async function readTreeChildren(relativePath, absolutePath, recursive) {
  const entries = await fs.readdir(absolutePath, { withFileTypes: true });
  const directChildren = await Promise.all(entries
    .filter((entry) => entry.name !== ".DS_Store")
    .filter((entry) => entry.name !== ".hermes-workspace")
    .filter((entry) => entry.name !== ".codmes")
    .map(async (entry) => {
      const childRelativePath = joinWorkspacePath(relativePath, entry.name);
      const childAbsolutePath = path.join(absolutePath, entry.name);
      const stat = await fs.stat(childAbsolutePath);
      const item = {
        name: entry.name,
        path: childRelativePath,
        kind: fileKind(entry.name, entry.isDirectory()),
        isDirectory: entry.isDirectory(),
        size: stat.size,
        modifiedAt: stat.mtime.toISOString()
      };
      const descendants = recursive && entry.isDirectory()
        ? await readTreeChildren(childRelativePath, childAbsolutePath, true)
        : [];
      return [item, ...descendants];
    }));
  directChildren.sort((a, b) => {
    const first = a[0];
    const second = b[0];
    return Number(second.isDirectory) - Number(first.isDirectory) || first.name.localeCompare(second.name);
  });
  return directChildren.flat();
}

async function readTextFile(url) {
  const filePath = requireQuery(url, "path");
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot read a folder as a file."), { status: 400 });
  if (stat.size > TEXT_FILE_LIMIT) {
    throw Object.assign(new Error("File is too large for text read. Use /api/raw or search/index APIs."), { status: 413 });
  }
  const content = await fs.readFile(absolutePath, "utf8");
  return {
    path: relativePath,
    name: path.basename(relativePath),
    kind: fileKind(relativePath),
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
    content
  };
}

async function streamRawFile(req, res, url) {
  const filePath = requireQuery(url, "path");
  const { absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot stream a folder."), { status: 400 });
  const range = parseByteRange(req.headers.range, stat.size);
  const headers = {
    "accept-ranges": "bytes",
    "content-type": contentTypeForPath(filePath)
  };

  if (range?.invalid) {
    res.writeHead(416, {
      ...headers,
      "content-range": `bytes */${stat.size}`
    });
    return res.end();
  }

  const start = range?.start ?? 0;
  const end = range?.end ?? Math.max(0, stat.size - 1);
  const status = range ? 206 : 200;
  res.writeHead(status, {
    ...headers,
    "content-length": String(stat.size === 0 ? 0 : end - start + 1),
    ...(range ? { "content-range": `bytes ${start}-${end}/${stat.size}` } : {})
  });
  if (req.method === "HEAD" || stat.size === 0) return res.end();
  createReadStream(absolutePath, { start, end }).pipe(res);
}

function parseByteRange(value, size) {
  if (!value) return null;
  const match = /^bytes=(\d*)-(\d*)$/i.exec(String(value).trim());
  if (!match || size <= 0) return { invalid: true };

  const rawStart = match[1];
  const rawEnd = match[2];
  if (!rawStart && !rawEnd) return { invalid: true };

  let start;
  let end;
  if (!rawStart) {
    const suffixLength = Number.parseInt(rawEnd, 10);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) return { invalid: true };
    start = Math.max(0, size - suffixLength);
    end = size - 1;
  } else {
    start = Number.parseInt(rawStart, 10);
    end = rawEnd ? Number.parseInt(rawEnd, 10) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= size || end < start) {
      return { invalid: true };
    }
    end = Math.min(end, size - 1);
  }
  return { start, end };
}

async function streamPdfThumbnail(res, url) {
  const filePath = requireQuery(url, "path");
  const page = Math.max(1, Number.parseInt(url.searchParams.get("page") || "1", 10) || 1);
  const crop = pdfThumbnailCrop(url);
  const scale = pdfThumbnailScale(url);
  const highlightQuery = String(url.searchParams.get("highlight") || "").trim().slice(0, 120);
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  if (path.extname(relativePath).toLowerCase() !== ".pdf") {
    throw Object.assign(new Error("PDF thumbnail source must be a PDF file."), { status: 400 });
  }
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot render a folder."), { status: 400 });
  const abortController = new AbortController();
  const abortRender = () => {
    if (!res.writableEnded) abortController.abort();
  };
  res.once("close", abortRender);
  let thumbnailPath;
  try {
    thumbnailPath = await renderPdfThumbnail(
      absolutePath,
      relativePath,
      stat,
      page,
      crop,
      highlightQuery,
      scale,
      abortController.signal
    );
  } finally {
    res.off("close", abortRender);
  }
  if (abortController.signal.aborted || res.destroyed) return;
  const thumbnailStat = await fs.stat(thumbnailPath);
  res.writeHead(200, {
    "cache-control": "public, max-age=86400",
    "content-length": String(thumbnailStat.size),
    "content-type": "image/png"
  });
  createReadStream(thumbnailPath).pipe(res);
}

async function readPdfMetadata(url) {
  const filePath = requireQuery(url, "path");
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  if (path.extname(relativePath).toLowerCase() !== ".pdf") {
    throw Object.assign(new Error("PDF metadata source must be a PDF file."), { status: 400 });
  }
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot inspect a folder."), { status: 400 });
  const python = await documentWorkerPython();
  const script = `
import fitz, json, sys
doc = fitz.open(sys.argv[1])
rect = doc.load_page(0).rect if doc.page_count else fitz.Rect(0, 0, 1, 1)
print(json.dumps({"pageCount": doc.page_count, "pageWidth": rect.width, "pageHeight": rect.height}))
doc.close()
`;
  const output = await runPythonScript(python, script, [absolutePath]);
  const metadata = JSON.parse(output);
  return {
    path: relativePath,
    size: stat.size,
    pageCount: metadata.pageCount,
    pageWidth: metadata.pageWidth,
    pageHeight: metadata.pageHeight
  };
}

async function streamPdfSkeleton(res, url) {
  const source = await resolvePdfStreamSource(url);
  const outputPath = await cachedPdfStreamArtifact(
    `skeleton-v1\n${source.relativePath}\n${source.stat.size}:${source.stat.mtimeMs}`,
    "skeleton.pdf",
    async (temporaryPath) => {
      const python = await documentWorkerPython();
      const script = `
import fitz, sys
source = fitz.open(sys.argv[1])
output = fitz.open()
for index in range(source.page_count):
    rect = source.load_page(index).rect
    output.new_page(width=max(rect.width, 1), height=max(rect.height, 1))
output.save(sys.argv[2], garbage=3, deflate=True)
output.close()
source.close()
`;
      await runPythonScript(python, script, [source.absolutePath, temporaryPath]);
    }
  );
  return streamPdfArtifact(res, outputPath);
}

async function streamPdfPage(res, url) {
  const source = await resolvePdfStreamSource(url);
  const page = Math.max(1, Number.parseInt(url.searchParams.get("page") || "1", 10) || 1);
  const outputPath = await cachedPdfStreamArtifact(
    `page-v1\n${source.relativePath}\n${source.stat.size}:${source.stat.mtimeMs}\n${page}`,
    `page-${page}.pdf`,
    async (temporaryPath) => {
      const python = await documentWorkerPython();
      const script = `
import fitz, sys
source = fitz.open(sys.argv[1])
page_index = int(sys.argv[3]) - 1
if page_index < 0 or page_index >= source.page_count:
    raise ValueError("PDF page is out of range")
output = fitz.open()
output.insert_pdf(source, from_page=page_index, to_page=page_index, links=True, annots=False)
output.save(sys.argv[2], garbage=3, deflate=True)
output.close()
source.close()
`;
      await runPythonScript(python, script, [source.absolutePath, temporaryPath, String(page)]);
    }
  );
  return streamPdfArtifact(res, outputPath);
}

async function resolvePdfStreamSource(url) {
  const filePath = requireQuery(url, "path");
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  if (path.extname(relativePath).toLowerCase() !== ".pdf") {
    throw Object.assign(new Error("PDF stream source must be a PDF file."), { status: 400 });
  }
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot stream a folder."), { status: 400 });
  return { relativePath, absolutePath, stat };
}

async function cachedPdfStreamArtifact(cacheIdentity, suffix, produce) {
  const key = createHash("sha256").update(cacheIdentity).digest("hex");
  const directory = path.join(WORKSPACE_ROOT, ".codmes", "index", "pdf-stream");
  const outputPath = path.join(directory, `${key}-${suffix}`);
  try {
    await fs.access(outputPath);
    const now = new Date();
    await fs.utimes(outputPath, now, now).catch(() => {});
    return outputPath;
  } catch {
    // Generate below.
  }

  if (!pdfStreamArtifactTasks.has(outputPath)) {
    const task = (async () => {
      await fs.mkdir(directory, { recursive: true });
      const temporaryPath = `${outputPath}.${randomUUID()}.tmp`;
      try {
        await produce(temporaryPath);
        await fs.rename(temporaryPath, outputPath);
        await trimPdfStreamCache(directory, PDF_STREAM_CACHE_LIMIT_BYTES, outputPath);
      } finally {
        await fs.rm(temporaryPath, { force: true });
      }
      return outputPath;
    })().finally(() => {
      pdfStreamArtifactTasks.delete(outputPath);
    });
    pdfStreamArtifactTasks.set(outputPath, task);
  }
  return pdfStreamArtifactTasks.get(outputPath);
}

async function trimPdfStreamCache(directory, limitBytes, keepingPath) {
  const names = await fs.readdir(directory).catch(() => []);
  const entries = await Promise.all(names.map(async (name) => {
    const artifactPath = path.join(directory, name);
    const stat = await fs.stat(artifactPath).catch(() => null);
    return stat?.isFile() ? { path: artifactPath, size: stat.size, modifiedAt: stat.mtimeMs } : null;
  }));
  const files = entries.filter(Boolean);
  let totalBytes = files.reduce((sum, file) => sum + file.size, 0);
  if (totalBytes <= limitBytes) return;

  files.sort((left, right) => left.modifiedAt - right.modifiedAt);
  for (const file of files) {
    if (totalBytes <= limitBytes) break;
    if (file.path === keepingPath || pdfStreamArtifactTasks.has(file.path)) continue;
    await fs.rm(file.path, { force: true }).catch(() => {});
    totalBytes -= file.size;
  }
}

async function streamPdfArtifact(res, artifactPath) {
  const stat = await fs.stat(artifactPath);
  res.writeHead(200, {
    "cache-control": "public, max-age=86400",
    "content-length": String(stat.size),
    "content-type": "application/pdf"
  });
  createReadStream(artifactPath).pipe(res);
}

async function renderPdfThumbnail(absolutePath, relativePath, stat, page, crop, highlightQuery, scale, signal) {
  const fileName = pdfThumbnailCacheFileName({
    relativePath,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    page,
    crop,
    highlightQuery,
    scale
  });
  const outputPath = path.join(WORKSPACE_ROOT, ".codmes", "index", "thumbnails", fileName);
  try {
    await fs.access(outputPath);
    return outputPath;
  } catch {}
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.${randomUUID()}.tmp.png`;
  const python = await documentWorkerPython();
  const script = `
import fitz, sys
pdf_path, out_path, page_number = sys.argv[1], sys.argv[2], int(sys.argv[3])
doc = fitz.open(pdf_path)
page_index = max(0, min(page_number - 1, doc.page_count - 1))
page = doc.load_page(page_index)
crop_args = sys.argv[4:8]
crop_values = [float(value) for value in crop_args] if len(crop_args) == 4 and all(crop_args) else []
highlight_query = sys.argv[8].strip() if len(sys.argv) >= 9 else ""
render_scale = float(sys.argv[9]) if len(sys.argv) >= 10 else 0.45
page_rect = page.rect
if highlight_query:
    matches = page.search_for(highlight_query)
    if matches:
        if crop_values:
            x, y, width, height = crop_values
            target_x = page_rect.x0 + (x + width / 2) * page_rect.width
            target_y = page_rect.y0 + (y + height / 2) * page_rect.height
            selected_matches = [match for match in matches if (
                x - 0.01 <= ((match.x0 + match.x1) / 2 - page_rect.x0) / page_rect.width <= x + width + 0.01
                and y - 0.01 <= ((match.y0 + match.y1) / 2 - page_rect.y0) / page_rect.height <= y + height + 0.01
            )]
            if not selected_matches:
                selected_matches = [min(matches, key=lambda rect: (rect.x0 + rect.x1 - 2 * target_x) ** 2 + (rect.y0 + rect.y1 - 2 * target_y) ** 2)]
        else:
            selected_matches = [matches[0]]
        for match in selected_matches:
            visual_top = match.y0 - match.height * 0.82
            visual_bottom = visual_top + match.height * 1.22
            highlight_rect = fitz.Rect(
                max(page_rect.x0, match.x0 - 1.5),
                max(page_rect.y0, visual_top - 0.5),
                min(page_rect.x1, match.x1 + 1.5),
                min(page_rect.y1, visual_bottom + 0.5),
            )
            page.draw_rect(
                highlight_rect,
                color=None,
                fill=(1.0, 0.55, 0.16),
                fill_opacity=0.34,
                overlay=True,
            )
if crop_values:
    x, y, width, height = crop_values
    center_x = x + width / 2
    center_y = y + height / 2
    crop_width = min(1.0, max(0.38, width + 0.10))
    landscape_height = crop_width * page_rect.width / (1.48 * page_rect.height)
    crop_height = min(1.0, max(height + 0.06, landscape_height))
    left = min(max(0.0, center_x - crop_width / 2), 1.0 - crop_width)
    top = min(max(0.0, center_y - crop_height / 2), 1.0 - crop_height)
    clip = fitz.Rect(
        page_rect.x0 + left * page_rect.width,
        page_rect.y0 + top * page_rect.height,
        page_rect.x0 + (left + crop_width) * page_rect.width,
        page_rect.y0 + (top + crop_height) * page_rect.height
    )
    crop_scale = max(1.15, render_scale)
    pix = page.get_pixmap(matrix=fitz.Matrix(crop_scale, crop_scale), clip=clip, alpha=False)
else:
    pix = page.get_pixmap(matrix=fitz.Matrix(render_scale, render_scale), alpha=False)
pix.save(out_path)
doc.close()
`;
  const cropArgs = crop ? [crop.x, crop.y, crop.width, crop.height].map(String) : ["", "", "", ""];
  try {
    await runPythonScript(
      python,
      script,
      [absolutePath, temporaryPath, String(page), ...cropArgs, highlightQuery, String(scale)],
      { signal }
    );
    await fs.rename(temporaryPath, outputPath);
  } finally {
    await fs.rm(temporaryPath, { force: true });
  }
  return outputPath;
}

function pdfThumbnailCrop(url) {
  const values = ["x", "y", "width", "height"].map((name) => Number.parseFloat(url.searchParams.get(name) || ""));
  if (!values.every(Number.isFinite)) return null;
  const [x, y, width, height] = values;
  if (x < 0 || y < 0 || width <= 0 || height <= 0 || x > 1 || y > 1) return null;
  return {
    x: Math.min(1, x),
    y: Math.min(1, y),
    width: Math.min(width, 1 - x),
    height: Math.min(height, 1 - y)
  };
}

function pdfThumbnailScale(url) {
  const value = Number.parseFloat(url.searchParams.get("scale") || "0.45");
  if (!Number.isFinite(value)) return 0.45;
  return Math.min(2.5, Math.max(0.35, value));
}

async function runPythonScript(python, script, args, options = {}) {
  const { spawn } = await import("node:child_process");
  const signal = options.signal;
  if (signal?.aborted) throw abortedOperationError();
  const stdout = [];
  const stderr = [];
  const child = spawn(python, ["-c", script, ...args], {
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env
  });
  const abort = () => child.kill("SIGTERM");
  signal?.addEventListener("abort", abort, { once: true });
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  let code;
  try {
    code = await new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("close", resolve);
    });
  } finally {
    signal?.removeEventListener("abort", abort);
  }
  if (signal?.aborted) throw abortedOperationError();
  if (code !== 0) {
    throw new Error(Buffer.concat(stderr).toString("utf8").trim() || `Python exited with ${code}`);
  }
  return Buffer.concat(stdout).toString("utf8");
}

function abortedOperationError() {
  return Object.assign(new Error("Operation cancelled."), { code: "ABORT_ERR", status: 499 });
}

async function writeTextFile(req, url) {
  const filePath = requireQuery(url, "path");
  const body = await readJsonBody(req);
  const content = typeof body.content === "string" ? body.content : "";
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, content, "utf8");
  await refreshSearchIndexPaths([relativePath]);
  const stat = await fs.stat(absolutePath);
  return {
    ok: true,
    path: relativePath,
    size: stat.size,
    modifiedAt: stat.mtime.toISOString()
  };
}

async function createFile(req) {
  const body = await readJsonBody(req);
  const filePath = body.path;
  if (!filePath) throw Object.assign(new Error("Missing file path."), { status: 400 });
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, typeof body.content === "string" ? body.content : "", { flag: "wx" });
  await refreshSearchIndexPaths([relativePath]);
  return { ok: true, path: relativePath };
}

async function createFolder(req) {
  const body = await readJsonBody(req);
  if (!body.path) throw Object.assign(new Error("Missing folder path."), { status: 400 });
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, body.path);
  await fs.mkdir(absolutePath, { recursive: true });
  await refreshSearchIndexPaths([relativePath]);
  return { ok: true, path: relativePath };
}

async function movePath(req) {
  const body = await readJsonBody(req);
  if (!body.from || !body.to) throw Object.assign(new Error("Missing from or to path."), { status: 400 });
  const from = resolveWorkspacePath(WORKSPACE_ROOT, body.from);
  const to = resolveWorkspacePath(WORKSPACE_ROOT, body.to);
  const movedDocuments = await collectDocumentStateTransitions(from.relativePath, to.relativePath);
  await fs.mkdir(path.dirname(to.absolutePath), { recursive: true });
  await fs.rename(from.absolutePath, to.absolutePath);
  await transferDocumentStateFiles(movedDocuments, { mode: "move" });
  await removeDocumentIngestCacheFiles(WORKSPACE_ROOT, movedDocuments.map((transition) => transition.from));
  await Promise.all(movedDocuments.map((transition) => (
    fs.rm(documentStateDirectory(WORKSPACE_ROOT, transition.from), { recursive: true, force: true })
  )));
  await refreshSearchIndexPaths([from.relativePath, to.relativePath]);
  return { ok: true, from: from.relativePath, to: to.relativePath };
}

async function copyPath(req) {
  const body = await readJsonBody(req);
  if (!body.from || !body.to) throw Object.assign(new Error("Missing from or to path."), { status: 400 });
  const from = resolveWorkspacePath(WORKSPACE_ROOT, body.from);
  const to = resolveWorkspacePath(WORKSPACE_ROOT, body.to);
  const copiedDocuments = await collectDocumentStateTransitions(from.relativePath, to.relativePath);
  await fs.mkdir(path.dirname(to.absolutePath), { recursive: true });
  await fs.cp(from.absolutePath, to.absolutePath, {
    recursive: true,
    errorOnExist: true,
    force: false
  });
  await transferDocumentStateFiles(copiedDocuments, { mode: "copy" });
  await refreshSearchIndexPaths([to.relativePath]);
  return { ok: true, from: from.relativePath, to: to.relativePath };
}

async function uploadFile(req) {
  const body = await readJsonBody(req);
  if (!body.path) throw Object.assign(new Error("Missing file path."), { status: 400 });
  if (typeof body.dataBase64 !== "string") {
    throw Object.assign(new Error("Missing file data."), { status: 400 });
  }
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, body.path);
  await assertPathAvailable(absolutePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, Buffer.from(body.dataBase64, "base64"), { flag: "wx" });
  const documentJob = queueUploadedNotesPdfProcessing(relativePath, absolutePath);
  if (!documentJob) await refreshSearchIndexPaths([relativePath]);
  return { ok: true, path: relativePath, documentJob };
}

async function replaceBinaryFile(req) {
  const body = await readJsonBody(req);
  if (!body.path) throw Object.assign(new Error("Missing file path."), { status: 400 });
  if (typeof body.dataBase64 !== "string") {
    throw Object.assign(new Error("Missing file data."), { status: 400 });
  }
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, body.path);
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot replace a folder."), { status: 400 });
  await fs.writeFile(absolutePath, Buffer.from(body.dataBase64, "base64"));
  const documentJob = queueUploadedNotesPdfProcessing(relativePath, absolutePath);
  if (!documentJob) await refreshSearchIndexPaths([relativePath]);
  return { ok: true, path: relativePath, documentJob };
}

async function importCodmesPdf(req) {
  const body = await readJsonBody(req);
  if (!body.path) throw Object.assign(new Error("Missing PDF path."), { status: 400 });
  if (typeof body.pdfDataBase64 !== "string") {
    throw Object.assign(new Error("Missing PDF data."), { status: 400 });
  }
  const requested = resolveWorkspacePath(WORKSPACE_ROOT, body.path);
  const target = await availableWorkspaceFilePath(requested.relativePath);
  await fs.mkdir(path.dirname(target.absolutePath), { recursive: true });
  await fs.writeFile(target.absolutePath, Buffer.from(body.pdfDataBase64, "base64"), { flag: "wx" });

  let annotations = null;
  if (typeof body.codmesDataBase64 === "string" && body.codmesDataBase64.trim()) {
    const raw = Buffer.from(body.codmesDataBase64, "base64").toString("utf8");
    annotations = normalizeAnnotations(target.relativePath, JSON.parse(raw));
    const targetAnnotationPath = annotationsPathForDocument(WORKSPACE_ROOT, target.relativePath);
    await fs.mkdir(path.dirname(targetAnnotationPath), { recursive: true });
    await fs.writeFile(targetAnnotationPath, JSON.stringify(annotations, null, 2) + "\n", "utf8");
    await ensureDocumentStateManifest(WORKSPACE_ROOT, target.relativePath);
  }

  const documentJob = queueUploadedNotesPdfProcessing(target.relativePath, target.absolutePath);
  if (!documentJob) await refreshSearchIndexPaths([target.relativePath]);
  return {
    ok: true,
    path: target.relativePath,
    requestedPath: requested.relativePath,
    renamed: target.relativePath !== requested.relativePath,
    annotationsImported: Boolean(annotations),
    documentJob
  };
}

async function exportCodmesPdfPackage(req) {
  const body = await readJsonBody(req);
  if (typeof body.pdfDataBase64 !== "string") {
    throw Object.assign(new Error("Missing PDF data."), { status: 400 });
  }
  if (typeof body.codmesDataBase64 !== "string") {
    throw Object.assign(new Error("Missing Codmes annotation data."), { status: 400 });
  }
  let annotations;
  try {
    annotations = JSON.parse(Buffer.from(body.codmesDataBase64, "base64").toString("utf8"));
  } catch {
    throw Object.assign(new Error("Codmes annotation data is invalid."), { status: 400 });
  }
  const title = codmesPdfBaseName(body.name);
  const result = createCodmesPdfPackage({
    pdfData: Buffer.from(body.pdfDataBase64, "base64"),
    annotations,
    title
  });
  return {
    ok: true,
    fileName: `${title}.codmespdf`,
    dataBase64: result.data.toString("base64"),
    manifest: result.manifest
  };
}

async function importCodmesPdfPackage(req) {
  const body = await readJsonBody(req);
  if (typeof body.packageDataBase64 !== "string") {
    throw Object.assign(new Error("Missing Codmes PDF package data."), { status: 400 });
  }
  const packageContents = readCodmesPdfPackage(Buffer.from(body.packageDataBase64, "base64"));
  const requestedName = body.path || `Documents/${codmesPdfBaseName(packageContents.manifest.title)}.pdf`;
  const requested = resolveWorkspacePath(WORKSPACE_ROOT, ensurePdfExtension(requestedName));
  const target = await availableWorkspaceFilePath(requested.relativePath);
  const stateDirectory = documentStateDirectory(WORKSPACE_ROOT, target.relativePath);
  let documentJob = null;
  try {
    await fs.rm(stateDirectory, { recursive: true, force: true });
    await fs.mkdir(path.dirname(target.absolutePath), { recursive: true });
    await fs.writeFile(target.absolutePath, packageContents.pdfData, { flag: "wx" });
    const annotations = normalizeAnnotations(target.relativePath, packageContents.annotations);
    const targetAnnotationPath = annotationsPathForDocument(WORKSPACE_ROOT, target.relativePath);
    await fs.mkdir(path.dirname(targetAnnotationPath), { recursive: true });
    await fs.writeFile(targetAnnotationPath, JSON.stringify(annotations, null, 2) + "\n", "utf8");
    await ensureDocumentStateManifest(WORKSPACE_ROOT, target.relativePath);
    documentJob = queueUploadedNotesPdfProcessing(target.relativePath, target.absolutePath);
    if (!documentJob) await refreshSearchIndexPaths([target.relativePath]);
  } catch (error) {
    await fs.rm(target.absolutePath, { force: true }).catch(() => {});
    await fs.rm(stateDirectory, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
  return {
    ok: true,
    path: target.relativePath,
    requestedPath: requested.relativePath,
    renamed: target.relativePath !== requested.relativePath,
    annotationsImported: true,
    documentJob
  };
}

function codmesPdfBaseName(value) {
  const original = path.posix.basename(String(value || "document").replace(/\\/g, "/"));
  const withoutPackage = original.replace(/\.codmespdf$/i, "");
  const withoutPdf = withoutPackage.replace(/\.pdf$/i, "").trim();
  return withoutPdf || "document";
}

function ensurePdfExtension(value) {
  const normalized = String(value || "").replace(/\\/g, "/");
  return normalized.toLowerCase().endsWith(".pdf") ? normalized : `${normalized}.pdf`;
}

async function startChunkedUpload(req) {
  const body = await readJsonBody(req);
  if (!body.path) throw Object.assign(new Error("Missing file path."), { status: 400 });
  const size = Number(body.size);
  if (!Number.isSafeInteger(size) || size < 0) {
    throw Object.assign(new Error("Missing or invalid file size."), { status: 400 });
  }
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, body.path);
  await assertPathAvailable(absolutePath);
  await fs.mkdir(uploadTempDir(), { recursive: true });
  const uploadId = randomUUID();
  const tempPath = uploadTempPath(uploadId);
  const metaPath = uploadMetaPath(uploadId);
  await fs.writeFile(tempPath, Buffer.alloc(0), { flag: "wx" });
  await fs.writeFile(metaPath, JSON.stringify({
    uploadId,
    path: relativePath,
    size,
    received: 0,
    createdAt: new Date().toISOString()
  }, null, 2) + "\n", { flag: "wx" });
  return { ok: true, uploadId, path: relativePath, received: 0 };
}

async function appendUploadChunk(req) {
  const body = await readJsonBody(req);
  const uploadId = requireUploadId(body.uploadId);
  const offset = Number(body.offset);
  if (!Number.isSafeInteger(offset) || offset < 0) {
    throw Object.assign(new Error("Missing or invalid chunk offset."), { status: 400 });
  }
  if (typeof body.dataBase64 !== "string") {
    throw Object.assign(new Error("Missing chunk data."), { status: 400 });
  }
  const meta = await readUploadMeta(uploadId);
  const buffer = Buffer.from(body.dataBase64, "base64");
  if (offset !== meta.received) {
    throw Object.assign(new Error(`Unexpected chunk offset. Expected ${meta.received}.`), { status: 409 });
  }
  if (offset + buffer.length > meta.size) {
    throw Object.assign(new Error("Chunk exceeds declared upload size."), { status: 400 });
  }
  const handle = await fs.open(uploadTempPath(uploadId), "r+");
  try {
    await handle.write(buffer, 0, buffer.length, offset);
  } finally {
    await handle.close();
  }
  meta.received = offset + buffer.length;
  await writeUploadMeta(uploadId, meta);
  return { ok: true, uploadId, received: meta.received, size: meta.size };
}

async function completeChunkedUpload(req) {
  const body = await readJsonBody(req);
  const uploadId = requireUploadId(body.uploadId);
  const meta = await readUploadMeta(uploadId);
  if (meta.received !== meta.size) {
    throw Object.assign(new Error(`Upload incomplete. Received ${meta.received} of ${meta.size} bytes.`), { status: 400 });
  }
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, meta.path);
  await assertPathAvailable(absolutePath);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.copyFile(uploadTempPath(uploadId), absolutePath, fsConstants.COPYFILE_EXCL);
  await cleanupUpload(uploadId);
  const documentJob = queueUploadedNotesPdfProcessing(relativePath, absolutePath);
  if (!documentJob) await refreshSearchIndexPaths([relativePath]);
  return { ok: true, uploadId, path: relativePath, documentJob };
}

function queueUploadedNotesPdfProcessing(relativePath, absolutePath) {
  const normalized = String(relativePath || "").replace(/\\/g, "/");
  if (!normalized.toLowerCase().startsWith("notes/") || path.extname(normalized).toLowerCase() !== ".pdf") {
    return null;
  }
  const job = startDocumentJob({ path: normalized });
  const run = async () => {
    try {
      const result = await normalizePdfBinaryTextLayer(WORKSPACE_ROOT, absolutePath, normalized, {
        onProgress: (progress) => updateDocumentJob(job.id, progress)
      });
      updateDocumentJob(job.id, {
        stage: "indexing",
        stageLabel: "검색 인덱스 갱신 중",
        progress: 0.96,
        completedUnits: null,
        totalUnits: null
      });
      await refreshSearchIndexPaths([normalized]);
      finishDocumentJob(job.id, {
        status: "completed",
        message: result.normalized
          ? `${result.pages?.length || 0}개 페이지를 정규화했습니다.`
          : "기존 PDF 텍스트 레이어가 정상입니다."
      });
    } catch (error) {
      console.warn(`[codmes] PDF text-layer normalization failed for ${normalized}: ${error?.message || error}`);
      await refreshSearchIndexPaths([normalized]).catch(() => {});
      finishDocumentJob(job.id, {
        status: "failed",
        message: String(error?.message || error)
      });
    }
  };
  setImmediate(() => {
    run().catch((error) => {
      finishDocumentJob(job.id, { status: "failed", message: String(error?.message || error) });
    });
  });
  return {
    id: job.id,
    status: job.status,
    path: job.path,
    title: job.title
  };
}

async function cancelChunkedUpload(req) {
  const body = await readJsonBody(req);
  const uploadId = requireUploadId(body.uploadId);
  await cleanupUpload(uploadId);
  return { ok: true, uploadId };
}

async function deletePath(url) {
  const filePath = requireQuery(url, "path");
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  const deletedDocuments = await collectDocumentPathsForState(relativePath);
  await fs.rm(absolutePath, { recursive: true, force: false });
  await removeDocumentStateFiles(deletedDocuments);
  await refreshSearchIndexPaths([relativePath]);
  return { ok: true, path: relativePath };
}

async function fileMetadata(url) {
  const filePath = requireQuery(url, "path");
  return await readFileMetadata(WORKSPACE_ROOT, filePath);
}

async function readFileAnnotations(url) {
  const filePath = requireQuery(url, "path");
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot annotate a folder."), { status: 400 });
  try {
    return JSON.parse(await fs.readFile(annotationsPath(relativePath), "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    const migrated = await migrateLegacyAnnotations(relativePath);
    if (migrated) return migrated;
    return emptyAnnotations(relativePath);
  }
}

async function availableWorkspaceFilePath(relativePath) {
  const normalized = String(relativePath || "").replace(/\\/g, "/").replace(/^\/+/, "");
  const parsed = path.posix.parse(normalized);
  const directory = parsed.dir;
  const extension = parsed.ext || "";
  const baseName = parsed.name || "document";
  for (let index = 0; index < 1000; index += 1) {
    const candidateName = index === 0 ? `${baseName}${extension}` : `${baseName} ${index + 1}${extension}`;
    const candidatePath = directory ? `${directory}/${candidateName}` : candidateName;
    const resolved = resolveWorkspacePath(WORKSPACE_ROOT, candidatePath);
    const exists = await fs.stat(resolved.absolutePath).then(() => true, () => false);
    if (!exists) return resolved;
  }
  throw Object.assign(new Error(`Could not find available file name for ${relativePath}.`), { status: 409 });
}

async function writeFileAnnotations(req, url) {
  const filePath = requireQuery(url, "path");
  const { relativePath, absolutePath } = resolveWorkspacePath(WORKSPACE_ROOT, filePath);
  const stat = await fs.stat(absolutePath);
  if (stat.isDirectory()) throw Object.assign(new Error("Cannot annotate a folder."), { status: 400 });
  const body = await readJsonBody(req);
  const annotations = normalizeAnnotations(relativePath, body);
  const targetPath = annotationsPath(relativePath);
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, JSON.stringify(annotations, null, 2) + "\n", "utf8");
  await ensureDocumentStateManifest(WORKSPACE_ROOT, relativePath);
  await refreshSearchIndexPaths([relativePath]);
  return annotations;
}

function annotationsPath(relativePath) {
  return annotationsPathForDocument(WORKSPACE_ROOT, relativePath);
}

async function collectDocumentStateTransitions(fromRelativePath, toRelativePath) {
  const fromPaths = await collectDocumentPathsForState(fromRelativePath);
  if (!fromPaths.length) return [];
  const fromPrefix = String(fromRelativePath || "").replace(/\\/g, "/").replace(/\/+$/g, "");
  const toPrefix = String(toRelativePath || "").replace(/\\/g, "/").replace(/\/+$/g, "");
  return fromPaths.map((fromPath) => {
    const suffix = fromPath === fromPrefix ? "" : fromPath.slice(fromPrefix.length).replace(/^\/+/, "");
    return {
      from: fromPath,
      to: suffix ? `${toPrefix}/${suffix}` : toPrefix
    };
  });
}

async function collectDocumentPathsForState(relativePath) {
  const resolved = resolveWorkspacePath(WORKSPACE_ROOT, relativePath);
  const stat = await fs.stat(resolved.absolutePath).catch(() => null);
  if (!stat) return [];
  if (!stat.isDirectory()) return [resolved.relativePath];
  const paths = [];
  await collectFilesUnderDirectory(resolved.absolutePath, resolved.relativePath, paths);
  return paths;
}

async function collectFilesUnderDirectory(absoluteDir, relativeDir, paths) {
  const entries = await fs.readdir(absoluteDir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name === ".codmes") continue;
    const childAbsolute = path.join(absoluteDir, entry.name);
    const childRelative = joinWorkspacePath(relativeDir, entry.name);
    if (entry.isDirectory()) {
      await collectFilesUnderDirectory(childAbsolute, childRelative, paths);
    } else if (entry.isFile()) {
      paths.push(childRelative);
    }
  }
}

async function transferDocumentStateFiles(transitions, { mode }) {
  for (const transition of transitions) {
    const targetPath = annotationsPathForDocument(WORKSPACE_ROOT, transition.to);
    const sourcePath = await existingAnnotationStatePath(transition.from);
    const movedTargetPath = await existingAnnotationStatePath(transition.to);
    const readablePath = sourcePath || movedTargetPath;
    if (!readablePath) continue;
    await fs.mkdir(path.dirname(targetPath), { recursive: true });
    const raw = await fs.readFile(readablePath, "utf8");
    let output = raw;
    try {
      const parsed = JSON.parse(raw);
      parsed.documentPath = transition.to;
      parsed.updatedAt = parsed.updatedAt || new Date().toISOString();
      output = JSON.stringify(parsed, null, 2) + "\n";
    } catch {}
    if (mode === "copy") {
      await fs.writeFile(targetPath, output);
      await ensureDocumentStateManifest(WORKSPACE_ROOT, transition.to);
    } else {
      await fs.writeFile(targetPath, output);
      await ensureDocumentStateManifest(WORKSPACE_ROOT, transition.to);
      await removeAnnotationStateForPath(transition.from);
    }
  }
}

async function removeDocumentStateFiles(relativePaths) {
  await removeDocumentIngestCacheFiles(WORKSPACE_ROOT, relativePaths);
  for (const relativePath of relativePaths) {
    await removeAnnotationStateForPath(relativePath);
  }
}

async function existingAnnotationStatePath(relativePath) {
  for (const candidate of [
    annotationsPathForDocument(WORKSPACE_ROOT, relativePath),
    documentFolderAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath),
    contentScopedAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath),
    legacyAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath)
  ]) {
    try {
      await fs.access(candidate);
      return candidate;
    } catch {}
  }
  return null;
}

async function removeAnnotationStateForPath(relativePath) {
  await Promise.all([
    fs.rm(documentStateDirectory(WORKSPACE_ROOT, relativePath), { recursive: true, force: true }),
    fs.rm(documentFolderAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath), { force: true }),
    fs.rm(contentScopedAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath), { force: true }),
    fs.rm(legacyAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath), { force: true })
  ]);
}

async function migrateLegacyAnnotations(relativePath) {
  const targetPath = annotationsPathForDocument(WORKSPACE_ROOT, relativePath);
  for (const legacyPath of [
    documentFolderAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath),
    contentScopedAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath),
    legacyAnnotationsPathForDocument(WORKSPACE_ROOT, relativePath)
  ]) {
    if (legacyPath === targetPath) continue;
    try {
      const raw = await fs.readFile(legacyPath, "utf8");
      const parsed = JSON.parse(raw);
      await fs.mkdir(path.dirname(targetPath), { recursive: true });
      await fs.writeFile(targetPath, raw, { flag: "wx" }).catch((error) => {
        if (error?.code !== "EEXIST") throw error;
      });
      await ensureDocumentStateManifest(WORKSPACE_ROOT, relativePath);
      const persisted = JSON.parse(await fs.readFile(targetPath, "utf8"));
      await fs.rm(legacyPath, { force: true });
      return persisted || parsed;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  return null;
}

function emptyAnnotations(relativePath) {
  return {
    schemaVersion: 2,
    documentPath: relativePath,
    updatedAt: null,
    pages: [],
    objects: [],
    elements: []
  };
}

function normalizeAnnotations(relativePath, body) {
  return {
    schemaVersion: Number.isSafeInteger(body.schemaVersion) ? Math.max(body.schemaVersion, 2) : 2,
    documentPath: relativePath,
    updatedAt: new Date().toISOString(),
    pages: Array.isArray(body.pages) ? body.pages : [],
    objects: Array.isArray(body.objects) ? body.objects : [],
    elements: Array.isArray(body.elements) ? body.elements : []
  };
}

async function resolveContext(req) {
  const body = await readJsonBody(req);
  return await buildWorkspaceContext(WORKSPACE_ROOT, body);
}

async function indexStatus() {
  const index = await readIndex(WORKSPACE_ROOT);
  const search = searchStatus(WORKSPACE_ROOT);
  return {
    provider: index.provider,
    builtAt: index.builtAt,
    itemCount: index.itemCount || 0,
    indexPath: ".codmes/index/files.json",
    search
  };
}

async function rebuildIndex() {
  const index = await buildIndex(WORKSPACE_ROOT);
  const config = await readSearchConfig();
  const search = await buildSearchIndex(WORKSPACE_ROOT, searchIndexOptions(config));
  return {
    ok: true,
    provider: index.provider,
    builtAt: index.builtAt,
    itemCount: index.itemCount,
    search: {
      provider: search.provider,
      builtAt: search.builtAt,
      itemCount: search.itemCount,
      chunkCount: search.chunkCount,
      indexPath: ".codmes/index/search.json"
    }
  };
}

async function runSearch(req) {
  const body = await readJsonBody(req);
  return await searchWorkspace(WORKSPACE_ROOT, body);
}

async function runGlobalSearch(url) {
  return await globalSearch(WORKSPACE_ROOT, {
    query: url.searchParams.get("q") || url.searchParams.get("query") || "",
    surface: url.searchParams.get("surface") || "all",
    limit: url.searchParams.get("limit") || url.searchParams.get("maxResults") || 100,
    cursor: url.searchParams.get("cursor") || null
  });
}

async function skillsList() {
  const skills = await listSkills(WORKSPACE_ROOT);
  return {
    skills: skills.map((skill) => ({
      name: skill.name,
      enabled: Boolean(skill.config?.enabled),
      triggers: skill.config?.triggers || [],
      taskTypes: skill.config?.taskTypes || []
    }))
  };
}

async function skillDetail(name) {
  return await readSkill(WORKSPACE_ROOT, decodeURIComponent(name));
}

async function setSkillEnabled(name, enabled) {
  await assertSkillExists(name);
  const skill = await enableSkill(WORKSPACE_ROOT, decodeURIComponent(name), enabled);
  return {
    ok: true,
    name: skill.name,
    enabled: Boolean(skill.config?.enabled)
  };
}

async function assertSkillExists(name) {
  const decoded = decodeURIComponent(name);
  const skills = await listSkills(WORKSPACE_ROOT);
  if (!skills.some((skill) => skill.name === decoded)) {
    throw Object.assign(new Error(`Skill not found: ${decoded}`), { status: 404 });
  }
}

async function updateSecurity(req) {
  const body = await readJsonBody(req);
  const current = await readSecurityConfig(WORKSPACE_ROOT);
  const next = {
    approvalMode: body.approvalMode ?? current.approvalMode,
    allowShell: body.allowShell ?? current.allowShell,
    allowedCommands: Array.isArray(body.allowedCommands) ? body.allowedCommands : current.allowedCommands,
    deniedCommands: Array.isArray(body.deniedCommands) ? body.deniedCommands : current.deniedCommands,
    requireApproval: Array.isArray(body.requireApproval) ? body.requireApproval : current.requireApproval
  };
  await writeSecurityConfig(WORKSPACE_ROOT, next);
  return { ok: true, security: next };
}

async function listMcpServers() {
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  return { servers: await Promise.all((config.mcpServers || []).map(normalizeMcpServer)) };
}

async function addMcpServer(req) {
  const body = await readJsonBody(req);
  const name = safeMcpName(body.name);
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  const servers = config.mcpServers || [];
  const next = normalizeMcpRequest({ ...body, name });
  const existingIndex = servers.findIndex((server) => server.name === name);
  if (existingIndex !== -1) {
    servers[existingIndex] = {
      ...servers[existingIndex],
      ...next
    };
    await writeRuntimeConfig(WORKSPACE_ROOT, { ...config, mcpServers: servers });
    return { ok: true, created: false, server: await normalizeMcpServer(servers[existingIndex]) };
  }
  servers.push(next);
  await writeRuntimeConfig(WORKSPACE_ROOT, { ...config, mcpServers: servers });
  return { ok: true, created: true, server: await normalizeMcpServer(servers.at(-1)) };
}

async function updateMcpServer(name, req) {
  const target = safeMcpName(decodeURIComponent(name));
  const body = await readJsonBody(req);
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  const servers = config.mcpServers || [];
  const index = servers.findIndex((item) => item.name === target);
  if (index === -1) throw Object.assign(new Error(`MCP server not found: ${target}`), { status: 404 });

  const current = servers[index];
  const next = normalizeMcpRequest({ ...current, ...body, name: current.name });
  servers[index] = next;
  await writeRuntimeConfig(WORKSPACE_ROOT, { ...config, mcpServers: servers });
  return { ok: true, server: await normalizeMcpServer(next) };
}

async function setMcpEnabled(name, enabled) {
  const target = safeMcpName(decodeURIComponent(name));
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  const servers = config.mcpServers || [];
  const server = servers.find((item) => item.name === target);
  if (!server) throw Object.assign(new Error(`MCP server not found: ${target}`), { status: 404 });
  server.enabled = enabled;
  await writeRuntimeConfig(WORKSPACE_ROOT, { ...config, mcpServers: servers });
  return { ok: true, server: await normalizeMcpServer(server) };
}

async function removeMcpServer(name) {
  const target = safeMcpName(decodeURIComponent(name));
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  const servers = config.mcpServers || [];
  const next = servers.filter((item) => item.name !== target);
  if (next.length === servers.length) {
    throw Object.assign(new Error(`MCP server not found: ${target}`), { status: 404 });
  }
  await writeRuntimeConfig(WORKSPACE_ROOT, { ...config, mcpServers: next });
  return { ok: true, removed: target };
}

async function readSearchConfig() {
  const envPath = codmesSearchEnvPath();
  const env = await readEnvFile(envPath);
  return {
    configPath: envPath,
    roots: normalizeSearchRoots(splitCsv(env.FILE_ROOTS || defaultSearchRoots())),
    includeGlobs: splitCsv(env.FILE_INCLUDE_GLOBS || defaultSearchIncludeGlobs()),
    excludeGlobs: splitCsv(env.FILE_EXCLUDE_GLOBS || defaultSearchExcludeGlobs()),
    embeddingsProvider: env.EMBEDDINGS_PROVIDER || "openai",
    openaiBaseUrl: env.OPENAI_BASE_URL || "http://127.0.0.1:11434/v1",
    openaiApiKeyConfigured: Boolean(env.OPENAI_API_KEY),
    openaiEmbedModel: env.OPENAI_EMBED_MODEL || "bge-m3",
    openaiEmbedDim: Number.parseInt(env.OPENAI_EMBED_DIM || "1024", 10),
    vlmProvider: env.VLM_PROVIDER || "",
    vlmModel: env.VLM_MODEL || "",
    vlmBaseUrl: env.VLM_BASE_URL || "",
    vlmApiKeyConfigured: Boolean(env.VLM_API_KEY),
    dbPath: env.DB_PATH || path.join(WORKSPACE_ROOT, ".codmes", "index", "search.sqlite"),
    backend: env.SEARCH_BACKEND || "codmes"
  };
}

async function updateSearchConfig(req) {
  const body = await readJsonBody(req);
  const envPath = codmesSearchEnvPath();
  const previousEnv = await readEnvFile(envPath);
  const current = await readSearchConfig();
  const roots = normalizeSearchRoots(sanitizeStringList(body.roots, current.roots.length ? current.roots : splitCsv(defaultSearchRoots())));
  const includeGlobs = sanitizeStringList(body.includeGlobs, current.includeGlobs.length ? current.includeGlobs : splitCsv(defaultSearchIncludeGlobs()));
  const excludeGlobs = sanitizeStringList(body.excludeGlobs, current.excludeGlobs.length ? current.excludeGlobs : splitCsv(defaultSearchExcludeGlobs()));
  const nextEnv = {
    FILE_ROOTS: roots.join(","),
    FILE_INCLUDE_GLOBS: includeGlobs.join(","),
    FILE_EXCLUDE_GLOBS: excludeGlobs.join(","),
    SEARCH_BACKEND: "codmes",
    EMBEDDINGS_PROVIDER: String(body.embeddingsProvider || current.embeddingsProvider || "openai").trim(),
    OPENAI_BASE_URL: String(body.openaiBaseUrl || current.openaiBaseUrl || "http://127.0.0.1:11434/v1").trim(),
    OPENAI_API_KEY: body.openaiApiKey !== undefined
      ? String(body.openaiApiKey || "").trim()
      : previousEnv.OPENAI_API_KEY || "",
    OPENAI_EMBED_MODEL: String(body.openaiEmbedModel || current.openaiEmbedModel || "bge-m3").trim(),
    OPENAI_EMBED_DIM: String(body.openaiEmbedDim || current.openaiEmbedDim || "1024").trim(),
    VLM_PROVIDER: String(body.vlmProvider ?? current.vlmProvider ?? "").trim(),
    VLM_MODEL: String(body.vlmModel ?? current.vlmModel ?? "").trim(),
    VLM_BASE_URL: String(body.vlmBaseUrl ?? current.vlmBaseUrl ?? "").trim(),
    VLM_API_KEY: body.vlmApiKey !== undefined
      ? String(body.vlmApiKey || "").trim()
      : previousEnv.VLM_API_KEY || "",
    DB_PATH: String(body.dbPath || current.dbPath || path.join(WORKSPACE_ROOT, ".codmes", "index", "search.sqlite")).trim()
  };
  await fs.mkdir(path.dirname(envPath), { recursive: true });
  await fs.mkdir(path.dirname(nextEnv.DB_PATH), { recursive: true });
  await writeEnvFile(envPath, nextEnv);
  await restartSearchWatchers();

  return { ok: true, ...(await readSearchConfig()) };
}

function codmesSearchEnvPath() {
  return path.join(WORKSPACE_ROOT, ".codmes", "config", "search.env");
}

function defaultSearchRoots() {
  return [
    "Notes",
    "Documents",
    "Code",
    ".codmes/conversation-index",
    ".codmes/sessions"
  ].join(",");
}

function searchIndexOptions(config) {
  return {
    roots: normalizeSearchRoots(config.roots || splitCsv(defaultSearchRoots())),
    embeddingsProvider: config.embeddingsProvider,
    openaiBaseUrl: config.openaiBaseUrl,
    openaiEmbedModel: config.openaiEmbedModel,
    openaiEmbedDim: config.openaiEmbedDim
  };
}

function normalizeSearchRoots(roots) {
  return sanitizeStringList(roots, splitCsv(defaultSearchRoots()))
    .map((root) => {
      const raw = String(root || "").trim();
      if (!raw) return "";
      const absolute = path.isAbsolute(raw) ? raw : path.join(WORKSPACE_ROOT, raw);
      const relative = path.relative(WORKSPACE_ROOT, absolute).replace(/\\/g, "/");
      if (relative.startsWith("..") || path.isAbsolute(relative)) return null;
      return relative === "." ? "" : relative;
    })
    .filter((root) => root !== null)
    .filter((root, index, array) => array.indexOf(root) === index);
}

async function startSearchWatchers() {
  const config = await readSearchConfig().catch(() => null);
  if (!config) return;
  for (const root of normalizeSearchRoots(config.roots)) {
    const absolute = path.join(WORKSPACE_ROOT, root);
    const stat = await fs.stat(absolute).catch(() => null);
    if (!stat?.isDirectory()) continue;
    try {
      const watcher = watch(absolute, { recursive: true }, (_eventType, filename) => {
        if (!filename) {
          queueSearchIndexUpdate(root);
          return;
        }
        queueSearchIndexUpdate(path.join(root, String(filename)).replace(/\\/g, "/"));
      });
      searchWatchers.push(watcher);
      console.log(`[codmes] watching search root ${root || "."}`);
    } catch (error) {
      console.warn(`[codmes] search watcher unavailable for ${root || "."}: ${error?.message || error}`);
    }
  }
}

async function restartSearchWatchers() {
  for (const watcher of searchWatchers.splice(0)) {
    try { watcher.close(); } catch {}
  }
  await startSearchWatchers();
}

function queueSearchIndexUpdate(relativePath) {
  const clean = String(relativePath || "").replace(/\\/g, "/").replace(/^\/+/, "");
  if (!clean || clean.startsWith(".codmes/index/")) return;
  pendingSearchUpdates.add(documentPathForAnnotationStatePath(clean) || clean);
  clearTimeout(searchUpdateTimer);
  searchUpdateTimer = setTimeout(async () => {
    const changed = Array.from(pendingSearchUpdates);
    pendingSearchUpdates.clear();
    await refreshSearchIndexPaths(changed);
  }, 750);
}

async function refreshSearchIndexPaths(pathsToRefresh) {
  const paths = Array.from(new Set([].concat(pathsToRefresh || [])
    .map((item) => String(item || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, ""))
    .filter((item) => item && !item.startsWith(".codmes/"))));
  if (!paths.length) return null;
  const run = async () => {
    const config = await readSearchConfig().catch(() => null);
    return await updateSearchIndex(WORKSPACE_ROOT, paths, searchIndexOptions(config || {}));
  };
  const next = searchIndexUpdateChain.then(run, run).catch((error) => {
    console.warn(`[codmes] search partial index update failed: ${error?.message || error}`);
    return null;
  });
  searchIndexUpdateChain = next.then(() => undefined, () => undefined);
  return await next;
}

function documentPathForAnnotationStatePath(relativePath) {
  const clean = String(relativePath || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  const marker = "/.codmes/annotations/";
  const markerIndex = clean.indexOf(marker);
  if (markerIndex < 0 || !clean.toLowerCase().endsWith(".codmes.json")) return null;
  const parent = clean.slice(0, markerIndex);
  const stateName = path.posix.basename(clean).replace(/\.codmes\.json$/i, ".pdf");
  return parent ? `${parent}/${stateName}` : stateName;
}

function defaultSearchIncludeGlobs() {
  return [
    "**/*.md", "**/*.mdx", "**/*.txt", "**/*.json", "**/*.jsonl", "**/*.yaml", "**/*.yml",
    "**/*.js", "**/*.mjs", "**/*.ts", "**/*.tsx", "**/*.py", "**/*.swift", "**/*.java",
    "**/*.c", "**/*.cpp", "**/*.h", "**/*.hpp", "**/*.rs", "**/*.go", "**/*.pdf"
  ].join(",");
}

function defaultSearchExcludeGlobs() {
  return [
    "**/.git/**", "**/node_modules/**", "**/dist/**", "**/build/**", "**/target/**",
    "**/DerivedData/**", "**/.next/**", "**/.venv/**", "**/venv/**", "**/__pycache__/**"
  ].join(",");
}

async function doctorStatus() {
  const [config, security, skills, index, audit] = await Promise.all([
    readRuntimeConfig(WORKSPACE_ROOT),
    readSecurityConfig(WORKSPACE_ROOT),
    listSkills(WORKSPACE_ROOT),
    readIndex(WORKSPACE_ROOT),
    readAuditSummary(WORKSPACE_ROOT)
  ]);
  return {
    ok: true,
    service: "codmes",
    workspaceRoot: WORKSPACE_ROOT,
    authRequired: Boolean(SERVER_TOKEN),
    runtime: {
      defaultModel: config.defaultModel,
      fallbackChain: config.fallbackChain || [],
      disabledTools: config.disabledTools || []
    },
    mcp: {
      count: (config.mcpServers || []).length,
      enabledCount: (config.mcpServers || []).filter((server) => server.enabled !== false).length
    },
    skills: {
      count: skills.length,
      enabledCount: skills.filter((skill) => skill.config?.enabled).length
    },
    security,
    index: {
      builtAt: index.builtAt,
      itemCount: index.itemCount || 0
    },
    audit,
    search: searchStatus(WORKSPACE_ROOT),
    documentIngest: await documentIngestDiagnostics()
  };
}

async function documentIngestDiagnostics() {
  const python = await documentWorkerPython();
  return {
    python,
    requirements: "server/workers/document-ingest/requirements.txt",
    libraries: await pythonLibraryDiagnostics(python, [
      "fitz",
      "pymupdf4llm",
      "PIL",
      "openpyxl",
      "docx",
      "pptx",
      "markitdown"
    ]),
    notes: [
      "Codmes core document extraction uses runtime Python libraries only.",
      "PyMuPDF4LLM provides the KNU-style PDF-to-Markdown/table extraction layer without Java-based ODL.",
      "Native OCR and office-conversion binaries such as tesseract, pdftoppm, LibreOffice, and soffice are not part of the core dependency path.",
      "MarkItDown is used through its default local/free converter path."
    ]
  };
}

async function documentWorkerPython() {
  if (process.env.CODMES_PYTHON) return process.env.CODMES_PYTHON;
  if (process.env.PYTHON) return process.env.PYTHON;
  const bundled = path.join(REPO_ROOT, ".codmes-runtime", process.platform === "win32" ? "Scripts/python.exe" : "bin/python");
  try {
    await fs.access(bundled);
    return bundled;
  } catch {
    return "python3";
  }
}

async function pythonLibraryDiagnostics(python, modules) {
  const { spawnSync } = await import("node:child_process");
  const script = [
    "import importlib.util, json",
    `mods = ${JSON.stringify(modules)}`,
    "print(json.dumps({m: bool(importlib.util.find_spec(m)) for m in mods}))"
  ].join("\n");
  const result = spawnSync(python, ["-c", script], { encoding: "utf8" });
  if (result.error || result.status !== 0) {
    return Object.fromEntries(modules.map((module) => [module, false]));
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    return Object.fromEntries(modules.map((module) => [module, false]));
  }
}

async function listRuntimeProviders() {
  const [providers, credentials, config] = await Promise.all([
    Promise.resolve(listProviderRegistry()),
    listCredentialStatus(WORKSPACE_ROOT),
    readRuntimeConfig(WORKSPACE_ROOT)
  ]);
  const credentialMap = new Map(credentials.map((item) => [item.provider, item]));
  return {
    providers: providers.map((provider) => ({
      ...provider,
      configured: Boolean(credentialMap.get(provider.id)?.configured),
      storedKeys: credentialMap.get(provider.id)?.storedKeys || [],
      envKeys: credentialMap.get(provider.id)?.envKeys || [],
      isDefault: config.defaultModel?.provider === provider.id
    }))
  };
}

async function discoverProviderModels(providerParam) {
  const providerId = decodeURIComponent(providerParam);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 404 });
  }

  if (providerId === "ollama-local") {
    const credentials = await readCredentials(WORKSPACE_ROOT);
    const values = credentials.providers?.[providerId]?.values || {};
    const configuredUrl = values.baseUrl || values.BASE_URL || values.OLLAMA_HOST || process.env.OLLAMA_HOST || provider.defaultBaseUrl;
    const host = String(configuredUrl || "http://127.0.0.1:11434")
      .replace(/\/v1\/?$/, "")
      .replace(/\/$/, "");
    let response;
    try {
      response = await fetch(`${host}/api/tags`, { signal: AbortSignal.timeout(5000) });
    } catch (error) {
      throw Object.assign(new Error(`Could not connect to Ollama at ${host}: ${error.message}`), { status: 502 });
    }
    if (!response.ok) {
      throw Object.assign(new Error(`Ollama model discovery failed: ${response.status}`), { status: 502 });
    }
    const payload = await response.json();
    const models = (payload.models || [])
      .filter((item) => {
        const capabilities = Array.isArray(item.capabilities) ? item.capabilities : [];
        return capabilities.length === 0 || capabilities.some((capability) => ["completion", "tools", "thinking"].includes(capability));
      })
      .map((item) => item.model || item.name)
      .filter(Boolean);
    return { provider: providerId, source: "ollama", baseUrl: `${host}/v1`, models };
  }

  if (providerId === "openai-codex") {
    return {
      ...(await discoverCodexModelIds({
        workspaceRoot: WORKSPACE_ROOT,
        fallbackModels: provider.models || []
      })),
      baseUrl: provider.defaultBaseUrl || null
    };
  }

  return {
    provider: providerId,
    source: "registry",
    baseUrl: provider.defaultBaseUrl || null,
    models: provider.models || []
  };
}

async function listRuntimeAuth() {
  return {
    providers: await listCredentialStatus(WORKSPACE_ROOT)
  };
}

async function startProviderOAuthLogin(providerId) {
  if (providerId !== "openai-codex") {
    throw Object.assign(new Error(`OAuth login is not implemented for provider: ${providerId}`), { status: 400 });
  }
  return await startCodexOAuthLogin({ workspaceRoot: WORKSPACE_ROOT });
}

async function readProviderAuth(providerParam) {
  const providerId = decodeURIComponent(providerParam);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
  }
  return {
    provider: providerId,
    credentials: await listProviderCredentialEntries(WORKSPACE_ROOT, providerId)
  };
}

async function selectProviderAuth(providerParam, req) {
  const providerId = decodeURIComponent(providerParam);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
  }
  const body = await readJsonBody(req);
  const credentialId = String(body.credentialId || body.id || "").trim();
  if (!credentialId) {
    throw Object.assign(new Error("credentialId is required."), { status: 400 });
  }
  const selected = await selectProviderCredentialEntry(WORKSPACE_ROOT, providerId, credentialId);
  return { ok: true, provider: providerId, selected };
}

async function deleteProviderAuthCredential(providerParam, credentialParam) {
  const providerId = decodeURIComponent(providerParam);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
  }
  const credentialId = decodeURIComponent(credentialParam);
  return await removeProviderCredentialEntry(WORKSPACE_ROOT, providerId, credentialId);
}

async function deleteProviderAuthAll(providerParam) {
  const providerId = decodeURIComponent(providerParam);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
  }
  return await removeCredentialValue(WORKSPACE_ROOT, providerId);
}

async function readDefaultModel() {
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  return {
    defaultModel: config.defaultModel || null
  };
}

async function updateDefaultModel(req) {
  const body = await readJsonBody(req);
  const provider = String(body.provider || "").trim();
  const model = String(body.model || body.name || "").trim();
  if (!provider || !model) {
    throw Object.assign(new Error("provider and model are required."), { status: 400 });
  }
  const config = await readRuntimeConfig(WORKSPACE_ROOT);
  const defaultModel = {
    provider,
    model,
    id: `${provider}:${model}`,
    baseUrl: body.baseUrl === undefined ? config.defaultModel?.baseUrl : String(body.baseUrl || ""),
    apiMode: body.apiMode === undefined ? config.defaultModel?.apiMode : String(body.apiMode || "")
  };
  await writeRuntimeConfig(WORKSPACE_ROOT, { ...config, defaultModel });
  return { ok: true, defaultModel };
}

async function updateProviderAuth(providerParam, req) {
  const providerId = decodeURIComponent(providerParam);
  const body = await readJsonBody(req);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
  }

  const rawValues = body.values && typeof body.values === "object" ? body.values : body;
  const entries = [];
  for (const [rawKey, rawValue] of Object.entries(rawValues || {})) {
    if (["values", "provider"].includes(rawKey)) continue;
    if (rawValue === undefined || rawValue === null) continue;
    const value = String(rawValue);
    if (!value && body.removeEmpty === true) continue;
    entries.push([providerCredentialKey(provider, rawKey), value]);
  }

  if (entries.length === 0 && body.key) {
    entries.push([providerCredentialKey(provider, body.key), String(body.value || "")]);
  }
  if (entries.length === 0) {
    throw Object.assign(new Error("No credential values provided."), { status: 400 });
  }

  const stored = [];
  for (const [key, value] of entries) {
    stored.push(await setCredentialValue(WORKSPACE_ROOT, providerId, key, value));
  }
  return { ok: true, provider: providerId, stored };
}

async function deleteProviderAuth(providerParam, keyParam) {
  const providerId = decodeURIComponent(providerParam);
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) {
    throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });
  }
  const key = providerCredentialKey(provider, decodeURIComponent(keyParam));
  return await removeCredentialValue(WORKSPACE_ROOT, providerId, key);
}

async function createCustomProvider(req) {
  const body = await readJsonBody(req);
  const id = String(body.id || "custom").trim();
  if (id !== "custom") {
    throw Object.assign(new Error("This preview build supports the built-in custom provider id only."), { status: 400 });
  }
  const stored = [];
  if (body.baseUrl) {
    stored.push(await setCredentialValue(WORKSPACE_ROOT, "custom", "CODMES_CUSTOM_BASE_URL", String(body.baseUrl)));
  }
  if (body.apiKey || body.token) {
    stored.push(await setCredentialValue(WORKSPACE_ROOT, "custom", "CODMES_CUSTOM_API_KEY", String(body.apiKey || body.token)));
  }
  if (body.model) {
    await setDefaultModel(WORKSPACE_ROOT, "custom", String(body.model));
  }
  return { ok: true, provider: { id: "custom", name: body.name || "Custom OpenAI-compatible" }, stored };
}

async function deleteCustomProvider(idParam) {
  const id = decodeURIComponent(idParam);
  if (id !== "custom") {
    throw Object.assign(new Error("This preview build supports the built-in custom provider id only."), { status: 404 });
  }
  return await removeCredentialValue(WORKSPACE_ROOT, "custom");
}

function providerCredentialKey(provider, rawKey) {
  const key = String(rawKey || "").trim();
  const normalized = key.toLowerCase();
  if (provider.id === "custom") {
    if (["baseurl", "base_url", "url", "endpoint"].includes(normalized)) return "CODMES_CUSTOM_BASE_URL";
    if (["apikey", "api_key", "token", "access_token", "key"].includes(normalized)) return "CODMES_CUSTOM_API_KEY";
  }
  if (["baseurl", "base_url", "url", "endpoint"].includes(normalized) && provider.baseUrlEnv) {
    return providerBaseUrlKeys(provider)[0] || provider.baseUrlEnv;
  }
  if (["apikey", "api_key", "token", "access_token", "key"].includes(normalized)) {
    return providerEnvKeys(provider)[0] || key;
  }
  return key;
}

function safeMcpName(value) {
  const name = String(value || "").trim();
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw Object.assign(new Error("MCP server name must contain only letters, numbers, dashes, and underscores."), { status: 400 });
  }
  return name;
}

function normalizeMcpRequest(server) {
  try { return normalizeMcpServerConfig(server); }
  catch (error) { throw Object.assign(error, { status: 400 }); }
}

async function normalizeMcpServer(server = {}) {
  const normalized = normalizeMcpRequest(server);
  if (normalized.transport === "streamable_http") {
    return { ...normalized, credentialConfigured: await getMcpCredentialStatus(WORKSPACE_ROOT, normalized.credential_id) };
  }
  return normalized;
}

function parseLooseBoolean(value, fallback = false) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "1", "yes", "on"].includes(normalized)) return true;
    if (["false", "0", "no", "off"].includes(normalized)) return false;
  }
  return fallback;
}

function sanitizeStringMap(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value)
      .map(([key, val]) => [String(key).trim(), String(val ?? "").trim()])
      .filter(([key, val]) => key && val)
  );
}

async function readEnvFile(filePath) {
  try {
    const content = await fs.readFile(filePath, "utf8");
    const result = {};
    for (const line of content.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const index = trimmed.indexOf("=");
      if (index === -1) continue;
      result[trimmed.slice(0, index)] = trimmed.slice(index + 1);
    }
    return result;
  } catch {
    return {};
  }
}

async function writeEnvFile(filePath, values) {
  const lines = Object.entries(values)
    .filter(([key, value]) => key && value !== undefined && value !== null && String(value).trim())
    .map(([key, value]) => `${key}=${String(value).replace(/\r?\n/g, " ")}`);
  await fs.writeFile(filePath, `${lines.join("\n")}\n`, "utf8");
}

function splitCsv(value) {
  return String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function sanitizeStringList(value, fallback = []) {
  if (!Array.isArray(value)) return fallback;
  const result = value.map((item) => String(item || "").trim()).filter(Boolean);
  return result.length ? result : fallback;
}

async function createCodeTask(req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.inspectCodeTask(body);
  } finally {
    engine.close();
  }
}

async function listAgentTasks(url) {
  const engine = createAgentEngine();
  try {
    return await engine.listTasks({
      type: url.searchParams.get("type") || "",
      limit: url.searchParams.get("limit") || ""
    });
  } finally {
    engine.close();
  }
}

async function readAgentTask(taskId) {
  const engine = createAgentEngine();
  try {
    return await engine.readTask(decodeURIComponent(taskId));
  } finally {
    engine.close();
  }
}

async function resumeAgentTask(taskId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.resumeTask(decodeURIComponent(taskId), body);
  } finally {
    engine.close();
  }
}

async function cancelAgentTask(taskId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.cancelTask(decodeURIComponent(taskId), body);
  } finally {
    engine.close();
  }
}

async function listAgentApprovals(url) {
  const engine = createAgentEngine();
  try {
    return await engine.listApprovals({
      status: url.searchParams.get("status") || "",
      category: url.searchParams.get("category") || "",
      taskId: url.searchParams.get("taskId") || "",
      limit: url.searchParams.get("limit") || ""
    });
  } finally {
    engine.close();
  }
}

async function readAgentApproval(approvalId) {
  const engine = createAgentEngine();
  try {
    return await engine.readApproval(decodeURIComponent(approvalId));
  } finally {
    engine.close();
  }
}

async function respondToAgentApproval(approvalId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.respondToWorkspaceApproval(decodeURIComponent(approvalId), body);
  } finally {
    engine.close();
  }
}

async function runCodeTaskChecks(taskId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.runCodeTaskChecks(decodeURIComponent(taskId), body);
  } finally {
    engine.close();
  }
}

async function runCodeTaskGit(taskId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.runCodeTaskGit(decodeURIComponent(taskId), body);
  } finally {
    engine.close();
  }
}

async function proposeCodeTaskPatch(taskId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.proposeCodeTaskPatch(decodeURIComponent(taskId), body);
  } finally {
    engine.close();
  }
}

async function generateCodeTaskPatch(taskId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.generateCodeTaskPatch(decodeURIComponent(taskId), body);
  } finally {
    engine.close();
  }
}

async function applyCodeTaskPatch(taskId, proposalId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.applyCodeTaskPatch(decodeURIComponent(taskId), {
      ...body,
      proposalId: decodeURIComponent(proposalId)
    });
  } finally {
    engine.close();
  }
}

async function rejectCodeTaskPatch(taskId, proposalId, req) {
  const body = await readJsonBody(req);
  const engine = createAgentEngine();
  try {
    return await engine.rejectCodeTaskPatch(decodeURIComponent(taskId), {
      ...body,
      proposalId: decodeURIComponent(proposalId)
    });
  } finally {
    engine.close();
  }
}

async function summarizeSession(sessionIdParam) {
  const sessionId = decodeURIComponent(sessionIdParam);
  const filePath = path.join(WORKSPACE_ROOT, ".codmes", "sessions", `${sessionId}.json`);
  const session = JSON.parse(await fs.readFile(filePath, "utf8"));
  const { buildSessionSummary } = await import("./lib/session-runtime.mjs");
  const summary = buildSessionSummary(session);
  session.summary = summary;
  session.updatedAt = new Date().toISOString();
  await fs.writeFile(filePath, JSON.stringify(session, null, 2), "utf8");
  const { indexSession } = await import("./lib/runtime/conversation-index.mjs");
  await indexSession(WORKSPACE_ROOT, session);
  return { ok: true, sessionId, summary };
}

async function extractMemoryFromSession(sessionIdParam) {
  const sessionId = String(sessionIdParam || "").trim();
  if (!sessionId) throw Object.assign(new Error("sessionId is required."), { status: 400 });
  const filePath = path.join(WORKSPACE_ROOT, ".codmes", "sessions", `${sessionId}.json`);
  const session = JSON.parse(await fs.readFile(filePath, "utf8"));
  const { updateMemoryFromSession } = await import("./lib/runtime/memory-retrieval.mjs");
  return await updateMemoryFromSession(WORKSPACE_ROOT, session);
}

async function renderMarkdown(req) {
  const body = await readJsonBody(req);
  const html = await renderMarkdownDocument(body.markdown || body.content || "", {
    theme: body.theme || "github-dark"
  });
  return { html };
}

async function renderCode(req) {
  const body = await readJsonBody(req);
  const html = await renderCodeDocument(body.code || body.content || "", {
    language: body.language || "",
    theme: body.theme || "github-dark"
  });
  return { html };
}

async function handleRuntimeProxy(req, res, url) {
  const engine = createAgentEngine();
  try {
    const isModels = url.pathname === "/api/models" || url.pathname === "/api/workspace/models";
    const isSessionsGet = url.pathname === "/api/sessions" && req.method === "GET";
    const isSessionsPost = url.pathname === "/api/sessions" && req.method === "POST";
    const isSessionsPrune = url.pathname === "/api/sessions/prune" && req.method === "POST";
    
    const messagesMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/messages$/);
    const sessionMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)$/);
    const renameMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/rename$/);
    const exportMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/export$/);

    if (isModels && req.method === "GET") {
      return sendJson(res, await engine.listModels());
    }
    if (isSessionsGet) {
      return sendJson(res, await normalizeSessionsResponse(await engine.listSessions(200)));
    }
    if (isSessionsPrune) {
      return sendJson(res, await engine.pruneSessions());
    }
    if (messagesMatch && req.method === "GET") {
      const sessionId = decodeURIComponent(messagesMatch[1]);
      return sendJson(res, normalizeSessionMessagesResponse(
        await engine.getSessionMessages(sessionId)
      ));
    }
    if (sessionMatch && req.method === "DELETE") {
      const sessionId = decodeURIComponent(sessionMatch[1]);
      return sendJson(res, await engine.deleteSession(sessionId));
    }
    if (renameMatch && req.method === "POST") {
      const sessionId = decodeURIComponent(renameMatch[1]);
      const body = await readJsonBody(req);
      return sendJson(res, await engine.renameSession(sessionId, body.title));
    }
    if (exportMatch && req.method === "GET") {
      const sessionId = decodeURIComponent(exportMatch[1]);
      return sendJson(res, await engine.exportSession(sessionId));
    }
    if (isSessionsPost) {
      const body = await readJsonBody(req);
      return sendJson(res, await engine.createSession(body), 201);
    }
    throw Object.assign(new Error("Unknown Codmes runtime endpoint."), { status: 404 });
  } finally {
    engine.close();
  }
}

async function normalizeSessionsResponse(value) {
  const source = Array.isArray(value?.sessions) ? value.sessions
    : Array.isArray(value?.items) ? value.items
      : Array.isArray(value?.data) ? value.data
        : Array.isArray(value) ? value
          : [];
  const folderTitleById = new Map();
  try {
    const { listFolders } = await import("./lib/runtime/conversation-folders.mjs");
    for (const folder of await listFolders(WORKSPACE_ROOT)) {
      folderTitleById.set(folder.id, folder.name);
    }
  } catch {}
  const seen = new Set();
  const sessions = [];
  for (const item of source) {
    if (!item || typeof item !== "object" || item.archived) continue;
    const id = stringField(item.id, item.session_id, item.sessionId, item.stored_session_id, item.storedSessionId);
    if (!id || seen.has(id)) continue;
    const preview = stringField(item.preview);
    const messageCount = Number(item.message_count ?? item.messageCount ?? 0);
    const explicitTitle = stringField(item.display_name, item.displayName, item.title, item.name, item.summary);
    const title = explicitTitle || preview
      || fallbackSessionTitle(item.model, id);
    const folderId = stringField(item.folder_id, item.folderId);
    const folderTitle = stringField(item.folder_title, item.folderTitle) || (folderId ? folderTitleById.get(folderId) : "");
    seen.add(id);
    sessions.push({
      id,
      title,
      model: stringField(item.model),
      preview,
      folderId,
      folderTitle,
      projectId: stringField(item.project_id, item.projectId, item.project?.id, item.workspace_id, item.workspaceId, item.scope_id, item.scopeId),
      projectTitle: stringField(item.project_title, item.projectTitle, item.project?.title, item.project?.name, item.workspace_title, item.workspaceTitle, item.workspace?.title, item.workspace?.name, item.cwd, item.git_repo_root, item.gitRepoRoot),
      updatedAt: stringField(item.updated_at, item.updatedAt, item.modified_at, item.modifiedAt, item.last_active, item.lastActive),
      pinned: Boolean(item.pinned),
      isActive: Boolean(item.is_active ?? item.isActive)
    });
  }
  return { sessions };
}

function normalizeSessionMessagesResponse(value) {
  const source = Array.isArray(value?.messages) ? value.messages
    : Array.isArray(value?.items) ? value.items
      : Array.isArray(value?.data) ? value.data
        : Array.isArray(value) ? value
          : [];
  const messages = [];
  for (const item of source) {
    if (!item || typeof item !== "object") continue;
    const role = stringField(item.role, item.type);
    const content = stringField(item.content, item.text, item.message, item.rendered);
    if (!role || !content) continue;
    messages.push({
      id: stringField(item.id, item.message_id, item.messageId) || `${messages.length}`,
      role,
      content,
      timestamp: stringField(item.timestamp, item.created_at, item.createdAt),
      toolName: stringField(item.tool_name, item.toolName, item.name),
      finishReason: stringField(item.finish_reason, item.finishReason),
      reasoning: stringField(item.reasoning, item.reasoning_content, item.reasoningContent)
    });
  }
  return {
    sessionId: stringField(value?.session_id, value?.sessionId),
    messages
  };
}

function fallbackSessionTitle(model, id) {
  if (model) return `Chat with ${model}`;
  const date = generatedSessionDate(id);
  return date ? `Chat ${date}` : "Untitled chat";
}

function generatedSessionDate(value) {
  const match = String(value || "").match(/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_/);
  return match ? `${match[1]}-${match[2]}-${match[3]} ${match[4]}:${match[5]}` : "";
}

function stringField(...values) {
  for (const value of values) {
    if (value === undefined || value === null) continue;
    const text = String(value).trim();
    if (text && text !== "<null>") return text;
  }
  return "";
}

function uploadTempDir() {
  return path.join(WORKSPACE_ROOT, ".codmes", "uploads");
}

function requireUploadId(value) {
  const uploadId = String(value || "");
  if (!/^[0-9a-f-]{36}$/i.test(uploadId)) {
    throw Object.assign(new Error("Missing or invalid upload id."), { status: 400 });
  }
  return uploadId;
}

function uploadTempPath(uploadId) {
  return path.join(uploadTempDir(), `${uploadId}.part`);
}

function uploadMetaPath(uploadId) {
  return path.join(uploadTempDir(), `${uploadId}.json`);
}

async function readUploadMeta(uploadId) {
  try {
    return JSON.parse(await fs.readFile(uploadMetaPath(uploadId), "utf8"));
  } catch {
    throw Object.assign(new Error("Upload session not found."), { status: 404 });
  }
}

async function writeUploadMeta(uploadId, meta) {
  await fs.writeFile(uploadMetaPath(uploadId), JSON.stringify(meta, null, 2) + "\n", "utf8");
}

async function cleanupUpload(uploadId) {
  await fs.rm(uploadTempPath(uploadId), { force: true });
  await fs.rm(uploadMetaPath(uploadId), { force: true });
}

async function assertPathAvailable(absolutePath) {
  try {
    await fs.access(absolutePath);
  } catch {
    return;
  }
  throw Object.assign(new Error("A file or folder already exists at that path."), { status: 409 });
}

async function fetchPluginViewDocument(pluginId, routeId) {
  const {
    resolvePluginViewDocumentTarget,
    resolveViewDocumentTarget
  } = await import("./lib/runtime/plugin-registry.mjs");
  const { getRuntimeContribution } = await import("./lib/runtime/plugin-runtime.mjs");
  const { renderPluginViewDocument } = await import("./lib/runtime/plugin-view-renderer.mjs");
  const { getPluginCredential } = await import("./lib/runtime/config-store.mjs");
  const runtimeContribution = await getRuntimeContribution(WORKSPACE_ROOT, pluginId);
  const { manifest, navigation, uiRoute, url } = runtimeContribution
    ? resolveViewDocumentTarget(runtimeContribution, routeId)
    : await resolvePluginViewDocumentTarget(WORKSPACE_ROOT, pluginId, routeId);
  if (manifest.surface.type !== "declarative") {
    throw Object.assign(new Error("Plugin does not provide a declarative surface."), { status: 400 });
  }
  const credential = manifest.surface.auth
    ? await getPluginCredential(WORKSPACE_ROOT, manifest.surface.auth.credentialId)
    : null;
  if (navigation.requiresAuth && !credential) {
    return {
      schemaVersion: 1,
      presentation: "collection",
      title: navigation.title,
      subtitle: "사이드바 상단의 로그인 버튼을 눌러 플러그인 계정을 연결하세요.",
      filters: [],
      items: [],
      emptyState: {
        title: "로그인이 필요합니다.",
        systemImage: "person.crop.circle.badge.exclamationmark"
      }
    };
  }
  if (uiRoute) {
    const entries = await Promise.all(uiRoute.dataSources.map(async (source) => {
      if (source.path.startsWith("collection:")) {
        const { readPluginCollection } = await import("./lib/runtime/plugin-collection-store.mjs");
        return [
          source.id,
          await readPluginCollection(WORKSPACE_ROOT, manifest, source.path.slice("collection:".length))
        ];
      }
      const sourceUrl = new URL(source.path, manifest.surface.upstreamUrl);
      return [source.id, await fetchPluginSurfaceJson(sourceUrl, credential)];
    }));
    const document = renderPluginViewDocument(uiRoute, Object.fromEntries(entries));
    validatePluginViewDocument(document);
    return document;
  }
  const document = await fetchPluginSurfaceJson(url, credential);
  validatePluginViewDocument(document);
  return document;
}

async function mutateInstalledPluginCollection(pluginId, collectionId, operation, args) {
  const { mutatePluginCollection } = await import("./lib/runtime/plugin-collection-store.mjs");
  const manifest = await resolveCollectionProvider(pluginId);
  return await mutatePluginCollection(
    WORKSPACE_ROOT,
    manifest,
    collectionId,
    operation,
    args
  );
}

async function resolveCollectionProvider(providerId) {
  const { getRuntimeContribution } = await import("./lib/runtime/plugin-runtime.mjs");
  const { getInstalledPlugin } = await import("./lib/runtime/plugin-registry.mjs");
  const manifest = await getRuntimeContribution(WORKSPACE_ROOT, providerId)
    || await getInstalledPlugin(WORKSPACE_ROOT, providerId);
  if (!manifest) {
    throw Object.assign(new Error("Surface data provider is not available."), { status: 404 });
  }
  return manifest;
}

async function fetchPluginSurfaceJson(url, credential) {
  let response;
  try {
    response = await fetch(url, {
      headers: {
        accept: "application/json",
        ...(credential ? { authorization: `Bearer ${credential.token}` } : {})
      },
      redirect: "error",
      signal: AbortSignal.timeout(15_000)
    });
  } catch (error) {
    throw Object.assign(new Error(`Plugin data source is unavailable: ${error.message}`), { status: 502 });
  }
  if (!response.ok) {
    throw Object.assign(
      new Error(`Plugin data source returned ${response.status}.`),
      { status: 502 }
    );
  }
  const text = await response.text();
  if (Buffer.byteLength(text, "utf8") > 2 * 1024 * 1024) {
    throw Object.assign(new Error("Plugin data source response is too large."), { status: 502 });
  }
  let document;
  try {
    document = JSON.parse(text);
  } catch {
    throw Object.assign(new Error("Plugin data source returned invalid JSON."), { status: 502 });
  }
  return document;
}

async function pluginAuthStatus(pluginId) {
  const { getInstalledPlugin } = await import("./lib/runtime/plugin-registry.mjs");
  const { getPluginCredential, removePluginCredential } = await import("./lib/runtime/config-store.mjs");
  const plugin = await getInstalledPlugin(WORKSPACE_ROOT, pluginId);
  if (!plugin) throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  const auth = plugin.surface.auth;
  if (!auth) return { supported: false, authenticated: false, username: null };
  const credential = await getPluginCredential(WORKSPACE_ROOT, auth.credentialId);
  if (!credential) return { supported: true, authenticated: false, username: null };
  const url = new URL(auth.statusPath, plugin.surface.upstreamUrl);
  try {
    const response = await fetch(url, {
      headers: { accept: "application/json", authorization: `Bearer ${credential.token}` },
      redirect: "error",
      signal: AbortSignal.timeout(10_000)
    });
    if (response.status === 401 || response.status === 403) {
      await removePluginCredential(WORKSPACE_ROOT, auth.credentialId);
      return { supported: true, authenticated: false, username: null };
    }
    if (!response.ok) {
      return {
        supported: true,
        authenticated: true,
        username: credential.username,
        reachable: false
      };
    }
    const profile = await response.json().catch(() => ({}));
    return {
      supported: true,
      authenticated: true,
      username: String(profile.username || credential.username || "") || null,
      reachable: true,
      studentId: String(profile.student_id || "") || null,
      name: String(profile.name || "") || null,
      major: String(profile.major || "") || null,
      year: Number.isInteger(profile.year) ? profile.year : null,
      profileSyncing: Boolean(
        profile.portal_syncing ?? (profile.student_id && !profile.name)
      ),
      syncStage: String(profile.sync_stage || "") || null,
      portalSyncError: String(profile.portal_sync_error || "") || null,
      lmsSyncError: String(profile.lms_sync_error || "") || null
    };
  } catch {
    return {
      supported: true,
      authenticated: true,
      username: credential.username,
      reachable: false
    };
  }
}

async function loginPlugin(req, pluginId) {
  const { getInstalledPlugin } = await import("./lib/runtime/plugin-registry.mjs");
  const { setPluginCredential } = await import("./lib/runtime/config-store.mjs");
  const plugin = await getInstalledPlugin(WORKSPACE_ROOT, pluginId);
  if (!plugin) throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  const auth = plugin.surface.auth;
  if (!auth) throw Object.assign(new Error("Plugin does not support user authentication."), { status: 400 });
  const body = await readJsonBody(req);
  const username = String(body.username || "").trim();
  const password = String(body.password || "");
  if (!username || !password) {
    throw Object.assign(new Error("Username and password are required."), { status: 400 });
  }
  const url = new URL(auth.loginPath, plugin.surface.upstreamUrl);
  let response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({
        [auth.usernameField]: username,
        [auth.passwordField]: password
      }),
      redirect: "error",
      // University SSO verification may use a headless browser. Keep it
      // bounded below the Apple client's request timeout.
      signal: AbortSignal.timeout(50_000)
    });
  } catch (error) {
    throw Object.assign(new Error(`Plugin login is unavailable: ${error.message}`), { status: 502 });
  }
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw Object.assign(
      new Error(String(result.detail || result.error || "Plugin login failed.")),
      { status: response.status === 401 ? 401 : 502 }
    );
  }
  const token = String(result[auth.tokenField] || "");
  if (!token) throw Object.assign(new Error("Plugin login did not return a session token."), { status: 502 });
  await setPluginCredential(WORKSPACE_ROOT, auth.credentialId, token, { username });
  return { authenticated: true, username };
}

async function logoutPlugin(pluginId) {
  const { getInstalledPlugin } = await import("./lib/runtime/plugin-registry.mjs");
  const { removePluginCredential } = await import("./lib/runtime/config-store.mjs");
  const plugin = await getInstalledPlugin(WORKSPACE_ROOT, pluginId);
  if (!plugin) throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  const auth = plugin.surface.auth;
  if (!auth) return { authenticated: false, removed: false };
  const result = await removePluginCredential(WORKSPACE_ROOT, auth.credentialId);
  return { authenticated: false, removed: result.removed };
}

function validatePluginViewDocument(document) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw Object.assign(new Error("Plugin surface document must be an object."), { status: 502 });
  }
  const presentation = String(document.presentation || "");
  if (![1, 2].includes(Number(document.schemaVersion))
      || !["collection", "dashboard", "calendar"].includes(presentation)) {
    throw Object.assign(
      new Error("Unsupported plugin surface document schema."),
      { status: 502 }
    );
  }
  if (!String(document.title || "").trim()) {
    throw Object.assign(new Error("Plugin surface title is required."), { status: 502 });
  }
  if (!Array.isArray(document.items) || document.items.length > 500) {
    throw Object.assign(
      new Error("Plugin surface items must be an array of at most 500 entries."),
      { status: 502 }
    );
  }
  if (presentation === "calendar") {
    if (document.editor != null
        && !/^[a-z][a-z0-9_-]{0,63}$/.test(String(document.editor.collection || ""))) {
      throw Object.assign(new Error("Plugin calendar editor collection is invalid."), { status: 502 });
    }
    for (const item of document.items) {
      if (!item?.temporal || !String(item.temporal.startsAt || "").trim()) {
        throw Object.assign(
          new Error("Plugin calendar items must include a temporal startsAt value."),
          { status: 502 }
        );
      }
    }
  }
  if (Number(document.schemaVersion) === 2 && document.editor != null) {
    if (!Array.isArray(document.editor.fields)
        || !document.editor.fields.length
        || document.editor.fields.length > 32) {
      throw Object.assign(new Error("Plugin Surface v2 editor fields are invalid."), { status: 502 });
    }
  }
  if (presentation === "dashboard") {
    if (!Array.isArray(document.sections) || document.sections.length > 50) {
      throw Object.assign(
        new Error("Plugin dashboard sections must be an array of at most 50 entries."),
        { status: 502 }
      );
    }
    for (const section of document.sections) {
      if (!section || !["keyValue", "table"].includes(section.kind)) {
        throw Object.assign(new Error("Unsupported plugin dashboard section."), { status: 502 });
      }
      if (section.kind === "keyValue" && (!Array.isArray(section.fields) || section.fields.length > 100)) {
        throw Object.assign(new Error("Plugin key-value section is invalid."), { status: 502 });
      }
      if (section.kind === "table") {
        if (!Array.isArray(section.columns) || section.columns.length > 50
            || !Array.isArray(section.rows) || section.rows.length > 1000) {
          throw Object.assign(new Error("Plugin table section is invalid."), { status: 502 });
        }
      }
    }
  }
}

async function readJsonBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw Object.assign(new Error("Request body must be JSON."), { status: 400 });
  }
}

function requireQuery(url, key) {
  const value = url.searchParams.get(key);
  if (!value) throw Object.assign(new Error(`Missing query parameter: ${key}`), { status: 400 });
  return value;
}

function sendJson(res, value, status = 200) {
  const body = JSON.stringify(value, null, 2) + "\n";
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body)
  });
  res.end(body);
}

function sendNoContent(res) {
  setCors(res);
  res.writeHead(204);
  res.end();
}

function sendError(res, error) {
  setCors(res);
  const status = Number.isInteger(error?.status) ? error.status
    : error?.code === "EEXIST" ? 409
      : 500;
  sendJson(res, {
    error: error?.message || "Internal server error",
    ...(error?.code ? { code: String(error.code) } : {}),
    ...(error?.details ? { details: error.details } : {})
  }, status);
}

function setCors(res) {
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS");
  res.setHeader("access-control-allow-headers", "content-type, authorization");
}

function contentTypeForPath(filePath) {
  const lower = String(filePath).toLowerCase();
  if (lower.endsWith(".pdf")) return "application/pdf";
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
  if (lower.endsWith(".svg")) return "image/svg+xml";
  if (lower.endsWith(".md")) return "text/markdown; charset=utf-8";
  return "application/octet-stream";
}

async function getUserMemories() {
  const filePath = path.join(WORKSPACE_ROOT, ".codmes", "memory", "user", "memories.jsonl");
  try {
    const data = await fs.readFile(filePath, "utf8");
    return data.split("\n").filter(Boolean).map(JSON.parse);
  } catch {
    return [];
  }
}

async function saveUserMemories(list) {
  const dir = path.join(WORKSPACE_ROOT, ".codmes", "memory", "user");
  await fs.mkdir(dir, { recursive: true });
  const filePath = path.join(dir, "memories.jsonl");
  await fs.writeFile(filePath, list.map(m => JSON.stringify(m)).join("\n") + "\n", "utf8");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
