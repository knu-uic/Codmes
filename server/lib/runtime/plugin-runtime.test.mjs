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
import { getInstalledPlugin } from "./plugin-registry.mjs";

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
