process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import { executeToolDiscovery } from "./tool-discovery.mjs";

test("Tool Discovery: traverses groups before exposing leaf tools", async () => {
  const root = await executeToolDiscovery("/tmp", "chat", {
    reason: "testing notes search",
    desiredCapability: "search notes"
  });

  assert.deepEqual(root.tools, []);
  assert.ok(root.groups.some((group) => group.path === "notes"));

  const branch = await executeToolDiscovery("/tmp", "chat", {
    reason: "testing notes search",
    desiredCapability: "search notes",
    path: "notes"
  });
  assert.deepEqual(branch.tools, []);
  assert.ok(branch.groups.some((group) => group.path === "notes.search"));

  const leaf = await executeToolDiscovery("/tmp", "chat", {
    reason: "testing notes search",
    desiredCapability: "search notes",
    path: "notes.search"
  });
  assert.equal(leaf.leaf, true);
  assert.ok(leaf.tools.some((tool) => tool.name === "codmes_search"));
  assert.ok(leaf.expandedToolsForThisTurn.includes("codmes_search"));
});

test("Tool Discovery: unknown paths do not expose tools", async () => {
  const res = await executeToolDiscovery("/tmp", "chat", {
    reason: "nothing",
    desiredCapability: "unmatched-nonexistent-capability",
    path: "does.not.exist"
  });

  assert.equal(res.tools.length, 0);
  assert.equal(res.recommendation.enableForThisTurn.length, 0);
});

test("Tool Discovery: cannot skip an unrevealed hierarchy level", async () => {
  const res = await executeToolDiscovery("/tmp", "chat", {
    reason: "search notes",
    desiredCapability: "search documents",
    path: "notes.search"
  }, {
    allowedPaths: [""]
  });

  assert.equal(res.requestedPathDeferred, "notes.search");
  assert.equal(res.nextSuggestedPath, "notes");
  assert.ok(res.groups.some((group) => group.path === "notes"));
  assert.deepEqual(res.tools, []);
  assert.deepEqual(res.expandedToolsForThisTurn, []);
});

test("Tool Discovery: suggests the current Surface route without auto-running its tools", async () => {
  const root = await executeToolDiscovery("/tmp", "notes", {
    reason: "current note question",
    desiredCapability: "search this document"
  }, { route: "search" });
  assert.equal(root.nextSuggestedPath, "notes");
  assert.deepEqual(root.expandedToolsForThisTurn, []);

  const notes = await executeToolDiscovery("/tmp", "notes", {
    reason: "current note question",
    desiredCapability: "search this document",
    path: "notes"
  }, { route: "search" });
  assert.equal(notes.nextSuggestedPath, "notes.search");
  assert.deepEqual(notes.expandedToolsForThisTurn, []);
});

test("Tool Discovery: exposes approval-gated tools but execution still requires approval", async () => {
  const res = await executeToolDiscovery("/tmp", "chat", {
    reason: "need edits",
    desiredCapability: "apply patch",
    path: "code.edit"
  });

  assert.ok(res.tools.some((tool) => tool.name === "apply_patch" && tool.requiresApproval));
  assert.equal(res.expandedToolsForThisTurn.includes("apply_patch"), true);
  assert.equal(res.recommendation.enableForThisTurn.includes("apply_patch"), true);
});

test("Tool Discovery: Planner separates tasks, calendar, and memos", async () => {
  const branch = await executeToolDiscovery("/tmp", "chat", {
    reason: "copy work into planner",
    desiredCapability: "create planner tasks",
    path: "planner"
  });
  assert.deepEqual(branch.groups.map((group) => group.path), [
    "planner.calendar",
    "planner.memos",
    "planner.tasks"
  ]);

  const leaf = await executeToolDiscovery("/tmp", "chat", {
    reason: "copy work into planner",
    desiredCapability: "create planner tasks",
    path: "planner.tasks"
  });
  assert.ok(leaf.tools.some((tool) => tool.name === "planner_create" && tool.requiresApproval));
  assert.ok(leaf.expandedToolsForThisTurn.includes("planner_create"));
});

test("Tool Discovery: disabled tools are discoverable but blocked from turn expansion", async () => {
  const res = await executeToolDiscovery("/tmp", "chat", {
    reason: "need indexed notes",
    desiredCapability: "search indexed pdf notes documents",
    path: "notes.search"
  }, {
    disabledTools: ["codmes_search"]
  });

  assert.ok(res.tools.some((tool) => tool.name === "codmes_search" && tool.disabledByUser === true));
  assert.equal(res.expandedToolsForThisTurn.includes("codmes_search"), false);
  assert.equal(res.blockedTools.some((tool) => tool.name === "codmes_search" && tool.reason === "disabled_by_surface_mode"), true);
});

test("Tool Discovery: uses live MCP tools and server-owned group descriptions", async () => {
  const runtimeTools = [{
    name: "knu_search_notice_details",
    description: "Search detailed KNU notice evidence.",
    group: "knu.notices",
    groupDescriptions: {
      knu: "KNU data supplied by the MCP server.",
      "knu.notices": "Live notice tools supplied by the MCP server."
    },
    surfaces: ["knu"],
    requiresApproval: false,
    provider: { type: "mcp", id: "knu", tool: "knu_search_notice_details" },
    pluginId: "kr.ac.kongju.knu"
  }];
  const root = await executeToolDiscovery("/tmp", "knu", {
    reason: "need university evidence",
    desiredCapability: "search notices"
  }, { runtimeTools });
  assert.deepEqual(root.groups.find((group) => group.path === "knu"), {
    path: "knu",
    description: "KNU data supplied by the MCP server."
  });

  const branch = await executeToolDiscovery("/tmp", "knu", {
    reason: "need university evidence",
    desiredCapability: "search notices",
    path: "knu"
  }, { runtimeTools });
  assert.equal(branch.groups[0].description, "Live notice tools supplied by the MCP server.");

  const leaf = await executeToolDiscovery("/tmp", "knu", {
    reason: "need university evidence",
    desiredCapability: "search notices",
    path: "knu.notices"
  }, { runtimeTools });
  assert.deepEqual(leaf.expandedToolsForThisTurn, ["knu_search_notice_details"]);
});
