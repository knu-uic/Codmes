import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  executePluginCollectionTool,
  normalizePluginStorage,
  previewPluginCollectionTool
} from "./plugin-collection-store.mjs";

const manifest = {
  id: "com.codmes.planner",
  storage: normalizePluginStorage({
    schemaVersion: 1,
    collections: [{
      id: "events",
      itemSchema: {
        type: "object",
        properties: {
          title: { type: "string" },
          startsAt: { type: "string" },
          endsAt: { type: "string" }
        },
        required: ["title", "startsAt", "endsAt"]
      }
    }]
  })
};
const createTool = {
  pluginId: manifest.id,
  provider: { type: "plugin", id: manifest.id, tool: "collection.events.create" }
};

test("plugin collection provider creates, previews, updates, lists, and deletes items", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-plugin-collection-"));
  const created = await executePluginCollectionTool(root, manifest, createTool, {
    item: { title: "회의", startsAt: "2026-08-01T10:00:00+09:00", endsAt: "2026-08-01T11:00:00+09:00" }
  });
  assert.equal(created.created, true);
  const updateTool = { ...createTool, provider: { ...createTool.provider, tool: "collection.events.update" } };
  const preview = await previewPluginCollectionTool(root, updateTool, {
    id: created.item.id,
    item: { title: "변경된 회의" }
  });
  assert.equal(preview.before.title, "회의");
  assert.equal(preview.after.title, "변경된 회의");
  const updated = await executePluginCollectionTool(root, manifest, updateTool, {
    id: created.item.id,
    item: { title: "변경된 회의" }
  });
  assert.equal(updated.item.title, "변경된 회의");
  const listTool = { ...createTool, provider: { ...createTool.provider, tool: "collection.events.list" } };
  assert.equal((await executePluginCollectionTool(root, manifest, listTool)).items.length, 1);
  const deleteTool = { ...createTool, provider: { ...createTool.provider, tool: "collection.events.delete" } };
  assert.equal((await executePluginCollectionTool(root, manifest, deleteTool, { id: created.item.id })).deleted, true);
  assert.equal((await executePluginCollectionTool(root, manifest, listTool)).items.length, 0);
});
