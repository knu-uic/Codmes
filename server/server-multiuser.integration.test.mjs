import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import http from "node:http";
import { randomUUID } from "node:crypto";
import { createCodmesDatabase } from "./lib/database.mjs";

const connectionString = process.env.CODMES_TEST_SERVER_DATABASE_URL || "";

test("Codmes multiuser server isolates family workspaces", { skip: !connectionString }, async () => {
  const dataRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-multiuser-"));
  const legacyRoot = path.join(dataRoot, "legacy-workspace");
  await fs.mkdir(path.join(legacyRoot, "Notes"), { recursive: true });
  await fs.writeFile(path.join(legacyRoot, "Notes", "existing.md"), "existing-workspace-marker");
  const embeddingServer = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const input = JSON.parse(Buffer.concat(chunks).toString("utf8")).input;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      data: input.map((text, index) => ({ index, embedding: embeddingVector(text) }))
    }));
  });
  await new Promise((resolve) => embeddingServer.listen(0, "127.0.0.1", resolve));
  const embeddingPort = embeddingServer.address().port;
  const port = 28000 + Math.floor(Math.random() * 5000);
  const server = spawn(process.execPath, ["server/index.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      NODE_ENV: "test",
      CODMES_HOST: "127.0.0.1",
      CODMES_PORT: String(port),
      CODMES_DATA_ROOT: dataRoot,
      CODMES_WORKSPACE_ROOT: legacyRoot,
      CODMES_MULTIUSER_ENABLED: "true",
      CODMES_DATABASE_URL: connectionString,
      CODMES_SEARCH_BACKEND: "postgres",
      CODMES_EMBEDDING_BASE_URL: `http://127.0.0.1:${embeddingPort}/v1`,
      CODMES_EMBEDDING_MODEL: "bge-m3",
      CODMES_EMBEDDING_DIM: "1024"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const serverOutput = [];
  server.stdout.on("data", (chunk) => serverOutput.push(chunk));
  server.stderr.on("data", (chunk) => serverOutput.push(chunk));
  const baseUrl = `http://127.0.0.1:${port}`;
  let testDatabase;
  try {
    await waitForServer(`${baseUrl}/api/health`);
    const health = await jsonRequest(`${baseUrl}/api/health`);
    assert.equal(health.multiuser, true);

    const bootstrap = await jsonRequest(`${baseUrl}/api/local-auth/bootstrap`, {
      method: "POST",
      body: {
        username: "admin",
        displayName: "Admin",
        password: "admin-password-123",
        workspaceName: "Admin Workspace"
      }
    });
    const adminToken = bootstrap.token;
    const adminWorkspaceId = bootstrap.workspace.id;
    const adopted = await jsonRequest(`${baseUrl}/api/file?path=Notes/existing.md`, {
      token: adminToken,
      workspaceId: adminWorkspaceId
    });
    assert.equal(adopted.content, "existing-workspace-marker");

    const createdUser = await jsonRequest(`${baseUrl}/api/local-users`, {
      token: adminToken,
      method: "POST",
      body: {
        username: "family",
        displayName: "Family",
        password: "family-password-123"
      }
    });
    assert.equal(createdUser.user.username, "family");
    const familyLogin = await jsonRequest(`${baseUrl}/api/local-auth/login`, {
      method: "POST",
      body: { username: "family", password: "family-password-123" }
    });
    const familyToken = familyLogin.token;
    const ownWorkspace = await jsonRequest(`${baseUrl}/api/workspaces`, {
      token: familyToken,
      method: "POST",
      body: { name: "Family Workspace" }
    });
    const familyWorkspaceId = ownWorkspace.workspace.id;

    await jsonRequest(`${baseUrl}/api/file`, {
      token: adminToken,
      workspaceId: adminWorkspaceId,
      method: "POST",
      body: { path: "Notes/private.md", content: "admin-only-marker" }
    });
    await jsonRequest(`${baseUrl}/api/file`, {
      token: familyToken,
      workspaceId: familyWorkspaceId,
      method: "POST",
      body: { path: "Notes/family.md", content: "family-only-marker" }
    });

    const forbidden = await fetch(`${baseUrl}/api/file?path=Notes/private.md`, {
      headers: {
        authorization: `Bearer ${familyToken}`,
        "x-codmes-workspace-id": adminWorkspaceId
      }
    });
    assert.equal(forbidden.status, 404);

    const familyNote = await jsonRequest(`${baseUrl}/api/file?path=Notes/family.md`, {
      token: familyToken,
      workspaceId: familyWorkspaceId
    });
    assert.equal(familyNote.content, "family-only-marker");
    const familySearch = await jsonRequest(`${baseUrl}/api/search`, {
      token: familyToken,
      workspaceId: familyWorkspaceId,
      method: "POST",
      body: { query: "family-only-marker" }
    });
    assert.equal(familySearch.provider, "codmes-postgres-hybrid");
    assert.ok(familySearch.results.length > 0, JSON.stringify(familySearch));
    assert.equal(familySearch.results[0].path, "Notes/family.md");
    assert.equal(familySearch.results.some((result) => result.path === "Notes/private.md"), false);

    testDatabase = createCodmesDatabase({ connectionString, maxConnections: 2 });
    const storage = await testDatabase.query("SELECT storage_key FROM codmes_workspaces WHERE id = $1", [familyWorkspaceId]);
    const assetRelativePath = ".codmes/documents/e2e--12345678/index/images/figure.png";
    const assetPath = path.join(dataRoot, "workspaces", storage.rows[0].storage_key, "files", assetRelativePath);
    await fs.mkdir(path.dirname(assetPath), { recursive: true });
    await fs.writeFile(assetPath, Buffer.from("workspace-image"));
    const documentId = randomUUID();
    const assetId = randomUUID();
    await testDatabase.query(
      `INSERT INTO codmes_documents(id, workspace_id, relative_path, content_hash)
       VALUES ($1, $2, 'Documents/e2e.pdf', 'e2e')`,
      [documentId, familyWorkspaceId]
    );
    await testDatabase.query(
      `INSERT INTO codmes_document_assets(id, document_id, kind, sha256, storage_path)
       VALUES ($1, $2, 'figure', 'e2e-image', $3)`,
      [assetId, documentId, assetRelativePath]
    );
    const assetResponse = await fetch(`${baseUrl}/api/workspace-assets/${assetId}/content`, {
      headers: {
        authorization: `Bearer ${familyToken}`,
        "x-codmes-workspace-id": familyWorkspaceId
      }
    });
    assert.equal(assetResponse.status, 200);
    assert.equal(Buffer.from(await assetResponse.arrayBuffer()).toString(), "workspace-image");
    const crossWorkspaceAsset = await fetch(`${baseUrl}/api/workspace-assets/${assetId}/content`, {
      headers: {
        authorization: `Bearer ${adminToken}`,
        "x-codmes-workspace-id": adminWorkspaceId
      }
    }).catch((error) => {
      throw new Error(`Cross-workspace asset request failed; server=${server.exitCode ?? server.signalCode ?? "running"}; ${Buffer.concat(serverOutput).toString("utf8")}; ${error.message}`);
    });
    assert.equal(crossWorkspaceAsset.status, 404);
  } finally {
    await testDatabase?.close().catch(() => {});
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await new Promise((resolve) => server.once("exit", resolve));
    }
    await new Promise((resolve) => embeddingServer.close(resolve));
    await fs.rm(dataRoot, { recursive: true, force: true });
  }
});

function embeddingVector(text) {
  const vector = new Array(1024).fill(0);
  vector[String(text).includes("family") ? 0 : 1] = 1;
  return vector;
}

async function jsonRequest(url, options = {}) {
  const headers = { ...(options.headers || {}) };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.workspaceId) headers["x-codmes-workspace-id"] = options.workspaceId;
  if (options.body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(url, {
    method: options.method || "GET",
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  const payload = await response.json();
  if (!response.ok) throw Object.assign(new Error(payload.error || `HTTP ${response.status}`), { status: response.status });
  return payload;
}

async function waitForServer(url) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("Codmes multiuser test server did not start.");
}
