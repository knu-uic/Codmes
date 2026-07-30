import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createPublisherKeyPair } from "./lib/runtime/plugin-package.mjs";
import { preparePluginRelease } from "./lib/runtime/plugin-publisher.mjs";

test("signed remote Marketplace runs install, Surface storage, update, and rollback end to end", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-runtime-"));
  const workspace = path.join(root, "workspace");
  const releases = path.join(root, "releases");
  const registryPath = path.join(root, "registry", "index.json");
  await fs.mkdir(workspace);
  const publisher = createPublisherKeyPair("com.example.runtime-publisher");
  let registry = null;
  const registryServer = http.createServer(async (request, response) => {
    if (request.url === "/index.json") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(registry));
      return;
    }
    if (request.url?.startsWith("/releases/")) {
      const filename = path.basename(new URL(request.url, "http://localhost").pathname);
      try {
        response.setHeader("content-type", "application/octet-stream");
        response.end(await fs.readFile(path.join(releases, filename)));
      } catch {
        response.statusCode = 404;
        response.end();
      }
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  registryServer.listen(0, "127.0.0.1");
  await once(registryServer, "listening");
  const registryPort = registryServer.address().port;
  const token = "mock-runtime-token";
  const codmesPort = await availablePort();
  let codmes = null;
  try {
    await prepareVersion("1.0.0");
    registry = JSON.parse(await fs.readFile(registryPath, "utf8"));
    codmes = spawn(process.execPath, ["server/index.mjs"], {
      cwd: path.resolve("."),
      env: {
        ...process.env,
        NODE_ENV: "test",
        CODMES_HOST: "127.0.0.1",
        CODMES_PORT: String(codmesPort),
        CODMES_WORKSPACE_ROOT: workspace,
        CODMES_SERVER_TOKEN: token,
        CODMES_MARKETPLACE_REGISTRY: `http://127.0.0.1:${registryPort}/index.json`
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    const baseUrl = `http://127.0.0.1:${codmesPort}`;
    await waitForServer(`${baseUrl}/api/health`);

    const listedV1 = await request(`${baseUrl}/api/marketplace/plugins`, { token });
    assert.equal(listedV1.plugins[0].version, "1.0.0");
    const installedV1 = await request(
      `${baseUrl}/api/marketplace/plugins/com.example.runtime/install`,
      { token, method: "POST", body: { version: "1.0.0" } }
    );
    assert.equal(installedV1.plugin.version, "1.0.0");
    const created = await request(
      `${baseUrl}/api/plugins/com.example.runtime/collections/memos`,
      { token, method: "POST", body: { item: { title: "Runtime memo", content: "v1" } } }
    );
    assert.equal(created.created, true);
    const surface = await request(
      `${baseUrl}/api/plugins/com.example.runtime/surface-document?route=memos`,
      { token }
    );
    assert.equal(surface.items[0].title, "Runtime memo");

    await prepareVersion("1.1.0");
    registry = JSON.parse(await fs.readFile(registryPath, "utf8"));
    const listedV2 = await request(`${baseUrl}/api/marketplace/plugins`, { token });
    assert.equal(listedV2.plugins[0].updateAvailable, true);
    assert.deepEqual(
      listedV2.plugins[0].addedPermissions,
      ["network:https://sync.example.com"]
    );
    await assert.rejects(
      () => request(
        `${baseUrl}/api/marketplace/plugins/com.example.runtime/update`,
        { token, method: "POST", body: {} }
      ),
      /requires consent/
    );
    const updated = await request(
      `${baseUrl}/api/marketplace/plugins/com.example.runtime/update`,
      {
        token,
        method: "POST",
        body: { acceptedPermissions: ["network:https://sync.example.com"] }
      }
    );
    assert.equal(updated.plugin.version, "1.1.0");
    const retained = await request(
      `${baseUrl}/api/plugins/com.example.runtime/collections/memos`,
      { token }
    );
    assert.equal(retained.items[0].content, "v1");

    const rolledBack = await request(
      `${baseUrl}/api/plugins/com.example.runtime/rollback`,
      { token, method: "POST", body: {} }
    );
    assert.equal(rolledBack.plugin.version, "1.0.0");

    await request(
      `${baseUrl}/api/marketplace/plugins/com.example.runtime/update`,
      { token, method: "POST", body: {} }
    );
    registry.blockedVersions = [{
      pluginId: "com.example.runtime",
      version: "1.0.0",
      severity: "critical",
      reason: "Mock vulnerable release."
    }];
    await assert.rejects(
      () => request(
        `${baseUrl}/api/plugins/com.example.runtime/rollback`,
        { token, method: "POST", body: {} }
      ),
      /version is blocked/
    );
  } finally {
    if (codmes && codmes.exitCode == null) {
      codmes.kill("SIGTERM");
      await once(codmes, "exit").catch(() => {});
    }
    registryServer.close();
    await once(registryServer, "close").catch(() => {});
  }

  async function prepareVersion(version) {
    const source = await createRuntimePlugin(root, version);
    const filename = `com.example.runtime-${version}.codmes-plugin`;
    await preparePluginRelease({
      sourcePath: source,
      outputDirectory: releases,
      registryPath,
      packageUrl: `http://127.0.0.1:${registryPort}/releases/${filename}`,
      signingKey: publisher.privateKey,
      publisherId: publisher.identity.publisherId,
      category: "Productivity",
      force: true
    });
  }
});

async function createRuntimePlugin(root, version) {
  const source = path.join(root, `source-${version}`);
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.runtime",
    version,
    name: "Runtime",
    description: "Remote signed runtime fixture",
    publisher: "Example",
    platforms: ["macos", "ios"],
    permissions: version === "1.0.0"
      ? ["storage:workspace"]
      : ["storage:workspace", "network:https://sync.example.com"],
    storage: "storage.json",
    tools: "tools.json",
    surface: {
      id: "runtime",
      type: "declarative",
      title: "Runtime",
      upstreamUrl: "http://127.0.0.1",
      entryPath: "/",
      ui: "surface.json"
    }
  }));
  await fs.writeFile(path.join(source, "storage.json"), JSON.stringify({
    schemaVersion: 1,
    collections: [{
      id: "memos",
      itemSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          id: { type: "string" },
          title: { type: "string" },
          content: { type: "string" }
        },
        required: ["title", "content"]
      }
    }]
  }));
  await fs.writeFile(path.join(source, "tools.json"), JSON.stringify({
    schemaVersion: 1,
    tools: [{
      name: "runtime_memo_list",
      description: "List runtime memos.",
      inputSchema: { type: "object", additionalProperties: false, properties: {} },
      provider: {
        type: "plugin",
        id: "com.example.runtime",
        tool: "collection.memos.list"
      },
      readOnly: true
    }]
  }));
  await fs.writeFile(path.join(source, "surface.json"), JSON.stringify({
    schemaVersion: 2,
    routes: [{
      id: "memos",
      title: "Memos",
      dataSources: [{ id: "memos", path: "collection:memos" }],
      document: {
        schemaVersion: 2,
        presentation: "collection",
        title: `Runtime ${version}`,
        editor: {
          collection: "memos",
          fields: [
            { id: "title", label: "Title", type: "text", required: true },
            { id: "content", label: "Content", type: "multiline", required: true }
          ]
        },
        collection: {
          source: "memos.items",
          item: { id: "id", title: "title", body: "content" }
        }
      }
    }]
  }));
  return source;
}

async function availablePort() {
  const server = http.createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = server.address().port;
  server.close();
  await once(server, "close");
  return port;
}

async function waitForServer(url) {
  let lastError;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw lastError || new Error("Codmes server did not start.");
}

async function request(url, { token, method = "GET", body } = {}) {
  const response = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "content-type": "application/json" })
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || `Request failed with ${response.status}.`);
  return value;
}
