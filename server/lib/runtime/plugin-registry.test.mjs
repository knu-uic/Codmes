import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { readRuntimeConfig } from "./config-store.mjs";
import {
  getInstalledPlugin,
  installPlugin,
  listInstalledPlugins,
  removePlugin,
  resolvePluginSurfaceTarget,
  validatePluginManifest
} from "./plugin-registry.mjs";
import { loadSurfaces } from "./surface-registry.mjs";

const manifest = {
  schemaVersion: 1,
  id: "kr.ac.kongju.knu",
  version: "0.1.0",
  name: "KNU",
  platforms: ["macos", "ios", "ipados"],
  surface: {
    id: "knu",
    type: "declarative",
    title: "KNU",
    upstreamUrl: "http://127.0.0.1",
    entryPath: "/api/codmes/surface",
    navigation: [
      { id: "notices", title: "Notices", path: "/api/codmes/surface/notices" },
      { id: "settings", title: "Settings", path: "/api/codmes/surface/settings", requiresAuth: true }
    ],
    auth: {
      type: "password",
      credentialId: "knu-user-session",
      loginPath: "/api/auth/login",
      statusPath: "/api/me"
    },
    order: 100
  },
  mcp: {
    name: "knu",
    transport: "streamable_http",
    url: "http://127.0.0.1:8000/api/mcp",
    surfaces: ["knu"],
    allowUnauthenticated: true,
    requiresApproval: true
  }
};

test("a plugin installs and removes its surface and MCP as one unit", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-root-"));
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-source-"));
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify(manifest), "utf8");

  const installed = await installPlugin(root, source);
  assert.equal(installed.plugin.id, manifest.id);
  assert.equal((await listInstalledPlugins(root)).length, 1);
  assert.equal((await getInstalledPlugin(root, manifest.id))?.surface.id, "knu");

  const config = await readRuntimeConfig(root);
  const mcp = config.mcpServers.find((server) => server.pluginId === manifest.id);
  assert.equal(mcp.name, "knu");
  assert.equal(mcp.allowUnauthenticated, true);
  assert.deepEqual(mcp.surfaces, ["knu"]);

  const surface = (await loadSurfaces(root)).find((item) => item.id === "knu");
  assert.equal(surface.renderer, "declarative");
  assert.equal(surface.dataPath, `/api/plugins/${encodeURIComponent(manifest.id)}/surface-document`);
  assert.deepEqual(surface.navigation.map((item) => item.id), ["notices", "settings"]);
  assert.equal(surface.hasAuthentication, true);

  const conflictingSource = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-conflict-"));
  await fs.writeFile(path.join(conflictingSource, "plugin.json"), JSON.stringify({
    ...manifest,
    id: "com.example.other",
    mcp: { ...manifest.mcp, name: "other" }
  }), "utf8");
  await assert.rejects(() => installPlugin(root, conflictingSource), /Surface id 'knu' is already in use/);

  const target = await resolvePluginSurfaceTarget(root, manifest.id, "api/notices", "?limit=20");
  assert.equal(target.url.toString(), "http://127.0.0.1/api/notices?limit=20");

  assert.equal((await removePlugin(root, manifest.id)).removed, true);
  assert.equal(await getInstalledPlugin(root, manifest.id), null);
  assert.equal((await readRuntimeConfig(root)).mcpServers.some((server) => server.pluginId === manifest.id), false);
});

test("plugin manifest rejects insecure remote services and cross-surface MCP access", () => {
  assert.throws(
    () => validatePluginManifest({
      ...manifest,
      surface: { ...manifest.surface, upstreamUrl: "http://example.com" }
    }),
    /HTTPS/
  );
  assert.throws(
    () => validatePluginManifest({
      ...manifest,
      mcp: { ...manifest.mcp, surfaces: ["chat"] }
    }),
    /own surface/
  );
});

test("plugin installation resolves a package-owned Surface UI file", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-ui-root-"));
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-ui-source-"));
  const ui = {
    schemaVersion: 1,
    routes: [{
      id: "notices",
      title: "Notices",
      icon: "bell",
      dataSources: [{ id: "notices", path: "/api/notices?limit=100" }],
      document: {
        schemaVersion: 1,
        presentation: "collection",
        title: "Notices",
        collection: {
          source: "notices.notices",
          item: { id: "url", title: "title" }
        }
      }
    }]
  };
  await fs.writeFile(path.join(source, "surface.json"), JSON.stringify(ui), "utf8");
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    ...manifest,
    surface: {
      ...manifest.surface,
      navigation: undefined,
      ui: "surface.json"
    }
  }), "utf8");

  const installed = await installPlugin(root, source);

  assert.equal(installed.plugin.surface.ui.schemaVersion, 1);
  assert.deepEqual(installed.plugin.surface.navigation.map((item) => item.id), ["notices"]);
  assert.equal(installed.plugin.surface.ui.routes[0].dataSources[0].path, "/api/notices?limit=100");
  assert.deepEqual(
    (await getInstalledPlugin(root, manifest.id)).surface.ui,
    installed.plugin.surface.ui
  );
});
