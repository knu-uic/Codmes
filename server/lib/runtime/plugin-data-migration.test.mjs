import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  getInstalledPlugin,
  installPlugin,
  rollbackPlugin
} from "./plugin-registry.mjs";
import {
  mutatePluginCollection,
  readPluginCollection
} from "./plugin-collection-store.mjs";

test("plugin update migrates collection fields atomically and blocks incompatible rollback", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-migration-workspace-"));
  const v1 = await createSource("1.0.0", 1);
  await installPlugin(workspace, v1);
  let manifest = await getInstalledPlugin(workspace, "com.example.migration");
  await mutatePluginCollection(workspace, manifest, "memos", "create", {
    item: { title: "Migrated", body: "old text" }
  });

  const v2 = await createSource("2.0.0", 2);
  const updated = await installPlugin(workspace, v2);
  assert.deepEqual(updated.state.migration.steps, ["memos-v2"]);
  manifest = await getInstalledPlugin(workspace, "com.example.migration");
  const state = await readPluginCollection(workspace, manifest, "memos");
  assert.equal(state.items[0].content, "old text");
  assert.equal(state.items[0].pinned, false);
  assert.equal(Object.hasOwn(state.items[0], "body"), false);
  await assert.rejects(
    () => rollbackPlugin(workspace, "com.example.migration", "1.0.0"),
    /different data schema/
  );
});

test("plugin update leaves data and active version unchanged when migration validation fails", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-migration-failure-"));
  const v1 = await createSource("1.0.0", 1);
  await installPlugin(workspace, v1);
  let manifest = await getInstalledPlugin(workspace, "com.example.migration");
  await mutatePluginCollection(workspace, manifest, "memos", "create", {
    item: { title: "Keep me", body: "safe" }
  });
  const invalid = await createSource("2.0.0", 2, { omitMigration: true });
  await assert.rejects(() => installPlugin(workspace, invalid), /missing data migration/);
  manifest = await getInstalledPlugin(workspace, "com.example.migration");
  assert.equal(manifest.version, "1.0.0");
  const state = await readPluginCollection(workspace, manifest, "memos");
  assert.equal(state.items[0].body, "safe");
});

async function createSource(version, dataVersion, options = {}) {
  const source = await fs.mkdtemp(path.join(os.tmpdir(), `codmes-plugin-migration-${version}-`));
  const properties = dataVersion === 1
    ? {
        id: { type: "string" },
        title: { type: "string" },
        body: { type: "string" }
      }
    : {
        id: { type: "string" },
        title: { type: "string" },
        content: { type: "string" },
        pinned: { type: "boolean" }
      };
  const required = dataVersion === 1
    ? ["title", "body"]
    : ["title", "content", "pinned"];
  const manifest = {
    schemaVersion: 1,
    id: "com.example.migration",
    version,
    name: "Migration",
    platforms: ["macos", "ios"],
    permissions: ["storage:workspace"],
    dataVersion,
    storage: "storage.json",
    surface: {
      id: "migration",
      type: "declarative",
      title: "Migration",
      upstreamUrl: "http://127.0.0.1",
      entryPath: "/",
      navigation: [{ id: "home", title: "Home", path: "/" }]
    }
  };
  if (dataVersion === 2 && !options.omitMigration) manifest.migrations = "migrations.json";
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify(manifest));
  await fs.writeFile(path.join(source, "storage.json"), JSON.stringify({
    schemaVersion: 1,
    collections: [{
      id: "memos",
      itemSchema: {
        type: "object",
        additionalProperties: false,
        properties,
        required
      }
    }]
  }));
  if (manifest.migrations) {
    await fs.writeFile(path.join(source, "migrations.json"), JSON.stringify({
      schemaVersion: 1,
      migrations: [{
        id: "memos-v2",
        from: 1,
        to: 2,
        operations: [
          { type: "renameField", collection: "memos", from: "body", to: "content" },
          { type: "setDefault", collection: "memos", field: "pinned", value: false }
        ]
      }]
    }));
  }
  return source;
}
