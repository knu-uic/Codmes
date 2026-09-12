#!/usr/bin/env node
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startManagedPostgres, stopManagedPostgres } from "../server/lib/managed-postgres.mjs";

const sourcePdf = path.resolve(process.env.CODMES_E2E_PDF || "");
if (!process.env.CODMES_E2E_PDF || !(await fs.stat(sourcePdf).catch(() => null))?.isFile()) {
  throw new Error("Set CODMES_E2E_PDF to a real PDF file.");
}
const model = process.env.CODMES_E2E_MODEL || "gemma4:12b-mlx";
const surface = process.env.CODMES_E2E_SURFACE || "notes";
if (!new Set(["chat", "notes"]).has(surface)) {
  throw new Error("CODMES_E2E_SURFACE must be either chat or notes.");
}
const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-document-rag-"));
const workspaceRoot = path.join(root, "legacy-workspace");
const relativePdf = `Documents/${path.basename(sourcePdf)}`;
const targetPdf = path.join(workspaceRoot, relativePdf);
const databasePort = 55500 + Math.floor(Math.random() * 300);
const serverPort = 28500 + Math.floor(Math.random() * 500);
let postgres;
let server;
try {
  await fs.mkdir(path.dirname(targetPdf), { recursive: true });
  await fs.copyFile(sourcePdf, targetPdf);
  postgres = await startManagedPostgres({ dataRoot: root, port: databasePort });
  server = spawn(process.execPath, ["server/index.mjs"], {
    cwd: path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
    env: {
      ...process.env,
      NODE_ENV: "test",
      CODMES_HOST: "127.0.0.1",
      CODMES_PORT: String(serverPort),
      CODMES_DATA_ROOT: root,
      CODMES_WORKSPACE_ROOT: workspaceRoot,
      CODMES_MULTIUSER_ENABLED: "true",
      CODMES_DATABASE_URL: postgres.connectionString,
      CODMES_SEARCH_BACKEND: "postgres",
      CODMES_EMBEDDING_BASE_URL: "http://127.0.0.1:11434/v1",
      CODMES_EMBEDDING_MODEL: "bge-m3",
      CODMES_EMBEDDING_DIM: "1024",
      CODMES_VLM_PROVIDER: "ollama",
      CODMES_VLM_MODEL: model,
      CODMES_VLM_BASE_URL: "http://127.0.0.1:11434",
      CODMES_VLM_OLLAMA_NATIVE: "true",
      CODMES_VLM_MAX_TOKENS: "700"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const serverErrors = [];
  server.stderr.on("data", (chunk) => serverErrors.push(chunk));
  const baseUrl = `http://127.0.0.1:${serverPort}`;
  await waitForServer(`${baseUrl}/api/health`, serverErrors);
  const bootstrap = await jsonRequest(`${baseUrl}/api/local-auth/bootstrap`, {
    method: "POST",
    body: {
      username: "e2e-admin",
      displayName: "E2E Admin",
      password: "e2e-password-123",
      workspaceName: "E2E Library"
    }
  });
  const auth = { token: bootstrap.token, workspaceId: bootstrap.workspace.id };
  await jsonRequest(`${baseUrl}/api/model/default`, {
    ...auth,
    method: "POST",
    body: {
      provider: "ollama-local",
      model,
      baseUrl: "http://127.0.0.1:11434/v1"
    }
  });
  const rebuilt = await jsonRequest(`${baseUrl}/api/index/rebuild`, { ...auth, method: "POST", body: {} });
  const search = await jsonRequest(`${baseUrl}/api/search`, {
    ...auth,
    method: "POST",
    body: { query: "DBMS 플랫폼 계층도 그림", maxResults: 5 }
  });
  if (!search.results?.some((result) => result.related_images?.length)) {
    throw new Error(`Search did not return a related image: ${JSON.stringify(search)}`);
  }
  const liveUrl = `ws://127.0.0.1:${serverPort}/api/live?workspaceId=${encodeURIComponent(auth.workspaceId)}`;
  const socket = new WebSocket(liveUrl, [`codmes.bearer.${auth.token}`]);
  const send = commandClient(socket);
  await waitForSocket(socket);
  await send("connect", {});
  const session = await send("session.create", { surface, title: `Document RAG E2E (${surface})` });
  const answer = await send("prompt.submit", {
    sessionId: session.sessionId,
    surface,
    message: "문서의 DBMS 플랫폼 계층 구조를 설명하고, 근거가 되는 그림을 답변에 반드시 한 번 포함해줘."
  }, 240_000);
  socket.close();
  const messages = await jsonRequest(`${baseUrl}/api/sessions/${encodeURIComponent(session.sessionId)}/messages`, auth);
  const assistantText = JSON.stringify(messages);
  const localizedImage = assistantText.match(/\/api\/sessions\/[^"\\)]+\/assets\/[a-f0-9]{24}\.(?:png|jpg|webp)/i)?.[0] || "";
  if (!localizedImage) throw new Error(`Assistant answer did not persist a localized image: ${assistantText.slice(-2000)}`);
  const imageResponse = await fetch(`${baseUrl}${localizedImage}`, { headers: authHeaders(auth) });
  if (!imageResponse.ok || !(await imageResponse.arrayBuffer()).byteLength) {
    throw new Error(`Localized answer image could not be fetched (${imageResponse.status}).`);
  }
  console.log(JSON.stringify({
    ok: true,
    surface,
    model,
    indexedItems: rebuilt.search?.itemCount ?? rebuilt.itemCount ?? null,
    searchProvider: search.provider,
    searchImages: search.results.flatMap((result) => result.related_images || []).length,
    sessionId: session.sessionId,
    localizedImage,
    answerPreview: String(answer.reply || "").slice(0, 500)
  }, null, 2));
} finally {
  if (server && server.exitCode === null) {
    server.kill("SIGTERM");
    await new Promise((resolve) => server.once("exit", resolve));
  }
  await stopManagedPostgres(postgres).catch(() => {});
  const trash = path.join(os.homedir(), ".Trash", `${path.basename(root)}-${Date.now()}`);
  await fs.rename(root, trash).catch(() => {});
}

function commandClient(socket) {
  let sequence = 0;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(String(event.data));
    if ((message.kind === "result" || message.kind === "error") && pending.has(message.id)) {
      const request = pending.get(message.id);
      pending.delete(message.id);
      if (message.kind === "error") request.reject(new Error(message.error));
      else request.resolve(message.result);
    }
  });
  return (command, params, timeoutMs = 30_000) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${command} timed out.`));
    }, timeoutMs);
    pending.set(id, {
      resolve: (value) => { clearTimeout(timer); resolve(value); },
      reject: (error) => { clearTimeout(timer); reject(error); }
    });
    socket.send(JSON.stringify({ id, command, params }));
  });
}

async function jsonRequest(url, options = {}) {
  const headers = authHeaders(options);
  if (options.body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(url, {
    method: options.method || "GET",
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
  return payload;
}

function authHeaders(options) {
  return {
    ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
    ...(options.workspaceId ? { "x-codmes-workspace-id": options.workspaceId } : {})
  };
}

async function waitForServer(url, errors) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(url)).ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Codmes server did not start: ${Buffer.concat(errors).toString("utf8")}`);
}

function waitForSocket(socket) {
  return new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", () => reject(new Error("WebSocket connection failed.")), { once: true });
  });
}
