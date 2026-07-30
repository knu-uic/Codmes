process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  DEFAULT_TOOL_MODES,
  loadToolModes,
  saveToolModeOverride,
  getEffectiveToolMode
} from "./tool-mode-registry.mjs";
import { WORKSPACE_TOOL_DEFINITIONS } from "./workspace-tools.mjs";
import { TOOL_DISCOVERY_DEFINITION, TOOL_REGISTRY } from "./tool-discovery.mjs";
import { CONVERSATION_SEARCH_DEFINITION, CONVERSATION_READ_DEFINITION } from "./conversation-tools.mjs";
import { MEMORY_SEARCH_DEFINITION } from "./memory-retrieval.mjs";
import { listRuntimeToolProviders } from "./plugin-runtime.mjs";

test("Tool Mode Registry: basic loading and defaults", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tool-modes-"));
  
  const modes = await loadToolModes(root);
  assert.equal(modes.chat.mode, "default");
  assert.ok(modes.chat.enabledTools.includes("tool_discovery"));
  assert.ok(modes.chat.enabledTools.includes("conversation_search"));
  
  assert.equal(modes.notes.mode, "default");
  assert.ok(modes.notes.enabledTools.includes("workspace_search"));
  
  assert.equal(modes.code.mode, "default");
  assert.ok(modes.code.enabledTools.includes("propose_patch"));
});

test("Tool Mode Registry: saving override and custom mode", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tool-modes-override-"));
  
  await saveToolModeOverride(root, "chat", {
    mode: "custom",
    enabledTools: ["web_search"],
    disabledTools: ["memory_search"]
  });
  
  const modes = await loadToolModes(root);
  assert.equal(modes.chat.mode, "custom");
  assert.ok(modes.chat.enabledTools.includes("web_search"));
  // Core recall tools are mandatory in surface modes, even when a custom mode tries to disable them.
  assert.ok(modes.chat.enabledTools.includes("memory_search"));
  // tool_discovery is mandatory and must be preserved
  assert.ok(modes.chat.enabledTools.includes("tool_discovery"));
  assert.ok(modes.chat.enabledTools.includes("conversation_search"));
  assert.ok(modes.chat.enabledTools.includes("conversation_read"));
});

test("Tool Mode Registry: safe mode overrides", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tool-modes-safe-"));
  
  await saveToolModeOverride(root, "code", {
    mode: "safe"
  });
  
  const modes = await loadToolModes(root);
  assert.equal(modes.code.mode, "safe");
  assert.ok(modes.code.requiresApproval.includes("apply_patch"));
  assert.ok(modes.code.requiresApproval.includes("run_checks"));
});

test("Tool Mode Registry: every configured tool name has a matching definition or registry entry", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tool-mode-definitions-"));
  const definedNames = new Set([
    ...WORKSPACE_TOOL_DEFINITIONS.map((tool) => tool.function.name),
    TOOL_DISCOVERY_DEFINITION.function.name,
    CONVERSATION_SEARCH_DEFINITION.function.name,
    CONVERSATION_READ_DEFINITION.function.name,
    MEMORY_SEARCH_DEFINITION.function.name
  ]);
  const registryNames = new Set(TOOL_REGISTRY.map((tool) => tool.name));
  for (const plugin of await listRuntimeToolProviders(root)) {
    for (const tool of plugin.tools) registryNames.add(tool.name);
  }

  for (const [surface, mode] of Object.entries(DEFAULT_TOOL_MODES)) {
    for (const toolName of mode.enabledTools || []) {
      assert.equal(
        definedNames.has(toolName) || registryNames.has(toolName),
        true,
        `${surface} mode references undefined tool '${toolName}'`
      );
    }
    for (const toolName of mode.requiresApproval || []) {
      assert.equal(
        definedNames.has(toolName) || registryNames.has(toolName),
        true,
        `${surface} approval list references undefined tool '${toolName}'`
      );
      assert.equal(
        registryNames.has(toolName),
        true,
        `${surface} approval tool '${toolName}' should be discoverable in the registry`
      );
    }
  }
});

test("Tool Mode Registry: surfaces expose focused default tools", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tool-modes-surface-"));
  const modes = await loadToolModes(root);

  assert.equal(modes.chat.enabledTools.includes("workspace_search"), false);
  assert.equal(modes.chat.enabledTools.includes("search_project"), false);
  assert.equal(modes.chat.enabledTools.includes("memory_search"), true);

  assert.equal(modes.notes.enabledTools.includes("codmes_search"), true);
  assert.equal(modes.notes.enabledTools.includes("read_note_file"), true);
  assert.equal(modes.notes.enabledTools.includes("apply_patch"), false);

  assert.equal(modes.code.enabledTools.includes("search_project"), true);
  assert.equal(modes.code.enabledTools.includes("apply_patch"), true);
  assert.equal(modes.code.requiresApproval.includes("apply_patch"), true);
  assert.equal(modes.code.requiresApproval.includes("run_git_command"), true);
});
