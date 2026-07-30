import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { ensureBuiltInPlugins } from "./builtin-plugins.mjs";
import {
  getInstalledPlugin,
  getPluginInstallState,
  installPlugin,
  removePlugin,
  rollbackPlugin
} from "./plugin-registry.mjs";

test("Planner is provisioned as a built-in plugin and preserves existing Workspace data", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-builtin-planner-"));
  const first = await ensureBuiltInPlugins(root);
  assert.equal(first[0].action, "installed");

  const planner = await getInstalledPlugin(root, "com.codmes.planner");
  assert.equal(planner.distribution, "builtin");
  assert.equal(planner.removable, false);
  assert.equal((await getPluginInstallState(root, planner.id)).source.type, "builtin");

  const dataDirectory = path.join(root, ".codmes", "plugin-data", planner.id);
  await fs.mkdir(dataDirectory, { recursive: true });
  const dataPath = path.join(dataDirectory, "tasks.json");
  const existingData = JSON.stringify({ schemaVersion: 1, items: [{ id: "keep-me" }] });
  await fs.writeFile(dataPath, existingData, "utf8");

  const statePath = path.join(root, ".codmes", "plugins", planner.id, "state.json");
  const state = JSON.parse(await fs.readFile(statePath, "utf8"));
  state.source = { type: "marketplace", pluginId: planner.id, version: planner.version };
  await fs.writeFile(statePath, JSON.stringify(state, null, 2) + "\n", "utf8");

  const migrated = await ensureBuiltInPlugins(root);
  assert.equal(migrated[0].action, "migrated-or-updated");
  assert.equal((await getPluginInstallState(root, planner.id)).source.type, "builtin");
  assert.equal(await fs.readFile(dataPath, "utf8"), existingData);

  const unchanged = await ensureBuiltInPlugins(root);
  assert.equal(unchanged[0].action, "unchanged");
});

test("Planner cannot be installed, removed, or rolled back independently", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-builtin-policy-"));
  const source = path.resolve("bundled/plugins/planner");

  await assert.rejects(
    () => installPlugin(root, source),
    (error) => error.status === 409 && error.code === "builtin_plugin_managed_by_codmes"
  );
  await ensureBuiltInPlugins(root);
  await assert.rejects(
    () => removePlugin(root, "com.codmes.planner"),
    (error) => error.status === 409 && error.code === "builtin_plugin_cannot_be_removed"
  );
  await assert.rejects(
    () => rollbackPlugin(root, "com.codmes.planner"),
    (error) => error.status === 409 && error.code === "builtin_plugin_managed_by_codmes"
  );
});
