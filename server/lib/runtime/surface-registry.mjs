import fs from "node:fs/promises";
import path from "node:path";
import { saveToolModeOverride } from "./tool-mode-registry.mjs";
import { listInstalledPlugins } from "./plugin-registry.mjs";

const DEFAULT_SURFACES = [
  {
    id: "chat",
    title: "Chat",
    kind: "core",
    icon: "message",
    enabled: true,
    removable: false,
    order: 10,
    description: "General conversation, recall, memory, and tool discovery."
  },
  {
    id: "notes",
    title: "Notes",
    kind: "core",
    icon: "doc.text",
    enabled: true,
    removable: false,
    order: 20,
    description: "Notes, documents, PDF text, and Codmes built-in search."
  },
  {
    id: "code",
    title: "Code",
    kind: "core",
    icon: "chevron.left.forwardslash.chevron.right",
    enabled: true,
    removable: false,
    order: 30,
    description: "Code projects, planning, inspection, patches, checks, git, and approvals."
  }
];

export async function ensureSurfaceRegistryDir(workspaceRoot) {
  const dir = path.join(workspaceRoot, ".codmes", "surfaces");
  await fs.mkdir(dir, { recursive: true });
  return dir;
}

export async function loadSurfaces(workspaceRoot) {
  const manifests = await readPluginSurfaceManifests(workspaceRoot);
  const overrides = await readSurfaceOverrides(workspaceRoot);
  const byId = new Map(DEFAULT_SURFACES.map((surface) => [surface.id, { ...surface }]));
  for (const manifest of manifests) {
    if (!manifest?.id) continue;
    byId.set(manifest.id, {
      id: manifest.id,
      title: titleFromId(manifest.id),
      kind: "plugin",
      icon: "square.grid.2x2",
      enabled: true,
      removable: true,
      order: 1000,
      description: "",
      ...pickSurfaceFields(manifest, {})
    });
  }
  for (const [id, override] of Object.entries(overrides)) {
    if (!override || typeof override !== "object") continue;
    const base = byId.get(id) || {
      id,
      title: titleFromId(id),
      kind: "plugin",
      icon: "square.grid.2x2",
      enabled: true,
      removable: true,
      order: 1000,
      description: ""
    };
    byId.set(id, {
      ...base,
      ...pickSurfaceFields(override, base),
      id
    });
  }
  return Array.from(byId.values())
    .sort((a, b) => (a.order ?? 1000) - (b.order ?? 1000) || a.title.localeCompare(b.title));
}

async function readPluginSurfaceManifests(workspaceRoot) {
  const installed = await listInstalledPlugins(workspaceRoot);
  const manifests = installed.map((plugin) => ({
    id: plugin.surface.id,
    title: plugin.surface.title,
    description: plugin.surface.description || plugin.description,
    icon: plugin.surface.icon,
    order: plugin.surface.order,
    pluginId: plugin.id,
    kind: "plugin",
    renderer: plugin.surface.type,
    dataPath: `/api/plugins/${encodeURIComponent(plugin.id)}/surface-document`,
    navigation: plugin.surface.navigation,
    hasAuthentication: Boolean(plugin.surface.auth)
  }));
  const pluginsDir = path.join(workspaceRoot, ".codmes", "plugins");
  let entries = [];
  try {
    entries = await fs.readdir(pluginsDir, { withFileTypes: true });
  } catch {
    return manifests;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (installed.some((plugin) => plugin.id === entry.name)) continue;
    const file = path.join(pluginsDir, entry.name, "surface.json");
    try {
      const parsed = JSON.parse(await fs.readFile(file, "utf8"));
      const id = normalizeSurfaceId(parsed.id || entry.name);
      if (!id) continue;
      manifests.push({
        ...parsed,
        id,
        pluginId: String(parsed.pluginId || entry.name),
        kind: "plugin"
      });
    } catch {}
  }
  return manifests;
}

export async function saveSurfaceOverride(workspaceRoot, surfaceId, config = {}) {
  const id = normalizeSurfaceId(surfaceId);
  if (!id) throw Object.assign(new Error("Surface id is required."), { status: 400 });
  const surfaces = await loadSurfaces(workspaceRoot);
  const current = surfaces.find((surface) => surface.id === id);
  if (current?.removable === false && config.remove === true) {
    throw Object.assign(new Error(`Core surface '${id}' cannot be removed.`), { status: 400 });
  }

  const overrides = await readSurfaceOverrides(workspaceRoot);
  if (config.remove === true) {
    delete overrides[id];
  } else {
    overrides[id] = {
      ...(overrides[id] || {}),
      ...pickSurfaceFields(config, current || {})
    };
  }
  await writeSurfaceOverrides(workspaceRoot, overrides);
  if (Array.isArray(config.enabledTools) || Array.isArray(config.disabledTools) || Array.isArray(config.requiresApproval)) {
    await saveToolModeOverride(workspaceRoot, id, {
      mode: "custom",
      enabledTools: Array.isArray(config.enabledTools) ? config.enabledTools.map(String) : undefined,
      disabledTools: Array.isArray(config.disabledTools) ? config.disabledTools.map(String) : undefined,
      requiresApproval: Array.isArray(config.requiresApproval) ? config.requiresApproval.map(String) : undefined
    });
  }
  return (await loadSurfaces(workspaceRoot)).find((surface) => surface.id === id) || null;
}

export function defaultSurfaces() {
  return DEFAULT_SURFACES.map((surface) => ({ ...surface }));
}

async function readSurfaceOverrides(workspaceRoot) {
  const file = path.join(await ensureSurfaceRegistryDir(workspaceRoot), "user-surfaces.json");
  try {
    return JSON.parse(await fs.readFile(file, "utf8"));
  } catch {
    return {};
  }
}

async function writeSurfaceOverrides(workspaceRoot, overrides) {
  const file = path.join(await ensureSurfaceRegistryDir(workspaceRoot), "user-surfaces.json");
  await fs.writeFile(file, JSON.stringify(overrides, null, 2), "utf8");
}

function pickSurfaceFields(value, base = {}) {
  const picked = {};
  for (const key of ["title", "kind", "icon", "description", "prompt", "toolMode", "root", "pluginId", "renderer", "dataPath"]) {
    if (typeof value[key] === "string") picked[key] = value[key];
  }
  if (typeof value.enabled === "boolean") picked.enabled = value.enabled;
  if (typeof value.removable === "boolean") picked.removable = value.removable;
  if (Number.isFinite(value.order)) picked.order = value.order;
  if (Array.isArray(value.enabledTools)) picked.enabledTools = value.enabledTools.map(String);
  if (Array.isArray(value.disabledTools)) picked.disabledTools = value.disabledTools.map(String);
  if (Array.isArray(value.requiresApproval)) picked.requiresApproval = value.requiresApproval.map(String);
  if (Array.isArray(value.navigation)) picked.navigation = value.navigation;
  if (typeof value.hasAuthentication === "boolean") picked.hasAuthentication = value.hasAuthentication;
  if (base.removable === false) picked.removable = false;
  return picked;
}

function normalizeSurfaceId(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function titleFromId(id) {
  return String(id || "Surface")
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part.slice(0, 1).toUpperCase() + part.slice(1))
    .join(" ");
}
