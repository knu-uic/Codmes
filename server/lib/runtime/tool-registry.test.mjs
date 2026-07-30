import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizePluginToolDocument,
  ToolRegistry
} from "./tool-registry.mjs";

const calendarCreate = {
  name: "calendar_create",
  description: "Create an event in the user's calendar.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      title: { type: "string" },
      startsAt: { type: "string", format: "date-time" },
      endsAt: { type: "string", format: "date-time" }
    },
    required: ["title", "startsAt", "endsAt"]
  },
  provider: { type: "plugin", id: "com.codmes.planner", tool: "event.create" },
  surfaces: ["calendar"],
  requiresApproval: true
};

const notesSearch = {
  name: "notes_search",
  description: "Search notes by text and optional folder.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      query: { type: "string" },
      folderId: { type: "string" },
      limit: { type: "integer" }
    },
    required: ["query"]
  },
  provider: { type: "native", id: "workspace", tool: "notes.search" },
  surfaces: ["notes"],
  readOnly: true
};

test("Tool Registry keeps different input schemas behind one provider contract", async () => {
  const calls = [];
  const registry = new ToolRegistry({
    adapters: {
      native: { execute: async (descriptor, args) => ({ descriptor, args }) },
      plugin: {
        execute: async (descriptor, args) => {
          calls.push({ descriptor, args });
          return { created: true };
        }
      }
    }
  });
  registry.register(calendarCreate);
  registry.register(notesSearch);

  assert.deepEqual(
    registry.get("calendar_create").inputSchema.required,
    ["title", "startsAt", "endsAt"]
  );
  assert.deepEqual(registry.get("notes_search").inputSchema.required, ["query"]);
  assert.deepEqual(registry.list({ surface: "notes" }).map((tool) => tool.name), ["notes_search"]);
  assert.equal(registry.openAITools().length, 2);
  assert.deepEqual(
    await registry.execute("calendar_create", {
      title: "팀 회의",
      startsAt: "2026-08-01T10:00:00+09:00",
      endsAt: "2026-08-01T11:00:00+09:00"
    }),
    { created: true }
  );
  assert.equal(calls[0].descriptor.provider.type, "plugin");
});

test("Plugin tool documents are confined to their own MCP and Surface", () => {
  const tools = normalizePluginToolDocument({
    schemaVersion: 1,
    tools: [{
      name: "knu_search_notices",
      description: "Search current Kongju National University notices.",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string" } },
        required: ["query"]
      },
      provider: { type: "mcp", server: "knu", tool: "search_knu_notices" },
      requiresApproval: true
    }]
  }, {
    pluginId: "kr.ac.kongju.knu",
    surfaceId: "knu",
    mcpName: "knu"
  });
  assert.equal(tools[0].provider.tool, "search_knu_notices");
  assert.deepEqual(tools[0].surfaces, ["knu"]);
  assert.throws(
    () => normalizePluginToolDocument({
      schemaVersion: 1,
      tools: [{
        name: "unsafe",
        description: "Escapes the plugin boundary.",
        inputSchema: { type: "object" },
        provider: { type: "mcp", server: "other", tool: "unsafe" },
        surfaces: ["chat"]
      }]
    }, {
      pluginId: "kr.ac.kongju.knu",
      surfaceId: "knu",
      mcpName: "knu"
    }),
    /own MCP server/
  );
});

test("Plugin collection tools must target declared Workspace storage", () => {
  const tools = normalizePluginToolDocument({
    schemaVersion: 1,
    tools: [{
      name: "calendar_create",
      description: "Create a calendar event.",
      inputSchema: { type: "object", properties: { item: { type: "object" } }, required: ["item"] },
      provider: { type: "plugin", id: "com.codmes.planner", tool: "collection.events.create" },
      requiresApproval: true
    }]
  }, {
    pluginId: "com.codmes.planner",
    surfaceId: "calendar",
    storageCollections: ["events"]
  });
  assert.equal(tools[0].provider.type, "plugin");
  assert.throws(() => normalizePluginToolDocument({
    schemaVersion: 1,
    tools: [{
      name: "calendar_create",
      description: "Create an undeclared item.",
      inputSchema: { type: "object" },
      provider: { type: "plugin", id: "com.codmes.planner", tool: "collection.private.create" }
    }]
  }, {
    pluginId: "com.codmes.planner",
    surfaceId: "calendar",
    storageCollections: ["events"]
  }), /declared collection/);
});
