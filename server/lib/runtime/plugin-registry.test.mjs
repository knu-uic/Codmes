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
import { listRuntimeViews } from "./plugin-runtime.mjs";

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
      logoutPath: "/api/auth/logout",
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
  const installedManifest = await getInstalledPlugin(root, manifest.id);
  assert.equal(installedManifest?.surface.id, "knu");
  assert.equal(installedManifest?.surface.auth.logoutPath, "/api/auth/logout");

  const config = await readRuntimeConfig(root);
  const mcp = config.mcpServers.find((server) => server.pluginId === manifest.id);
  assert.equal(mcp.name, "knu");
  assert.equal(mcp.allowUnauthenticated, true);
  assert.deepEqual(mcp.surfaces, ["knu"]);

  const surface = (await listRuntimeViews(root)).find((item) => item.id === "knu");
  assert.equal(surface.renderer, "declarative");
  assert.equal(surface.dataPath, `/api/plugins/${encodeURIComponent(manifest.id)}/view-document`);
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

test("plugin manifest normalizes OS and form-factor compatibility", () => {
  const modern = validatePluginManifest({
    ...manifest,
    platforms: ["MACOS", "ios", "android", "windows", "ios"],
    formFactors: ["PHONE", "tablet", "desktop", "phone"]
  });
  assert.deepEqual(modern.platforms, ["macos", "ios", "android", "windows"]);
  assert.deepEqual(modern.formFactors, ["phone", "tablet", "desktop"]);
  const legacy = validatePluginManifest({
    ...manifest,
    platforms: ["macos", "ios", "ipados"],
    formFactors: undefined
  });
  assert.deepEqual(legacy.platforms, ["macos", "ios"]);
  assert.deepEqual(legacy.formFactors, ["desktop", "phone", "tablet"]);
  assert.throws(
    () => validatePluginManifest({ ...manifest, platforms: [] }),
    /at least one platform/
  );
  assert.throws(
    () => validatePluginManifest({ ...manifest, platforms: ["linux"], formFactors: ["desktop"] }),
    /unsupported platforms: linux/
  );
  assert.throws(
    () => validatePluginManifest({ ...manifest, platforms: ["android"], formFactors: ["watch"] }),
    /unsupported formFactors: watch/
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

test("Surface v2 validates declared collection data sources and editor fields", () => {
  const value = {
    ...manifest,
    storage: {
      schemaVersion: 1,
      collections: [{
        id: "events",
        itemSchema: { type: "object", properties: { title: { type: "string" } } }
      }]
    },
    surface: {
      ...manifest.surface,
      navigation: undefined,
      ui: {
        schemaVersion: 2,
        routes: [{
          id: "events",
          title: "Events",
          dataSources: [{ id: "events", path: "collection:events" }],
          document: {
            schemaVersion: 2,
            presentation: "calendar",
            title: "Events",
            editor: {
              collection: "events",
              fields: [{
                id: "title",
                label: "Title",
                type: "text",
                required: true,
                role: "title"
              }]
            },
            collection: {
              source: "events.items",
              item: { id: "id", title: "title" }
            }
          }
        }]
      }
    }
  };

  const normalized = validatePluginManifest(value);
  assert.equal(normalized.surface.ui.schemaVersion, 2);
  assert.equal(normalized.surface.ui.routes[0].document.editor.collection, "events");
  assert.equal(normalized.surface.ui.routes[0].document.editor.fields[0].role, "title");

  const invalid = structuredClone(value);
  invalid.surface.ui.routes[0].document.editor.collection = "tasks";
  assert.throws(() => validatePluginManifest(invalid), /not declared/);
});

test("plugin installation resolves and confines package-owned MCP tool declarations", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-tools-root-"));
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-tools-source-"));
  await fs.writeFile(path.join(source, "tools.json"), JSON.stringify({
    schemaVersion: 1,
    tools: [{
      name: "knu_search_notices",
      description: "Search KNU notices.",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string" } },
        required: ["query"]
      },
      provider: { type: "mcp", server: "knu", tool: "search_knu_notices" },
      readOnly: true,
      requiresApproval: true
    }]
  }), "utf8");
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    ...manifest,
    tools: "tools.json"
  }), "utf8");

  const installed = await installPlugin(root, source);
  assert.equal(installed.plugin.tools[0].name, "knu_search_notices");
  assert.equal(installed.plugin.tools[0].provider.type, "mcp");
  assert.equal(installed.plugin.tools[0].provider.tool, "search_knu_notices");
  assert.deepEqual(installed.plugin.tools[0].surfaces, ["knu"]);
  assert.equal((await getInstalledPlugin(root, manifest.id)).tools[0].readOnly, true);
});
