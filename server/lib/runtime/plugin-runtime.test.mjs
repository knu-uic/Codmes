import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  ensurePluginRuntime,
  listRuntimePlugins,
  listRuntimeToolProviders,
  listRuntimeViews,
  savePluginConfiguration
} from "./plugin-runtime.mjs";
import {
  getInstalledPlugin,
  readPluginManifestSource
} from "./plugin-registry.mjs";

test("Plugin Runtime exposes Chat, Notes, Code, and Planner as built-in plugins", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-runtime-"));
  await ensurePluginRuntime(root);

  const plugins = await listRuntimePlugins(root);
  assert.deepEqual(
    plugins.map((plugin) => plugin.id),
    ["com.codmes.chat", "com.codmes.notes", "com.codmes.code", "com.codmes.planner"]
  );
  assert.equal(plugins.every((plugin) => plugin.distribution === "builtin"), true);
  assert.equal(plugins.every((plugin) => plugin.removable === false), true);
  assert.equal(
    plugins.every((plugin) => plugin.platforms.includes("android")
      && plugin.platforms.includes("windows")),
    true
  );
  assert.equal(
    plugins.every((plugin) => plugin.formFactors.join(",") === "phone,tablet,desktop"),
    true
  );
  assert.deepEqual(
    (await listRuntimeViews(root)).map((view) => view.id),
    ["chat", "notes", "code", "planner"]
  );
  assert.equal(await getInstalledPlugin(root, "com.codmes.planner"), null);

  const planner = (await listRuntimeToolProviders(root)).find(
    (plugin) => plugin.id === "com.codmes.planner"
  );
  assert.equal(planner.tools[0].provider.type, "plugin");
});

test("Plugin Runtime stores enablement by plugin and rejects built-in removal", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-settings-"));
  await savePluginConfiguration(root, "notes", { enabled: false });
  const notes = (await listRuntimePlugins(root)).find(
    (plugin) => plugin.id === "com.codmes.notes"
  );
  assert.equal(notes.enabled, false);
  assert.equal(
    (await listRuntimeViews(root)).find((view) => view.id === "notes").enabled,
    false
  );
  await assert.rejects(
    () => savePluginConfiguration(root, "com.codmes.notes", { remove: true }),
    (error) => error.code === "builtin_plugin_cannot_be_removed"
  );
});

test("Plugin Runtime ignores stale installed copies of built-in plugins", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-deduplicate-"));
  const manifest = await readPluginManifestSource(
    path.resolve("bundled/plugins/planner")
  );
  const installRoot = path.join(
    root,
    ".codmes",
    "plugins",
    manifest.id,
    "versions",
    manifest.version
  );
  await fs.mkdir(installRoot, { recursive: true });
  await fs.writeFile(
    path.join(installRoot, "plugin.json"),
    JSON.stringify(manifest, null, 2) + "\n",
    "utf8"
  );
  await fs.writeFile(
    path.join(root, ".codmes", "plugins", manifest.id, "state.json"),
    JSON.stringify({
      schemaVersion: 1,
      currentVersion: manifest.version,
      previousVersion: null
    }, null, 2) + "\n",
    "utf8"
  );

  assert.equal(await getInstalledPlugin(root, manifest.id) != null, true);
  const plugins = await listRuntimePlugins(root);
  assert.equal(plugins.filter((plugin) => plugin.id === manifest.id).length, 1);
  assert.equal(plugins.find((plugin) => plugin.id === manifest.id).distribution, "builtin");
  assert.equal(
    (await listRuntimeViews(root)).filter((view) => view.id === "planner").length,
    1
  );
});
