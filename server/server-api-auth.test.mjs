import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { annotationsPathForDocument, documentManifestPath, documentStateDirectory } from "./lib/document-ingest.mjs";

test("workspace server protects APIs with CODMES_SERVER_TOKEN and exposes management APIs", async () => {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-server-api-"));
  const port = 18000 + Math.floor(Math.random() * 10000);
  const token = "test-token";
  const server = spawn(process.execPath, ["server/index.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      NODE_ENV: "test",
      CODMES_HOST: "127.0.0.1",
      CODMES_PORT: String(port),
      CODMES_WORKSPACE_ROOT: workspaceRoot,
      CODMES_SERVER_TOKEN: token
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  try {
    const baseUrl = `http://127.0.0.1:${port}`;
    await waitForServer(`${baseUrl}/api/health`);

    const health = await fetchJson(`${baseUrl}/api/health`);
    assert.equal(health.ok, true);
    assert.equal(health.authRequired, true);

    const unauthorized = await fetch(`${baseUrl}/api/workspace`);
    assert.equal(unauthorized.status, 401);

    const workspace = await fetchJson(`${baseUrl}/api/workspace`, { token });
    assert.equal(workspace.runtime.owner, "codmes");

    const documentJobs = await fetchJson(`${baseUrl}/api/document-jobs`, { token });
    assert.deepEqual(documentJobs.jobs, []);

    await fs.writeFile(path.join(workspaceRoot, "Notes", "auth-note.md"), "# Token Test\n", "utf8");
    const rebuilt = await fetchJson(`${baseUrl}/api/index/rebuild`, { token, method: "POST" });
    assert.equal(rebuilt.ok, true);
    assert.equal(rebuilt.itemCount, 1);

    const metadata = await fetchJson(`${baseUrl}/api/file/metadata?path=Notes/auth-note.md`, { token });
    assert.equal(metadata.path, "Notes/auth-note.md");
    assert.equal(metadata.kind, "markdown");

    await fs.mkdir(path.join(workspaceRoot, "Notes", "Work", "Docs"), { recursive: true });
    await fs.writeFile(path.join(workspaceRoot, "Notes", "Work", "README.md"), "# Work\n", "utf8");
    await fs.writeFile(path.join(workspaceRoot, "Notes", "Work", "Docs", "Architecture.md"), "# Architecture\n", "utf8");
    const directTree = await fetchJson(`${baseUrl}/api/tree?root=notes`, { token });
    assert.equal(directTree.children.some((item) => item.path === "Notes/Work"), true);
    assert.equal(directTree.children.some((item) => item.path === "Notes/Work/README.md"), false);
    const recursiveTree = await fetchJson(`${baseUrl}/api/tree?root=notes&recursive=true`, { token });
    assert.equal(recursiveTree.children.some((item) => item.path === "Notes/Work/README.md"), true);
    assert.equal(recursiveTree.children.some((item) => item.path === "Notes/Work/Docs/Architecture.md"), true);

    await fs.writeFile(path.join(workspaceRoot, "Documents", "sample.pdf"), "%PDF-1.4\n%%EOF", "utf8");
    const rawRange = await fetch(`${baseUrl}/api/raw?path=Documents/sample.pdf`, {
      headers: {
        authorization: `Bearer ${token}`,
        range: "bytes=0-3"
      }
    });
    assert.equal(rawRange.status, 206);
    assert.equal(rawRange.headers.get("accept-ranges"), "bytes");
    assert.equal(rawRange.headers.get("content-range"), "bytes 0-3/14");
    assert.equal(await rawRange.text(), "%PDF");
    const rawHead = await fetch(`${baseUrl}/api/raw?path=Documents/sample.pdf`, {
      method: "HEAD",
      headers: { authorization: `Bearer ${token}` }
    });
    assert.equal(rawHead.status, 200);
    assert.equal(rawHead.headers.get("content-length"), "14");
    assert.equal(await rawHead.text(), "");
    const emptyAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/sample.pdf`, { token });
    assert.equal(emptyAnnotations.documentPath, "Documents/sample.pdf");
    assert.equal(emptyAnnotations.pages.length, 0);
    const savedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/sample.pdf`, {
      token,
      method: "PUT",
      body: {
        schemaVersion: 1,
        pages: [
          {
            pageIndex: 0,
            inkDataBase64: "cGVuLWRhdGE=",
            inkStrokes: [
              {
                id: "stroke-1",
                tool: "pen",
                color: "#111111",
                width: 2.5,
                points: [
                  { x: 0.1, y: 0.2, pressure: 0.5, timeOffset: 0 },
                  { x: 0.2, y: 0.25, pressure: 0.6, timeOffset: 0.01 }
                ]
              }
            ],
            objects: [
              { id: "highlight-1", type: "highlight", bbox: { x: 0.1, y: 0.2, width: 0.3, height: 0.04 } }
            ]
          }
        ]
      }
    });
    assert.equal(savedAnnotations.documentPath, "Documents/sample.pdf");
    assert.equal(savedAnnotations.pages[0].pageIndex, 0);
    const readAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/sample.pdf`, { token });
    assert.equal(readAnnotations.pages[0].inkDataBase64, "cGVuLWRhdGE=");
    assert.equal(readAnnotations.pages[0].inkStrokes[0].points[1].x, 0.2);
    await fs.access(annotationsPathForDocument(workspaceRoot, "Documents/sample.pdf"));
    assert.equal(
      annotationsPathForDocument(workspaceRoot, "Documents/sample.pdf"),
      path.join(documentStateDirectory(workspaceRoot, "Documents/sample.pdf"), "annotations.json")
    );
    await fs.access(documentManifestPath(workspaceRoot, "Documents/sample.pdf"));

    const movedPdf = await fetchJson(`${baseUrl}/api/file/move`, {
      token,
      method: "PATCH",
      body: { from: "Documents/sample.pdf", to: "Documents/renamed.pdf" }
    });
    assert.equal(movedPdf.to, "Documents/renamed.pdf");
    const movedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/renamed.pdf`, { token });
    assert.equal(movedAnnotations.documentPath, "Documents/renamed.pdf");
    assert.equal(movedAnnotations.pages[0].inkDataBase64, "cGVuLWRhdGE=");
    await fs.access(annotationsPathForDocument(workspaceRoot, "Documents/renamed.pdf"));
    await fs.access(documentManifestPath(workspaceRoot, "Documents/renamed.pdf"));
    await assert.rejects(
      fs.access(documentStateDirectory(workspaceRoot, "Documents/sample.pdf")),
      { code: "ENOENT" }
    );

    const copiedPdf = await fetchJson(`${baseUrl}/api/file/copy`, {
      token,
      method: "POST",
      body: { from: "Documents/renamed.pdf", to: "Documents/copied.pdf" }
    });
    assert.equal(copiedPdf.to, "Documents/copied.pdf");
    const copiedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/copied.pdf`, { token });
    assert.equal(copiedAnnotations.documentPath, "Documents/copied.pdf");
    assert.equal(copiedAnnotations.pages[0].inkDataBase64, "cGVuLWRhdGE=");
    await fs.access(documentManifestPath(workspaceRoot, "Documents/copied.pdf"));

    const deletedCopy = await fetchJson(`${baseUrl}/api/file?path=Documents/copied.pdf`, {
      token,
      method: "DELETE"
    });
    assert.equal(deletedCopy.path, "Documents/copied.pdf");
    await assert.rejects(
      fs.access(documentStateDirectory(workspaceRoot, "Documents/copied.pdf")),
      { code: "ENOENT" }
    );

    await fs.writeFile(path.join(workspaceRoot, "Documents", "imported.pdf"), "%PDF-1.4\nexisting\n%%EOF", "utf8");
    const imported = await fetchJson(`${baseUrl}/api/file/import-codmes-pdf`, {
      token,
      method: "POST",
      body: {
        path: "Documents/imported.pdf",
        pdfDataBase64: Buffer.from("%PDF-1.4\nimported\n%%EOF", "utf8").toString("base64"),
        codmesDataBase64: Buffer.from(JSON.stringify({
          schemaVersion: 1,
          documentPath: "Portable/old.pdf",
          pages: [{
            pageIndex: 0,
            objects: [{ id: "portable-text", type: "text", text: "portable import marker" }]
          }],
          objects: []
        }), "utf8").toString("base64")
      }
    });
    assert.equal(imported.requestedPath, "Documents/imported.pdf");
    assert.equal(imported.path, "Documents/imported 2.pdf");
    assert.equal(imported.renamed, true);
    assert.equal(imported.annotationsImported, true);
    const importedAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/imported%202.pdf`, { token });
    assert.equal(importedAnnotations.documentPath, "Documents/imported 2.pdf");
    assert.equal(importedAnnotations.pages[0].objects[0].text, "portable import marker");

    const editableExport = await fetchJson(`${baseUrl}/api/file/export-codmes-pdf`, {
      token,
      method: "POST",
      body: {
        name: "portable.pdf",
        pdfDataBase64: Buffer.from("%PDF-1.4\nportable package\n%%EOF", "utf8").toString("base64"),
        codmesDataBase64: Buffer.from(JSON.stringify({
          schemaVersion: 2,
          documentPath: "Documents/original.pdf",
          pages: [{
            pageIndex: 0,
            objects: [{ id: "package-text", type: "text", text: "editable package marker" }]
          }],
          objects: [],
          elements: []
        }), "utf8").toString("base64")
      }
    });
    assert.equal(editableExport.fileName, "portable.codmespdf");

    const restoredPackage = await fetchJson(`${baseUrl}/api/file/import-codmes-pdf-package`, {
      token,
      method: "POST",
      body: {
        path: "Documents/portable.pdf",
        packageDataBase64: editableExport.dataBase64
      }
    });
    assert.equal(restoredPackage.path, "Documents/portable.pdf");
    assert.equal(restoredPackage.annotationsImported, true);
    const restoredAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/portable.pdf`, { token });
    assert.equal(restoredAnnotations.documentPath, "Documents/portable.pdf");
    assert.equal(restoredAnnotations.pages[0].objects[0].text, "editable package marker");

    const restoredCollision = await fetchJson(`${baseUrl}/api/file/import-codmes-pdf-package`, {
      token,
      method: "POST",
      body: {
        path: "Documents/portable.pdf",
        packageDataBase64: editableExport.dataBase64
      }
    });
    assert.equal(restoredCollision.path, "Documents/portable 2.pdf");
    assert.equal(restoredCollision.renamed, true);

    const invalidPackageResponse = await fetch(`${baseUrl}/api/file/import-codmes-pdf-package`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json"
      },
      body: JSON.stringify({
        path: "Documents/broken.pdf",
        packageDataBase64: Buffer.from("not a zip", "utf8").toString("base64")
      })
    });
    assert.equal(invalidPackageResponse.status, 400);
    await assert.rejects(fs.access(path.join(workspaceRoot, "Documents", "broken.pdf")), { code: "ENOENT" });

    await fs.mkdir(path.join(workspaceRoot, "Documents", ".codmes", "annotations"), { recursive: true });
    await fs.writeFile(path.join(workspaceRoot, "Documents", ".codmes", "annotations", "later.codmes.json"), JSON.stringify({
      schemaVersion: 1,
      documentPath: "Documents/later.pdf",
      pages: [{
        pageIndex: 0,
        objects: [{ id: "state-first", type: "text", text: "state arrived first" }]
      }],
      objects: []
    }), "utf8");
    await fs.writeFile(path.join(workspaceRoot, "Documents", "later.pdf"), "%PDF-1.4\nlater\n%%EOF", "utf8");
    const stateFirstAnnotations = await fetchJson(`${baseUrl}/api/file/annotations?path=Documents/later.pdf`, { token });
    assert.equal(stateFirstAnnotations.pages[0].objects[0].text, "state arrived first");

    const replacedPdf = await fetchJson(`${baseUrl}/api/file/binary`, {
      token,
      method: "PUT",
      body: {
        path: "Documents/later.pdf",
        dataBase64: Buffer.from("%PDF-1.4\nreplaced\n%%EOF", "utf8").toString("base64")
      }
    });
    assert.equal(replacedPdf.path, "Documents/later.pdf");
    assert.equal(await fs.readFile(path.join(workspaceRoot, "Documents", "later.pdf"), "utf8"), "%PDF-1.4\nreplaced\n%%EOF");

    await Promise.all(["a", "b", "c"].map((name) => fetchJson(`${baseUrl}/api/file/upload`, {
      token,
      method: "POST",
      body: {
        path: `Notes/concurrent-${name}.md`,
        dataBase64: Buffer.from(`# Concurrent ${name}\nshared-upload-token-${name}\n`, "utf8").toString("base64")
      }
    })));
    await Promise.all(["a", "b", "c"].map((name) => fetchJson(`${baseUrl}/api/file?path=Notes/concurrent-${name}.md`, {
      token,
      method: "PUT",
      body: {
        content: `# Concurrent ${name}\nshared-upload-token-${name}\nmodified-token-${name}\n`
      }
    })));
    const concurrentSearch = await fetchJson(`${baseUrl}/api/search`, {
      token,
      method: "POST",
      body: { query: "modified-token-b", scopePath: "Notes", maxResults: 10 }
    });
    assert.equal(concurrentSearch.results.some((result) => result.path === "Notes/concurrent-b.md"), true);

    const security = await fetchJson(`${baseUrl}/api/security`, { token });
    assert.equal(security.approvalMode, "auto");
    const updatedSecurity = await fetchJson(`${baseUrl}/api/security`, {
      token,
      method: "POST",
      body: { approvalMode: "manual", requireApproval: ["mcp.tool.call"] }
    });
    assert.equal(updatedSecurity.security.approvalMode, "manual");

    const addedMcp = await fetchJson(`${baseUrl}/api/mcp`, {
      token,
      method: "POST",
      body: { name: "test_mcp", command: "node", args: ["server.js"], scopePath: "Notes" }
    });
    assert.equal(addedMcp.server.name, "test_mcp");
    assert.equal(addedMcp.server.scopePath, "Notes");
    const upsertedMcp = await fetchJson(`${baseUrl}/api/mcp`, {
      token,
      method: "POST",
      body: { name: "test_mcp", command: "node", args: ["updated.js"], enabled: true, scopePath: "Code" }
    });
    assert.equal(upsertedMcp.created, false);
    assert.equal(upsertedMcp.server.scopePath, "Code");
    assert.deepEqual(upsertedMcp.server.args, ["updated.js"]);
    assert.equal(upsertedMcp.server.enabled, true);
    const updatedMcp = await fetchJson(`${baseUrl}/api/mcp/test_mcp`, {
      token,
      method: "POST",
      body: {
        command: "example-mcp",
        args: ["start", "--scope", "Notes"],
        enabled: true,
        env: { EXAMPLE_MCP_MODE: "demo" },
        scopePath: "Notes/Research"
      }
    });
    assert.equal(updatedMcp.server.command, "example-mcp");
    assert.equal(updatedMcp.server.scopePath, "Notes/Research");
    assert.equal(updatedMcp.server.env.EXAMPLE_MCP_MODE, "demo");
    assert.deepEqual(updatedMcp.server.args, ["start", "--scope", "Notes"]);
    const remoteMcp = await fetchJson(`${baseUrl}/api/mcp`, {
      token,
      method: "POST",
      body: {
        name: "knu-rag",
        transport: "streamable_http",
        url: "https://macbookair.tail649ef4.ts.net/api/mcp/",
        credential_id: "knu-rag",
        surfaces: ["chat"]
      }
    });
    assert.equal(remoteMcp.server.transport, "streamable_http");
    assert.equal(remoteMcp.server.credentialConfigured, false);
    assert.equal(Object.hasOwn(remoteMcp.server, "token"), false);
    assert.equal(JSON.stringify(remoteMcp).includes("bearer"), false);
    const listedMcp = await fetchJson(`${baseUrl}/api/mcp`, { token });
    assert.equal(typeof listedMcp.servers.find((server) => server.name === "test_mcp").enabled, "boolean");
    const disabled = await fetchJson(`${baseUrl}/api/mcp/test_mcp/disable`, { token, method: "POST" });
    assert.equal(disabled.server.enabled, false);
    const removed = await fetchJson(`${baseUrl}/api/mcp/test_mcp`, { token, method: "DELETE" });
    assert.equal(removed.removed, "test_mcp");

    const searchConfig = await fetchJson(`${baseUrl}/api/search/config`, {
      token,
      method: "POST",
      body: {
        roots: ["Notes", "Code"],
        embeddingsProvider: "openai",
        openaiBaseUrl: "http://127.0.0.1:11434/v1",
        openaiApiKey: "ollama",
        openaiEmbedModel: "bge-m3",
        openaiEmbedDim: 1024,
        vlmProvider: "ollama-local",
        vlmModel: "gemma4:e2b-mlx",
        vlmBaseUrl: "http://127.0.0.1:11434/v1",
        vlmApiKey: "ollama"
      }
    });
    assert.equal(searchConfig.ok, true);
    assert.equal(searchConfig.openaiEmbedModel, "bge-m3");
    assert.equal(searchConfig.openaiApiKeyConfigured, true);
    assert.equal(searchConfig.vlmProvider, "ollama-local");
    assert.equal(searchConfig.vlmModel, "gemma4:e2b-mlx");
    assert.equal(searchConfig.vlmApiKeyConfigured, true);
    assert.equal(searchConfig.backend, "codmes");
    assert.match(searchConfig.configPath, /search\.env$/);

    const doctor = await fetchJson(`${baseUrl}/api/doctor`, { token });
    assert.equal(doctor.ok, true);
    assert.equal(doctor.authRequired, true);
    assert.equal(doctor.audit.path, ".codmes/audit/audit.jsonl");
    assert.equal(doctor.documentIngest.requirements, "server/workers/document-ingest/requirements.txt");
    assert.equal(typeof doctor.documentIngest.libraries.fitz, "boolean");
    assert.equal(Object.hasOwn(doctor.documentIngest, "binaries"), false);

    const providers = await fetchJson(`${baseUrl}/api/providers`, { token });
    assert.equal(providers.providers.some((provider) => provider.id === "custom"), false);
    assert.equal(providers.providers.some((provider) => provider.id === "openai-api"), false);
    assert.ok(providers.providers.some((provider) => provider.id === "openai-codex"));
    assert.ok(providers.providers.some((provider) => provider.id === "ollama-local"));

    const openAiModels = await fetchJson(`${baseUrl}/api/providers/openai-codex/models`, { token });
    assert.equal(openAiModels.provider, "openai-codex");
    assert.ok(openAiModels.models.includes("gpt-5.6-sol"));
    assert.ok(openAiModels.models.includes("gpt-5.6-terra"));
    assert.ok(openAiModels.models.includes("gpt-5.6-luna"));
    assert.ok(openAiModels.models.includes("gpt-5.4-mini"));

    const storedAuth = await fetchJson(`${baseUrl}/api/auth/ollama-local`, {
      token,
      method: "POST",
      body: {
        baseUrl: "http://127.0.0.1:11434"
      }
    });
    assert.equal(storedAuth.ok, true);
    assert.equal(storedAuth.provider, "ollama-local");

    const authStatus = await fetchJson(`${baseUrl}/api/auth`, { token });
    const ollamaAuth = authStatus.providers.find((provider) => provider.provider === "ollama-local");
    assert.equal(ollamaAuth.configured, true);

    const providerAuth = await fetchJson(`${baseUrl}/api/auth/ollama-local`, { token });
    assert.equal(providerAuth.provider, "ollama-local");
    assert.equal(providerAuth.credentials.length, 1);
    assert.equal(providerAuth.credentials[0].baseUrl, "http://127.0.0.1:11434");

    const defaultModel = await fetchJson(`${baseUrl}/api/model/default`, {
      token,
      method: "POST",
      body: { provider: "ollama-local", model: "demo-model" }
    });
    assert.equal(defaultModel.defaultModel.provider, "ollama-local");
    assert.equal(defaultModel.defaultModel.model, "demo-model");

    const readDefault = await fetchJson(`${baseUrl}/api/model/default`, { token });
    assert.equal(readDefault.defaultModel.id, "ollama-local:demo-model");

    const models = await fetchJson(`${baseUrl}/api/models`, { token });
    assert.ok(models.models.some((model) => model.id === "ollama-local:demo-model"));

    const removedAuth = await fetchJson(`${baseUrl}/api/auth/ollama-local`, {
      token,
      method: "DELETE"
    });
    assert.equal(removedAuth.removed, true);
    const providerAuthAfterDelete = await fetchJson(`${baseUrl}/api/auth/ollama-local`, { token });
    assert.equal(providerAuthAfterDelete.credentials.length, 0);
  } finally {
    server.kill("SIGTERM");
    await fs.rm(workspaceRoot, { recursive: true, force: true });
  }
});

async function waitForServer(url) {
  let lastError;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw lastError || new Error(`Server did not become ready: ${url}`);
}

async function fetchJson(url, options = {}) {
  const headers = { accept: "application/json" };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.body) headers["content-type"] = "application/json";
  const response = await fetch(url, {
    method: options.method || "GET",
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${text}`);
  }
  return text ? JSON.parse(text) : {};
}
