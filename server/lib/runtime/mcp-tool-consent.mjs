import fs from "node:fs/promises";
import path from "node:path";

const STATE_VERSION = 1;
const TOOL_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,128}$/;
const stateUpdates = new Map();

export async function reconcilePluginMcpTools(workspaceRoot, {
  pluginId,
  serverName,
  tools
}) {
  const id = normalizeId(pluginId, "plugin id");
  const server = normalizeId(serverName, "MCP server name");
  const discoveredTools = normalizeDiscoveredTools(tools);
  return await updateState(workspaceRoot, async (state) => {
    const previous = state.plugins[id];
    const discoveredNames = new Set(discoveredTools.map((tool) => tool.name));
    if (previous
        && previous.serverName === server
        && JSON.stringify(normalizeDiscoveredTools(previous.discoveredTools)) === JSON.stringify(discoveredTools)) {
      return publicConsent(previous);
    }
    const approvedTools = previous
      ? normalizeToolNames(previous.approvedTools).filter((name) => discoveredNames.has(name))
      : [];

    state.plugins[id] = {
      pluginId: id,
      serverName: server,
      approvedTools,
      discoveredTools,
      updatedAt: new Date().toISOString()
    };
    return publicConsent(state.plugins[id]);
  });
}

export async function getPluginMcpToolConsent(workspaceRoot, pluginId) {
  const id = normalizeId(pluginId, "plugin id");
  const pendingUpdate = stateUpdates.get(path.resolve(workspaceRoot));
  if (pendingUpdate) await pendingUpdate.catch(() => {});
  const state = await readState(workspaceRoot);
  return state.plugins[id] ? publicConsent(state.plugins[id]) : {
    pluginId: id,
    serverName: null,
    approvedTools: [],
    discoveredTools: [],
    pendingTools: [],
    updatedAt: null
  };
}

export async function setPluginMcpToolConsent(workspaceRoot, pluginId, approvedTools) {
  const id = normalizeId(pluginId, "plugin id");
  return await updateState(workspaceRoot, async (state) => {
    const entry = state.plugins[id];
    if (!entry) {
      throw Object.assign(new Error("Discover this plugin's MCP tools before approving them."), { status: 409 });
    }
    const approved = normalizeToolNames(approvedTools);
    const discoveredNames = new Set(entry.discoveredTools.map((tool) => tool.name));
    const unknown = approved.filter((name) => !discoveredNames.has(name));
    if (unknown.length) {
      throw Object.assign(new Error(`Cannot approve undiscovered MCP tools: ${unknown.join(", ")}`), { status: 400 });
    }
    entry.approvedTools = approved;
    entry.updatedAt = new Date().toISOString();
    return publicConsent(entry);
  });
}

export async function removePluginMcpToolConsent(workspaceRoot, pluginId) {
  const id = normalizeId(pluginId, "plugin id");
  return await updateState(workspaceRoot, async (state) => {
    const removed = Boolean(state.plugins[id]);
    delete state.plugins[id];
    return { removed, pluginId: id };
  });
}

function publicConsent(entry) {
  const approved = new Set(normalizeToolNames(entry.approvedTools));
  const discoveredTools = normalizeDiscoveredTools(entry.discoveredTools);
  return {
    pluginId: entry.pluginId,
    serverName: entry.serverName,
    approvedTools: [...approved],
    discoveredTools: discoveredTools.map((tool) => ({
      ...tool,
      approved: approved.has(tool.name)
    })),
    pendingTools: discoveredTools.filter((tool) => !approved.has(tool.name)).map((tool) => tool.name),
    updatedAt: entry.updatedAt || null
  };
}

function normalizeDiscoveredTools(tools) {
  if (!Array.isArray(tools)) return [];
  const seen = new Set();
  const normalized = [];
  for (const value of tools) {
    const name = String(value?.name || "").trim();
    if (!TOOL_NAME_PATTERN.test(name) || seen.has(name)) continue;
    seen.add(name);
    const catalog = value?._meta?.["com.codmes/tool"];
    normalized.push({
      name,
      description: String(value?.description || "").trim().slice(0, 1000),
      group: typeof catalog?.group === "string"
        ? catalog.group.trim().slice(0, 128)
        : (typeof value?.group === "string" ? value.group.trim().slice(0, 128) : null),
      readOnly: value?.annotations?.readOnlyHint === true || value?.readOnly === true,
      destructive: value?.annotations?.destructiveHint === true || value?.destructive === true
    });
  }
  return normalized.sort((left, right) => left.name.localeCompare(right.name));
}

function normalizeToolNames(values) {
  if (!Array.isArray(values)) throw Object.assign(new Error("approvedTools must be an array."), { status: 400 });
  const names = [...new Set(values.map((value) => String(value || "").trim()).filter(Boolean))];
  if (names.length > 256 || names.some((name) => !TOOL_NAME_PATTERN.test(name))) {
    throw Object.assign(new Error("approvedTools contains an invalid MCP tool name."), { status: 400 });
  }
  return names;
}

function normalizeId(value, label) {
  const result = String(value || "").trim();
  if (!result || result.length > 160) throw Object.assign(new Error(`Invalid ${label}.`), { status: 400 });
  return result;
}

function statePath(workspaceRoot) {
  return path.join(workspaceRoot, ".codmes", "plugin-runtime", "mcp-tool-consent.json");
}

async function readState(workspaceRoot) {
  try {
    const parsed = JSON.parse(await fs.readFile(statePath(workspaceRoot), "utf8"));
    return {
      schemaVersion: STATE_VERSION,
      plugins: parsed && typeof parsed.plugins === "object" && !Array.isArray(parsed.plugins)
        ? parsed.plugins
        : {}
    };
  } catch {
    return { schemaVersion: STATE_VERSION, plugins: {} };
  }
}

async function writeState(workspaceRoot, state) {
  const target = statePath(workspaceRoot);
  await fs.mkdir(path.dirname(target), { recursive: true });
  const temporary = `${target}.${process.pid}.tmp`;
  await fs.writeFile(temporary, JSON.stringify(state, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await fs.rename(temporary, target);
}

async function updateState(workspaceRoot, change) {
  const key = path.resolve(workspaceRoot);
  const previous = stateUpdates.get(key) || Promise.resolve();
  const operation = previous.catch(() => {}).then(async () => {
    const state = await readState(workspaceRoot);
    const before = JSON.stringify(state);
    const result = await change(state);
    if (JSON.stringify(state) !== before) await writeState(workspaceRoot, state);
    return result;
  });
  stateUpdates.set(key, operation);
  try {
    return await operation;
  } finally {
    if (stateUpdates.get(key) === operation) stateUpdates.delete(key);
  }
}
