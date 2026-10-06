import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { getPluginCredential, readRuntimeConfig, setSharedPluginCredential } from "./config-store.mjs";
import { mutatePluginCollection, readPluginCollection } from "./plugin-collection-store.mjs";
import {
  adoptWorkspacePluginPackages,
  getInstalledPlugin,
  installPlugin,
  pluginsDirectory,
  removePlugin
} from "./plugin-registry.mjs";
import {
  ensurePluginRuntime,
  getRuntimePlugin,
  savePluginConfiguration
} from "./plugin-runtime.mjs";

test("profiles share one community plugin package but keep independent configuration", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-shared-plugin-"));
  const first = path.join(root, "profiles", "first");
  const second = path.join(root, "profiles", "second");
  const source = path.join(root, "source");
  await fs.mkdir(source, { recursive: true });
  const manifest = (version) => ({
    schemaVersion: 1,
    id: "com.example.shared",
    version,
    name: "Shared",
    platforms: ["macos"],
    surface: {
      id: "shared",
      type: "declarative",
      title: "Shared",
      upstreamUrl: "http://127.0.0.1",
      entryPath: "/",
      navigation: [{ id: "home", title: "Home", path: "/" }]
    },
    mcp: {
      name: "shared",
      transport: "streamable_http",
      url: "http://127.0.0.1:8000/mcp",
      surfaces: ["shared"],
      allowUnauthenticated: true
    }
  });
  const originalSharedRoot = process.env.CODMES_SHARED_PLUGIN_ROOT;
  try {
    await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify(manifest("1.0.0")));
    await installPlugin(first, source);
    await installPlugin(second, source);
    process.env.CODMES_SHARED_PLUGIN_ROOT = path.join(root, "shared");
    const adopted = await adoptWorkspacePluginPackages([first, second]);
    assert.deepEqual(adopted.adopted, [{ pluginId: "com.example.shared", version: "1.0.0", profiles: 2 }]);
    assert.equal(pluginsDirectory(first), pluginsDirectory(second));
    await ensurePluginRuntime(first);
    await ensurePluginRuntime(second);
    assert.equal((await readRuntimeConfig(second)).mcpServers.some((server) => server.pluginId === "com.example.shared"), true);
    await savePluginConfiguration(second, "com.example.shared", { enabled: false });
    await setSharedPluginCredential(first, "shared-session", "first-token");
    await setSharedPluginCredential(second, "shared-session", "second-token");
    assert.equal((await getRuntimePlugin(first, "com.example.shared")).enabled, true);
    assert.equal((await getRuntimePlugin(second, "com.example.shared")).enabled, false);
    assert.equal((await getPluginCredential(first, "shared-session")).token, "first-token");
    assert.equal((await getPluginCredential(second, "shared-session")).token, "second-token");

    await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify(manifest("1.1.0")));
    await installPlugin(first, source, { workspaceRoots: [first, second] });
    await ensurePluginRuntime(second);
    assert.equal((await getInstalledPlugin(second, "com.example.shared")).version, "1.1.0");
    assert.equal((await getRuntimePlugin(second, "com.example.shared")).enabled, false);
    assert.equal((await readRuntimeConfig(second)).mcpServers.find((server) => server.pluginId === "com.example.shared").enabled, false);
    assert.equal((await fs.readdir(path.join(root, "shared", "plugins"))).length, 1);
    await removePlugin(first, "com.example.shared", { workspaceRoots: [first, second] });
    assert.deepEqual((await adoptWorkspacePluginPackages([first, second])).adopted, []);
    assert.equal(await getInstalledPlugin(second, "com.example.shared"), null);
  } finally {
    if (originalSharedRoot === undefined) delete process.env.CODMES_SHARED_PLUGIN_ROOT;
    else process.env.CODMES_SHARED_PLUGIN_ROOT = originalSharedRoot;
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("a shared plugin update migrates each profile's collection without merging data", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-shared-migration-"));
  const first = path.join(root, "first");
  const second = path.join(root, "second");
  const source = path.join(root, "source");
  await fs.mkdir(source, { recursive: true });
  const originalSharedRoot = process.env.CODMES_SHARED_PLUGIN_ROOT;
  process.env.CODMES_SHARED_PLUGIN_ROOT = path.join(root, "shared");
  const manifest = (version, dataVersion) => ({
    schemaVersion: 1, id: "com.example.records", version, name: "Records",
    platforms: ["macos"], permissions: ["storage:workspace"], dataVersion,
    storage: {
      schemaVersion: 1,
      collections: [{
        id: "records",
        itemSchema: {
          type: "object", additionalProperties: false,
          properties: dataVersion === 1
            ? { id: { type: "string" }, title: { type: "string" } }
            : { id: { type: "string" }, name: { type: "string" } },
          required: dataVersion === 1 ? ["title"] : ["name"]
        }
      }]
    },
    ...(dataVersion === 2 ? { migrations: {
      schemaVersion: 1,
      migrations: [{ id: "records-v2", from: 1, to: 2,
        operations: [{ type: "renameField", collection: "records", from: "title", to: "name" }] }]
    } } : {}),
    surface: { id: "records", type: "declarative", title: "Records",
      upstreamUrl: "http://127.0.0.1", entryPath: "/",
      navigation: [{ id: "home", title: "Home", path: "/" }] }
  });
  try {
    await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify(manifest("1.0.0", 1)));
    await installPlugin(first, source, { workspaceRoots: [first, second] });
    const v1 = await getInstalledPlugin(first, "com.example.records");
    await mutatePluginCollection(first, v1, "records", "create", { item: { title: "A" } });
    await mutatePluginCollection(second, v1, "records", "create", { item: { title: "B" } });
    await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify(manifest("2.0.0", 2)));
    await installPlugin(second, source, { workspaceRoots: [first, second] });
    const v2 = await getInstalledPlugin(first, "com.example.records");
    assert.equal((await readPluginCollection(first, v2, "records")).items[0].name, "A");
    assert.equal((await readPluginCollection(second, v2, "records")).items[0].name, "B");
  } finally {
    if (originalSharedRoot === undefined) delete process.env.CODMES_SHARED_PLUGIN_ROOT;
    else process.env.CODMES_SHARED_PLUGIN_ROOT = originalSharedRoot;
    await fs.rm(root, { recursive: true, force: true });
  }
});
