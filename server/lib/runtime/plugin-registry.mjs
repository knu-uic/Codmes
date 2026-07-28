import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import {
  ensureRuntimeConfig,
  readRuntimeConfig,
  writeRuntimeConfig
} from "./config-store.mjs";

const PLUGIN_SCHEMA_VERSION = 1;
const PLUGIN_ID_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)+$/;
const SURFACE_ID_PATTERN = /^[a-z0-9][a-z0-9_-]*$/;
const MCP_NAME_PATTERN = /^[a-zA-Z0-9_-]+$/;

export function pluginsDirectory(workspaceRoot) {
  return path.join(workspaceRoot, ".codmes", "plugins");
}

export async function ensurePluginsDirectory(workspaceRoot) {
  const directory = pluginsDirectory(workspaceRoot);
  await fs.mkdir(directory, { recursive: true });
  return directory;
}

export async function readPluginManifestSource(sourcePath) {
  const absolute = path.resolve(String(sourcePath || ""));
  const stat = await fs.stat(absolute);
  const manifestPath = stat.isDirectory() ? path.join(absolute, "plugin.json") : absolute;
  const parsed = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  return validatePluginManifest(parsed);
}

export function validatePluginManifest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin manifest must be a JSON object.");
  }
  if (Number(value.schemaVersion) !== PLUGIN_SCHEMA_VERSION) {
    throw new Error(`Plugin schemaVersion must be ${PLUGIN_SCHEMA_VERSION}.`);
  }

  const id = String(value.id || "").trim().toLowerCase();
  const version = String(value.version || "").trim();
  const name = String(value.name || "").trim();
  if (!PLUGIN_ID_PATTERN.test(id)) {
    throw new Error("Plugin id must be a reverse-domain style identifier.");
  }
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error("Plugin version must use semantic versioning.");
  }
  if (!name) throw new Error("Plugin name is required.");

  const surface = normalizeDeclarativeSurface(value.surface, id, name);
  const mcp = normalizePluginMcp(value.mcp, id, surface.id);
  const platforms = Array.isArray(value.platforms)
    ? [...new Set(value.platforms.map(String).map((item) => item.trim().toLowerCase()).filter(Boolean))]
    : [];
  if (!platforms.length) throw new Error("Plugin must declare at least one platform.");

  return {
    schemaVersion: PLUGIN_SCHEMA_VERSION,
    id,
    version,
    name,
    description: String(value.description || "").trim(),
    publisher: String(value.publisher || "").trim(),
    platforms,
    permissions: Array.isArray(value.permissions)
      ? [...new Set(value.permissions.map(String).map((item) => item.trim()).filter(Boolean))]
      : [],
    surface,
    mcp
  };
}

function normalizeDeclarativeSurface(value, pluginId, pluginName) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin must include a declarative surface.");
  }
  const id = String(value.id || "").trim().toLowerCase();
  if (!SURFACE_ID_PATTERN.test(id)) throw new Error("Plugin surface id is invalid.");
  if (String(value.type || "") !== "declarative") {
    throw new Error("Marketplace plugin surface type must be 'declarative'.");
  }
  const upstreamUrl = normalizeServiceUrl(value.upstreamUrl, "Surface upstreamUrl");
  const entryPath = normalizeEntryPath(value.entryPath || "/api/codmes/surface");
  const navigation = Array.isArray(value.navigation)
    ? value.navigation.map((item) => normalizeSurfaceNavigationItem(item))
    : [];
  if (!navigation.length) {
    throw new Error("Declarative plugin surface must include navigation.");
  }
  if (new Set(navigation.map((item) => item.id)).size !== navigation.length) {
    throw new Error("Plugin surface navigation ids must be unique.");
  }
  const auth = value.auth == null ? null : normalizeSurfaceAuth(value.auth);
  return {
    id,
    type: "declarative",
    title: String(value.title || pluginName).trim() || pluginName,
    description: String(value.description || "").trim(),
    icon: String(value.icon || "square.grid.2x2").trim(),
    upstreamUrl,
    entryPath,
    navigation,
    auth,
    order: Number.isFinite(value.order) ? Number(value.order) : 1000,
    pluginId
  };
}

function normalizeSurfaceNavigationItem(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin surface navigation item must be an object.");
  }
  const id = String(value.id || "").trim().toLowerCase();
  if (!SURFACE_ID_PATTERN.test(id)) throw new Error("Plugin surface navigation id is invalid.");
  const title = String(value.title || "").trim();
  if (!title) throw new Error("Plugin surface navigation title is required.");
  return {
    id,
    title,
    icon: String(value.icon || "square.grid.2x2").trim(),
    path: normalizeEntryPath(value.path || `/api/codmes/surface/${id}`),
    requiresAuth: value.requiresAuth === true
  };
}

function normalizeSurfaceAuth(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin surface auth must be an object.");
  }
  if (String(value.type || "") !== "password") {
    throw new Error("Plugin surface auth type must be 'password'.");
  }
  const credentialId = String(value.credentialId || "").trim();
  if (!/^[a-zA-Z0-9_-]+$/.test(credentialId)) {
    throw new Error("Plugin surface auth credentialId is invalid.");
  }
  return {
    type: "password",
    credentialId,
    loginPath: normalizeEntryPath(value.loginPath),
    statusPath: normalizeEntryPath(value.statusPath),
    usernameField: String(value.usernameField || "username").trim(),
    passwordField: String(value.passwordField || "password").trim(),
    tokenField: String(value.tokenField || "access_token").trim()
  };
}

function normalizePluginMcp(value, pluginId, surfaceId) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin must include an MCP definition.");
  }
  const name = String(value.name || surfaceId).trim();
  if (!MCP_NAME_PATTERN.test(name)) throw new Error("Plugin MCP name is invalid.");
  if (String(value.transport || "") !== "streamable_http") {
    throw new Error("Plugin MCP transport must be 'streamable_http'.");
  }
  const url = normalizeServiceUrl(value.url, "MCP url", { allowPath: true });
  const surfaces = Array.isArray(value.surfaces)
    ? [...new Set(value.surfaces.map(String).map((item) => item.trim()).filter(Boolean))]
    : [surfaceId];
  if (!surfaces.includes(surfaceId)) {
    throw new Error("Plugin MCP must be enabled for its own surface.");
  }
  const credentialId = String(value.credentialId || value.credential_id || "").trim();
  const allowUnauthenticated = value.allowUnauthenticated === true;
  if (allowUnauthenticated && !isLoopbackUrl(url)) {
    throw new Error("Unauthenticated MCP is allowed only for a loopback URL.");
  }
  if (!allowUnauthenticated && !credentialId) {
    throw new Error("Plugin MCP requires credentialId unless it uses an unauthenticated loopback gateway.");
  }
  return {
    name,
    transport: "streamable_http",
    url,
    surfaces,
    credentialId: credentialId || null,
    allowUnauthenticated,
    requiresApproval: value.requiresApproval !== false,
    pluginId
  };
}

function normalizeServiceUrl(value, label) {
  let parsed;
  try {
    parsed = new URL(String(value || "").trim());
  } catch {
    throw new Error(`${label} must be an absolute URL.`);
  }
  const isAllowedHttp = parsed.protocol === "http:" && isLoopbackHostname(parsed.hostname);
  if (parsed.protocol !== "https:" && !isAllowedHttp) {
    throw new Error(`${label} must use HTTPS, except for loopback development services.`);
  }
  if (parsed.username || parsed.password || parsed.hash) {
    throw new Error(`${label} cannot contain credentials or a fragment.`);
  }
  return parsed.toString();
}

function normalizeEntryPath(value) {
  const entryPath = String(value || "/").trim();
  if (!entryPath.startsWith("/") || entryPath.startsWith("//")) {
    throw new Error("Surface entryPath must be an absolute path.");
  }
  return entryPath;
}

export async function listInstalledPlugins(workspaceRoot) {
  const directory = await ensurePluginsDirectory(workspaceRoot);
  let entries = [];
  try {
    entries = await fs.readdir(directory, { withFileTypes: true });
  } catch {
    return [];
  }
  const plugins = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
    try {
      const manifest = validatePluginManifest(
        JSON.parse(await fs.readFile(path.join(directory, entry.name, "plugin.json"), "utf8"))
      );
      plugins.push(manifest);
    } catch {}
  }
  return plugins.sort((a, b) => a.name.localeCompare(b.name));
}

export async function getInstalledPlugin(workspaceRoot, pluginId) {
  const id = normalizePluginId(pluginId);
  const file = path.join(pluginsDirectory(workspaceRoot), id, "plugin.json");
  try {
    return validatePluginManifest(JSON.parse(await fs.readFile(file, "utf8")));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export async function installPlugin(workspaceRoot, sourcePath) {
  const manifest = await readPluginManifestSource(sourcePath);
  await ensureRuntimeConfig(workspaceRoot);
  const directory = await ensurePluginsDirectory(workspaceRoot);
  const target = path.join(directory, manifest.id);
  const staging = path.join(directory, `.${manifest.id}.${crypto.randomBytes(6).toString("hex")}.installing`);
  const backup = path.join(directory, `.${manifest.id}.${crypto.randomBytes(6).toString("hex")}.backup`);
  const previousConfig = await readRuntimeConfig(workspaceRoot);
  const otherPlugins = (await listInstalledPlugins(workspaceRoot))
    .filter((plugin) => plugin.id !== manifest.id);
  if (["chat", "notes", "code"].includes(manifest.surface.id)
      || otherPlugins.some((plugin) => plugin.surface.id === manifest.surface.id)) {
    throw new Error(`Surface id '${manifest.surface.id}' is already in use.`);
  }
  const mcpConflict = (previousConfig.mcpServers || []).find(
    (server) => server.name === manifest.mcp.name && server.pluginId !== manifest.id
  );
  if (mcpConflict) {
    throw new Error(`MCP server name '${manifest.mcp.name}' is already in use.`);
  }
  let hadExisting = false;

  await fs.mkdir(staging, { recursive: true });
  await fs.writeFile(path.join(staging, "plugin.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
  try {
    try {
      await fs.rename(target, backup);
      hadExisting = true;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await fs.rename(staging, target);
    await writeRuntimeConfig(workspaceRoot, {
      ...previousConfig,
      mcpServers: upsertPluginMcp(previousConfig.mcpServers || [], manifest)
    });
    if (hadExisting) await fs.rm(backup, { recursive: true, force: true });
    return { installed: true, plugin: manifest };
  } catch (error) {
    await fs.rm(target, { recursive: true, force: true });
    if (hadExisting) await fs.rename(backup, target).catch(() => {});
    await writeRuntimeConfig(workspaceRoot, previousConfig).catch(() => {});
    throw error;
  } finally {
    await fs.rm(staging, { recursive: true, force: true });
  }
}

export async function removePlugin(workspaceRoot, pluginId) {
  const id = normalizePluginId(pluginId);
  const manifest = await getInstalledPlugin(workspaceRoot, id);
  if (!manifest) return { removed: false, pluginId: id };

  const directory = await ensurePluginsDirectory(workspaceRoot);
  const target = path.join(directory, id);
  const staging = path.join(directory, `.${id}.${crypto.randomBytes(6).toString("hex")}.removing`);
  const previousConfig = await readRuntimeConfig(workspaceRoot);
  await fs.rename(target, staging);
  try {
    await writeRuntimeConfig(workspaceRoot, {
      ...previousConfig,
      mcpServers: (previousConfig.mcpServers || []).filter((server) => server.pluginId !== id)
    });
    await fs.rm(staging, { recursive: true, force: true });
    return { removed: true, pluginId: id };
  } catch (error) {
    await fs.rename(staging, target).catch(() => {});
    await writeRuntimeConfig(workspaceRoot, previousConfig).catch(() => {});
    throw error;
  }
}

function upsertPluginMcp(servers, manifest) {
  const mcp = {
    name: manifest.mcp.name,
    transport: manifest.mcp.transport,
    url: manifest.mcp.url,
    credential_id: manifest.mcp.credentialId || undefined,
    surfaces: manifest.mcp.surfaces,
    allowUnauthenticated: manifest.mcp.allowUnauthenticated,
    requiresApproval: manifest.mcp.requiresApproval,
    pluginId: manifest.id,
    enabled: true
  };
  return [...servers.filter((server) => server.pluginId !== manifest.id && server.name !== mcp.name), mcp];
}

export async function resolvePluginSurfaceTarget(workspaceRoot, pluginId, relativePath, search = "") {
  const manifest = await getInstalledPlugin(workspaceRoot, pluginId);
  if (!manifest) throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  const upstream = new URL(manifest.surface.upstreamUrl);
  const cleaned = String(relativePath || "").replace(/^\/+/, "");
  if (cleaned) {
    upstream.pathname = `/${cleaned}`;
    upstream.search = search || "";
  } else {
    const entry = new URL(manifest.surface.entryPath, upstream);
    upstream.pathname = entry.pathname;
    upstream.search = search || entry.search;
  }
  return { manifest, url: upstream };
}

export async function resolvePluginSurfaceDocumentTarget(workspaceRoot, pluginId, routeId) {
  const manifest = await getInstalledPlugin(workspaceRoot, pluginId);
  if (!manifest) throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  const route = String(routeId || manifest.surface.navigation[0]?.id || "").trim().toLowerCase();
  const navigation = manifest.surface.navigation.find((item) => item.id === route);
  if (!navigation) {
    throw Object.assign(new Error("Plugin surface route was not found."), { status: 404 });
  }
  const url = new URL(navigation.path, manifest.surface.upstreamUrl);
  return { manifest, navigation, url };
}

function normalizePluginId(value) {
  const id = String(value || "").trim().toLowerCase();
  if (!PLUGIN_ID_PATTERN.test(id)) throw new Error("Plugin id is invalid.");
  return id;
}

function isLoopbackUrl(value) {
  try {
    return isLoopbackHostname(new URL(value).hostname);
  } catch {
    return false;
  }
}

function isLoopbackHostname(hostname) {
  const normalized = String(hostname || "").toLowerCase().replace(/^\[|\]$/g, "");
  return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1";
}
