import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  getPluginMcpToolConsent,
  removePluginMcpToolConsent,
  reconcilePluginMcpTools,
  setPluginMcpToolConsent
} from "./mcp-tool-consent.mjs";

test("new plugin MCP tools remain pending until the Workspace approves them", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-mcp-consent-"));
  const first = await reconcilePluginMcpTools(root, {
    pluginId: "com.example.plugin",
    serverName: "example",
    tools: [{
      name: "read_items",
      description: "Read items",
      annotations: { readOnlyHint: true },
      _meta: { "com.codmes/tool": { group: "example.read" } }
    }]
  });
  assert.deepEqual(first.approvedTools, []);
  assert.deepEqual(first.pendingTools, ["read_items"]);
  assert.equal(first.discoveredTools[0].approved, false);

  const approved = await setPluginMcpToolConsent(root, "com.example.plugin", ["read_items"]);
  assert.deepEqual(approved.approvedTools, ["read_items"]);
  assert.deepEqual(approved.pendingTools, []);

  const changed = await reconcilePluginMcpTools(root, {
    pluginId: "com.example.plugin",
    serverName: "example",
    tools: [{ name: "read_items" }, { name: "delete_everything", annotations: { destructiveHint: true } }]
  });
  assert.deepEqual(changed.approvedTools, ["read_items"]);
  assert.deepEqual(changed.pendingTools, ["delete_everything"]);
  assert.equal(changed.discoveredTools.find((tool) => tool.name === "delete_everything").destructive, true);
});

test("approval survives catalog refresh but is removed with the plugin", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-mcp-consent-migration-"));
  const consent = await reconcilePluginMcpTools(root, {
    pluginId: "com.example.legacy",
    serverName: "legacy",
    tools: [{ name: "old_tool" }, { name: "new_tool" }]
  });
  assert.deepEqual(consent.approvedTools, []);
  await setPluginMcpToolConsent(root, "com.example.legacy", ["old_tool"]);
  assert.deepEqual((await getPluginMcpToolConsent(root, "com.example.legacy")).approvedTools, ["old_tool"]);
  await assert.rejects(
    () => setPluginMcpToolConsent(root, "com.example.legacy", ["unknown_tool"]),
    /undiscovered/
  );
  await removePluginMcpToolConsent(root, "com.example.legacy");
  assert.deepEqual((await getPluginMcpToolConsent(root, "com.example.legacy")).approvedTools, []);
});
