import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import {
  ensureRuntimeConfig,
  readRuntimeConfig,
  writeRuntimeConfig
} from "./config-store.mjs";
import { normalizePluginToolDocument } from "./tool-registry.mjs";
import { normalizePluginStorage } from "./plugin-collection-store.mjs";
import {
  normalizePluginMigrations,
  preparePluginDataMigration
} from "./plugin-data-migration.mjs";
import {
  isBuiltInPluginId,
  pluginDistribution
} from "./plugin-distribution.mjs";
import { normalizeClientCompatibility } from "./plugin-compatibility.mjs";

const PLUGIN_SCHEMA_VERSION = 1;
const PLUGIN_ID_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)+$/;
const SURFACE_ID_PATTERN = /^[a-z0-9][a-z0-9_-]*$/;
const EDITOR_FIELD_ID_PATTERN = /^[A-Za-z_][A-Za-z0-9_-]{0,63}$/;
const MCP_NAME_PATTERN = /^[a-zA-Z0-9_-]+$/;

export function pluginsDirectory(workspaceRoot) {
  const sharedRoot = String(process.env.CODMES_SHARED_PLUGIN_ROOT || "").trim();
  return sharedRoot
    ? path.join(path.resolve(sharedRoot), "plugins")
    : path.join(workspaceRoot, ".codmes", "plugins");
}

// Existing profile installations remain on disk as recoverable backups. Only the
// highest installed version is activated, and collection data stays per profile.
export async function adoptWorkspacePluginPackages(workspaceRoots) {
  if (!process.env.CODMES_SHARED_PLUGIN_ROOT) return { adopted: [] };
  const marker = path.join(path.resolve(process.env.CODMES_SHARED_PLUGIN_ROOT), ".legacy-plugin-adoption-complete");
  if (await fs.stat(marker).catch((error) => {
    if (error?.code === "ENOENT") return null;
    throw error;
  })) return { adopted: [] };
  const candidates = new Map();
  for (const workspaceRoot of [...new Set(workspaceRoots || [])]) {
    const localDirectory = path.join(workspaceRoot, ".codmes", "plugins");
    const entries = await fs.readdir(localDirectory, { withFileTypes: true }).catch((error) => {
      if (error?.code === "ENOENT") return [];
      throw error;
    });
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      const source = path.join(localDirectory, entry.name);
      const state = await readPluginInstallStateFile(source);
      const manifestPath = state?.currentVersion
        ? path.join(source, "versions", state.currentVersion, "plugin.json")
        : path.join(source, "plugin.json");
      const manifest = validatePluginManifest(JSON.parse(await fs.readFile(manifestPath, "utf8")));
      if (manifest.id !== entry.name) throw new Error(`Legacy plugin directory '${entry.name}' has a different manifest id.`);
      const group = candidates.get(manifest.id) || [];
      group.push({ workspaceRoot, source, manifest, state });
      candidates.set(manifest.id, group);
    }
  }
  const adopted = [];
  const directory = await ensurePluginsDirectory(workspaceRoots?.[0] || process.cwd());
  for (const [pluginId, group] of candidates) {
    const target = path.join(directory, pluginId);
    if (await fs.stat(target).catch((error) => {
      if (error?.code === "ENOENT") return null;
      throw error;
    })) continue;
    const publishers = new Set(group.map((item) => item.state?.source?.publisherId).filter(Boolean));
    const permissionSets = new Set(group.map((item) => [...item.manifest.permissions].sort().join("\n")));
    if (publishers.size > 1 || permissionSets.size > 1) {
      throw new Error(`Legacy plugin '${pluginId}' differs across profiles in publisher or permissions; resolve those installations before sharing it.`);
    }
    const chosen = group.reduce((best, item) => comparePluginVersions(item.manifest.version, best.manifest.version) > 0 ? item : best);
    const migrations = await Promise.all(group.map((item) => preparePluginDataMigration(
      item.workspaceRoot,
      item.manifest,
      chosen.manifest,
      item.state?.dataVersion || item.manifest.dataVersion
    )));
    const applied = [];
    try {
      for (const migration of migrations) {
        await migration.apply();
        applied.push(migration);
      }
      await fs.cp(chosen.source, target, { recursive: true, errorOnExist: true, force: false });
      adopted.push({ pluginId, version: chosen.manifest.version, profiles: group.length });
    } catch (error) {
      for (const migration of applied.reverse()) await migration.rollback().catch(() => {});
      await fs.rm(target, { recursive: true, force: true });
      throw error;
    }
  }
  await fs.mkdir(path.dirname(marker), { recursive: true });
  await fs.writeFile(marker, JSON.stringify({ completedAt: new Date().toISOString(), adopted }) + "\n", { flag: "wx" });
  return { adopted };
}

function comparePluginVersions(left, right) {
  const numeric = (value) => String(value).split(/[+-]/, 1)[0].split(".").map(Number);
  const a = numeric(left);
  const b = numeric(right);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return String(left).localeCompare(String(right));
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
  if (typeof parsed?.surface?.ui === "string") {
    const packageDirectory = path.dirname(manifestPath);
    const uiPath = path.resolve(packageDirectory, parsed.surface.ui);
    const relative = path.relative(packageDirectory, uiPath);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error("Plugin surface UI file must stay inside the plugin package.");
    }
    parsed.surface.ui = JSON.parse(await fs.readFile(uiPath, "utf8"));
  }
  if (typeof parsed?.tools === "string") {
    const packageDirectory = path.dirname(manifestPath);
    const toolsPath = path.resolve(packageDirectory, parsed.tools);
    const relative = path.relative(packageDirectory, toolsPath);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error("Plugin tools file must stay inside the plugin package.");
    }
    parsed.tools = JSON.parse(await fs.readFile(toolsPath, "utf8"));
  }
  if (typeof parsed?.storage === "string") {
    const packageDirectory = path.dirname(manifestPath);
    const storagePath = path.resolve(packageDirectory, parsed.storage);
    const relative = path.relative(packageDirectory, storagePath);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) throw new Error("Plugin storage file must stay inside the plugin package.");
    parsed.storage = JSON.parse(await fs.readFile(storagePath, "utf8"));
  }
  if (typeof parsed?.migrations === "string") {
    const packageDirectory = path.dirname(manifestPath);
    const migrationsPath = path.resolve(packageDirectory, parsed.migrations);
    const relative = path.relative(packageDirectory, migrationsPath);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error("Plugin migrations file must stay inside the plugin package.");
    }
    parsed.migrations = JSON.parse(await fs.readFile(migrationsPath, "utf8"));
  }
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

  const permissions = Array.isArray(value.permissions)
    ? [...new Set(value.permissions.map(String).map((item) => item.trim()).filter(Boolean))]
    : [];
  const storage = normalizePluginStorage(value.storage);
  const dataVersion = value.dataVersion == null ? 1 : Number(value.dataVersion);
  if (!Number.isInteger(dataVersion) || dataVersion < 1 || dataVersion > 10_000) {
    throw new Error("Plugin dataVersion must be a positive integer.");
  }
  const migrations = normalizePluginMigrations(value.migrations);
  if (migrations.some((migration) => migration.to > dataVersion)) {
    throw new Error("Plugin migration cannot exceed manifest dataVersion.");
  }
  const storageCollections = storage?.collections?.map((item) => item.id) || [];
  const surface = normalizeDeclarativeSurface(value.surface, id, name, storageCollections);
  const mcp = value.mcp == null ? null : normalizePluginMcp(value.mcp, id, surface.id);
  const tools = normalizePluginToolDocument(value.tools, {
    pluginId: id,
    surfaceId: surface.id,
    mcpName: mcp?.name || null,
    storageCollections
  });
  if (!mcp && !storage) throw new Error("Plugin must include MCP or Workspace storage.");
  const compatibility = normalizeClientCompatibility({
    platforms: value.platforms,
    formFactors: value.formFactors,
    subject: "Plugin"
  });

  return {
    schemaVersion: PLUGIN_SCHEMA_VERSION,
    id,
    version,
    name,
    description: String(value.description || "").trim(),
    publisher: String(value.publisher || "").trim(),
    platforms: compatibility.platforms,
    formFactors: compatibility.formFactors,
    permissions,
    surface,
    mcp,
    storage,
    tools,
    dataVersion,
    migrations,
    distribution: pluginDistribution(id),
    removable: !isBuiltInPluginId(id)
  };
}

function normalizeDeclarativeSurface(value, pluginId, pluginName, storageCollections) {
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
  const ui = value.ui == null ? null : normalizeSurfaceUiDefinition(value.ui, storageCollections);
  const navigation = ui
    ? ui.routes.map((route) => ({
        id: route.id,
        title: route.title,
        icon: route.icon,
        path: route.dataSources[0]?.path || entryPath,
        requiresAuth: route.requiresAuth
      }))
    : Array.isArray(value.navigation)
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
    ui,
    auth,
    order: Number.isFinite(value.order) ? Number(value.order) : 1000,
    pluginId
  };
}

function normalizeSurfaceUiDefinition(value, storageCollections = []) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin surface UI definition must be an object.");
  }
  const schemaVersion = Number(value.schemaVersion);
  if (![1, 2].includes(schemaVersion)) {
    throw new Error("Plugin surface UI schemaVersion must be 1 or 2.");
  }
  if (!Array.isArray(value.routes) || !value.routes.length || value.routes.length > 32) {
    throw new Error("Plugin surface UI must contain between 1 and 32 routes.");
  }
  const collections = new Set(storageCollections);
  const routes = value.routes.map(
    (route) => normalizeSurfaceUiRoute(route, schemaVersion, collections)
  );
  if (new Set(routes.map((route) => route.id)).size !== routes.length) {
    throw new Error("Plugin surface UI route ids must be unique.");
  }
  return { schemaVersion, routes };
}

function normalizeSurfaceUiRoute(value, surfaceSchemaVersion, storageCollections) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Plugin surface UI route must be an object.");
  }
  const id = String(value.id || "").trim().toLowerCase();
  if (!SURFACE_ID_PATTERN.test(id)) throw new Error("Plugin surface UI route id is invalid.");
  const title = String(value.title || "").trim();
  if (!title) throw new Error("Plugin surface UI route title is required.");
  if (!Array.isArray(value.dataSources) || !value.dataSources.length || value.dataSources.length > 8) {
    throw new Error("Plugin surface UI route must contain between 1 and 8 data sources.");
  }
  const dataSources = value.dataSources.map((source) => {
    const sourceId = String(source?.id || "").trim();
    if (!SURFACE_ID_PATTERN.test(sourceId)) throw new Error("Plugin data source id is invalid.");
    const sourcePath = String(source.path || "").trim();
    const collectionMatch = /^collection:([a-z][a-z0-9_-]{0,63})$/.exec(sourcePath);
    if (surfaceSchemaVersion === 2
        && collectionMatch
        && !storageCollections.has(collectionMatch[1])) {
      throw new Error(`Surface v2 data source collection '${collectionMatch[1]}' is not declared.`);
    }
    return {
      id: sourceId,
      path: collectionMatch
        ? sourcePath
        : normalizeEntryPath(sourcePath)
    };
  });
  if (new Set(dataSources.map((source) => source.id)).size !== dataSources.length) {
    throw new Error("Plugin data source ids must be unique within a route.");
  }
  const document = value.document;
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("Plugin surface UI route must include a document binding.");
  }
  if (Number(document.schemaVersion) !== surfaceSchemaVersion
      || !["collection", "dashboard", "calendar"].includes(String(document.presentation || ""))) {
    throw new Error("Unsupported plugin surface UI document binding.");
  }
  if (!String(document.title || "").trim()) {
    throw new Error("Plugin surface UI document title is required.");
  }
  const normalizedDocument = JSON.parse(JSON.stringify(document));
  if (normalizedDocument.collectionStyle != null) {
    if (normalizedDocument.presentation !== "collection"
        || !["list", "cards"].includes(String(normalizedDocument.collectionStyle))) {
      throw new Error("Plugin collectionStyle must be 'list' or 'cards' on a collection document.");
    }
  }
  if (surfaceSchemaVersion === 2 && normalizedDocument.editor != null) {
    normalizedDocument.editor = normalizeSurfaceEditor(
      normalizedDocument.editor,
      storageCollections
    );
  }
  const serialized = JSON.stringify(normalizedDocument);
  if (Buffer.byteLength(serialized, "utf8") > 256 * 1024) {
    throw new Error("Plugin surface UI document binding is too large.");
  }
  return {
    id,
    title,
    icon: String(value.icon || "square.grid.2x2").trim(),
    requiresAuth: value.requiresAuth === true,
    dataSources,
    document: JSON.parse(serialized)
  };
}

function normalizeSurfaceEditor(value, storageCollections) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Surface v2 editor must be an object.");
  }
  const collection = String(value.collection || "").trim();
  if (!storageCollections.has(collection)) {
    throw new Error(`Surface v2 editor collection '${collection}' is not declared.`);
  }
  if (!Array.isArray(value.fields) || !value.fields.length || value.fields.length > 32) {
    throw new Error("Surface v2 editor must declare between 1 and 32 fields.");
  }
  const supportedTypes = new Set(["text", "multiline", "boolean", "date", "dateTime", "number"]);
  const fields = value.fields.map((field) => {
    const id = String(field?.id || "").trim();
    const label = String(field?.label || "").trim();
    const type = String(field?.type || "").trim();
    if (!EDITOR_FIELD_ID_PATTERN.test(id) || !label || !supportedTypes.has(type)) {
      throw new Error("Surface v2 editor field is invalid.");
    }
    return {
      id,
      label,
      type,
      required: field.required === true,
      placeholder: String(field.placeholder || "").trim() || null,
      role: String(field.role || "").trim() || null
    };
  });
  if (new Set(fields.map((field) => field.id)).size !== fields.length) {
    throw new Error("Surface v2 editor field ids must be unique.");
  }
  return { collection, fields };
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
    ...(value.logoutPath
      ? { logoutPath: normalizeEntryPath(value.logoutPath) }
      : {}),
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
      const manifest = await getInstalledPlugin(workspaceRoot, entry.name);
      if (!manifest) continue;
      plugins.push(manifest);
    } catch {}
  }
  return plugins.sort((a, b) => a.name.localeCompare(b.name));
}

export async function synchronizeSharedPluginProfile(workspaceRoot) {
  if (!process.env.CODMES_SHARED_PLUGIN_ROOT) return;
  const plugins = await listInstalledPlugins(workspaceRoot);
  const config = await readRuntimeConfig(workspaceRoot);
  const settings = await fs.readFile(
    path.join(workspaceRoot, ".codmes", "plugin-runtime", "settings.json"), "utf8"
  ).then(JSON.parse).catch(() => ({}));
  const installedIds = new Set(plugins.map((plugin) => plugin.id));
  let next = (config.mcpServers || []).filter((server) => !server.pluginId || installedIds.has(server.pluginId));
  for (const plugin of plugins) {
    if (plugin.mcp && next.some((server) => server.name === plugin.mcp.name && server.pluginId !== plugin.id)) {
      console.warn(`[codmes] plugin '${plugin.id}' MCP name conflicts in profile workspace ${workspaceRoot}`);
      continue;
    }
    next = upsertPluginMcp(next, plugin);
    if (settings[plugin.id]?.enabled === false) {
      next = next.map((server) => server.pluginId === plugin.id ? { ...server, enabled: false } : server);
    }
  }
  if (JSON.stringify(next) !== JSON.stringify(config.mcpServers || [])) {
    await writeRuntimeConfig(workspaceRoot, { ...config, mcpServers: next });
  }
}

export async function getInstalledPlugin(workspaceRoot, pluginId) {
  const id = normalizePluginId(pluginId);
  const root = path.join(pluginsDirectory(workspaceRoot), id);
  try {
    const state = await readPluginInstallStateFile(root);
    const file = state?.currentVersion
      ? path.join(root, "versions", state.currentVersion, "plugin.json")
      : path.join(root, "plugin.json");
    return validatePluginManifest(JSON.parse(await fs.readFile(file, "utf8")));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export async function getPluginInstallState(workspaceRoot, pluginId) {
  const id = normalizePluginId(pluginId);
  const root = path.join(pluginsDirectory(workspaceRoot), id);
  const manifest = await getInstalledPlugin(workspaceRoot, id);
  if (!manifest) return null;
  const state = await readPluginInstallStateFile(root);
  return state || {
    schemaVersion: 1,
    currentVersion: manifest.version,
    previousVersion: null,
    installedAt: null,
    source: { type: "legacy" }
  };
}

export async function getPluginVersionManifest(workspaceRoot, pluginId, version) {
  const id = normalizePluginId(pluginId);
  const targetVersion = String(version || "").trim();
  if (!targetVersion) return null;
  try {
    return validatePluginManifest(JSON.parse(await fs.readFile(
      path.join(pluginsDirectory(workspaceRoot), id, "versions", targetVersion, "plugin.json"),
      "utf8"
    )));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export async function installPlugin(workspaceRoot, sourcePath, options = {}) {
  const manifest = await readPluginManifestSource(sourcePath);
  if (isBuiltInPluginId(manifest.id) && options.source?.type !== "builtin") {
    throw Object.assign(
      new Error("Built-in plugins are installed and updated with Codmes."),
      { status: 409, code: "builtin_plugin_managed_by_codmes" }
    );
  }
  await ensureRuntimeConfig(workspaceRoot);
  const directory = await ensurePluginsDirectory(workspaceRoot);
  const target = path.join(directory, manifest.id);
  const versions = path.join(target, "versions");
  const versionTarget = path.join(versions, manifest.version);
  const staging = path.join(versions, `.${manifest.version}.${crypto.randomBytes(6).toString("hex")}.installing`);
  const versionBackup = path.join(versions, `.${manifest.version}.${crypto.randomBytes(6).toString("hex")}.backup`);
  const previousConfig = await readRuntimeConfig(workspaceRoot);
  const previousManifest = await getInstalledPlugin(workspaceRoot, manifest.id);
  const previousState = await readPluginInstallStateFile(target);
  const previousDataVersion = Number(
    previousState?.dataVersion || previousManifest?.dataVersion || 1
  );
  const migrationRoots = [...new Set([workspaceRoot, ...(options.workspaceRoots || [])])];
  const dataMigrations = await Promise.all(migrationRoots.map((root) => preparePluginDataMigration(
    root, previousManifest, manifest, previousDataVersion
  )));
  const dataMigration = dataMigrations[0];
  const otherPlugins = (await listInstalledPlugins(workspaceRoot))
    .filter((plugin) => plugin.id !== manifest.id);
  if (["chat", "notes", "code", "planner"].includes(manifest.surface.id)
      || otherPlugins.some((plugin) => plugin.surface.id === manifest.surface.id)) {
    throw new Error(`Surface id '${manifest.surface.id}' is already in use.`);
  }
  const mcpConflict = manifest.mcp && (previousConfig.mcpServers || []).find(
    (server) => server.name === manifest.mcp.name && server.pluginId !== manifest.id
  );
  if (mcpConflict) {
    throw new Error(`MCP server name '${manifest.mcp.name}' is already in use.`);
  }
  if (manifest.mcp) {
    for (const root of migrationRoots.filter((root) => root !== workspaceRoot)) {
      const config = await readRuntimeConfig(root);
      if (config.mcpServers.some((server) => server.name === manifest.mcp.name && server.pluginId !== manifest.id)) {
        throw new Error(`MCP server name '${manifest.mcp.name}' is already in use in another profile.`);
      }
    }
  }
  await fs.mkdir(versions, { recursive: true });
  if (previousManifest && !previousState) {
    const legacyVersion = path.join(versions, previousManifest.version);
    await fs.mkdir(legacyVersion, { recursive: true });
    await fs.writeFile(
      path.join(legacyVersion, "plugin.json"),
      JSON.stringify(previousManifest, null, 2) + "\n",
      "utf8"
    );
  }
  await fs.mkdir(staging, { recursive: true });
  await fs.writeFile(path.join(staging, "plugin.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
  if (options.packageSha256) {
    await fs.writeFile(
      path.join(staging, "package.json"),
      JSON.stringify({
        sha256: String(options.packageSha256),
        source: options.source || null
      }, null, 2) + "\n",
      "utf8"
    );
  }
  let replacedVersion = false;
  const appliedMigrations = [];
  try {
    try {
      await fs.rename(versionTarget, versionBackup);
      replacedVersion = true;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await fs.rename(staging, versionTarget);
    for (const migration of dataMigrations) {
      await migration.apply();
      appliedMigrations.push(migration);
    }
    const nextState = {
      schemaVersion: 1,
      currentVersion: manifest.version,
      previousVersion: previousManifest && previousManifest.version !== manifest.version
        ? previousManifest.version
        : previousState?.previousVersion || null,
      installedAt: previousState?.installedAt || new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      dataVersion: manifest.dataVersion,
      acceptedPermissions: Array.isArray(options.acceptedPermissions)
        ? [...new Set(options.acceptedPermissions.map(String))]
        : previousState?.acceptedPermissions || manifest.permissions,
      migration: dataMigration.steps.length ? {
        from: dataMigration.from,
        to: dataMigration.to,
        steps: dataMigration.steps,
        appliedAt: new Date().toISOString()
      } : previousState?.migration || null,
      source: options.source || previousState?.source || { type: "local", path: path.resolve(sourcePath) }
    };
    await writePluginInstallStateFile(target, nextState);
    await writeRuntimeConfig(workspaceRoot, {
      ...previousConfig,
      mcpServers: upsertPluginMcp(previousConfig.mcpServers || [], manifest)
    });
    await fs.rm(path.join(target, "plugin.json"), { force: true });
    if (replacedVersion) await fs.rm(versionBackup, { recursive: true, force: true });
    return {
      installed: true,
      updated: Boolean(previousManifest),
      plugin: manifest,
      state: nextState
    };
  } catch (error) {
    for (const migration of appliedMigrations.reverse()) await migration.rollback().catch(() => {});
    await fs.rm(versionTarget, { recursive: true, force: true });
    if (replacedVersion) await fs.rename(versionBackup, versionTarget).catch(() => {});
    if (previousState) {
      await writePluginInstallStateFile(target, previousState).catch(() => {});
    } else {
      await fs.rm(path.join(target, "state.json"), { force: true }).catch(() => {});
    }
    await writeRuntimeConfig(workspaceRoot, previousConfig).catch(() => {});
    if (!previousManifest) {
      await fs.rm(target, { recursive: true, force: true }).catch(() => {});
    }
    throw error;
  } finally {
    await fs.rm(staging, { recursive: true, force: true });
  }
}

export async function rollbackPlugin(workspaceRoot, pluginId, targetVersion = null) {
  const id = normalizePluginId(pluginId);
  if (isBuiltInPluginId(id)) {
    throw Object.assign(
      new Error("Built-in plugins are updated with Codmes and cannot be rolled back separately."),
      { status: 409, code: "builtin_plugin_managed_by_codmes" }
    );
  }
  const root = path.join(pluginsDirectory(workspaceRoot), id);
  const current = await getInstalledPlugin(workspaceRoot, id);
  const state = await getPluginInstallState(workspaceRoot, id);
  if (!current || !state) {
    throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  }
  const version = String(targetVersion || state.previousVersion || "").trim();
  if (!version || version === state.currentVersion) {
    throw Object.assign(new Error("Plugin does not have a previous version to restore."), { status: 409 });
  }
  let manifest;
  try {
    manifest = validatePluginManifest(JSON.parse(await fs.readFile(
      path.join(root, "versions", version, "plugin.json"),
      "utf8"
    )));
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw Object.assign(new Error(`Plugin version '${version}' is not installed.`), { status: 404 });
    }
    throw error;
  }
  if (Number(manifest.dataVersion || 1) !== Number(state.dataVersion || current.dataVersion || 1)) {
    throw Object.assign(
      new Error("Rollback is unavailable because this version uses a different data schema."),
      { status: 409, code: "plugin_rollback_data_version" }
    );
  }
  const previousConfig = await readRuntimeConfig(workspaceRoot);
  const nextState = {
    ...state,
    currentVersion: version,
    previousVersion: state.currentVersion,
    updatedAt: new Date().toISOString()
  };
  await writePluginInstallStateFile(root, nextState);
  try {
    await writeRuntimeConfig(workspaceRoot, {
      ...previousConfig,
      mcpServers: upsertPluginMcp(previousConfig.mcpServers || [], manifest)
    });
    return { rolledBack: true, plugin: manifest, state: nextState };
  } catch (error) {
    await writePluginInstallStateFile(root, state).catch(() => {});
    await writeRuntimeConfig(workspaceRoot, previousConfig).catch(() => {});
    throw error;
  }
}

export async function removePlugin(workspaceRoot, pluginId, options = {}) {
  const id = normalizePluginId(pluginId);
  if (isBuiltInPluginId(id)) {
    throw Object.assign(
      new Error("Built-in plugins cannot be removed."),
      { status: 409, code: "builtin_plugin_cannot_be_removed" }
    );
  }
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
    const { removePluginMcpToolConsent } = await import("./mcp-tool-consent.mjs");
    for (const root of new Set([workspaceRoot, ...(options.workspaceRoots || [])])) {
      await removePluginMcpToolConsent(root, id);
    }
    await fs.rm(staging, { recursive: true, force: true });
    return { removed: true, pluginId: id };
  } catch (error) {
    await fs.rename(staging, target).catch(() => {});
    await writeRuntimeConfig(workspaceRoot, previousConfig).catch(() => {});
    throw error;
  }
}

function upsertPluginMcp(servers, manifest) {
  if (!manifest.mcp) return servers.filter((server) => server.pluginId !== manifest.id);
  const existing = servers.find((server) => server.pluginId === manifest.id);
  const mcp = {
    name: manifest.mcp.name,
    transport: manifest.mcp.transport,
    url: manifest.mcp.url,
    credential_id: manifest.mcp.credentialId || undefined,
    surfaces: manifest.mcp.surfaces,
    allowUnauthenticated: manifest.mcp.allowUnauthenticated,
    requiresApproval: manifest.mcp.requiresApproval,
    pluginId: manifest.id,
    enabled: existing?.enabled !== false
  };
  return [...servers.filter((server) => server.pluginId !== manifest.id && server.name !== mcp.name), mcp];
}

async function readPluginInstallStateFile(pluginRoot) {
  try {
    const value = JSON.parse(await fs.readFile(path.join(pluginRoot, "state.json"), "utf8"));
    if (Number(value?.schemaVersion) !== 1 || !String(value.currentVersion || "").trim()) {
      throw new Error("Installed plugin state is invalid.");
    }
    return value;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function writePluginInstallStateFile(pluginRoot, value) {
  await fs.mkdir(pluginRoot, { recursive: true });
  const temporary = path.join(
    pluginRoot,
    `.state.${crypto.randomBytes(6).toString("hex")}.tmp`
  );
  await fs.writeFile(temporary, JSON.stringify(value, null, 2) + "\n", "utf8");
  await fs.rename(temporary, path.join(pluginRoot, "state.json"));
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

export async function resolvePluginViewDocumentTarget(workspaceRoot, pluginId, routeId) {
  const manifest = await getInstalledPlugin(workspaceRoot, pluginId);
  if (!manifest) throw Object.assign(new Error("Plugin is not installed."), { status: 404 });
  return resolveViewDocumentTarget(manifest, routeId);
}

export function resolveViewDocumentTarget(manifest, routeId) {
  const route = String(routeId || manifest.surface.navigation[0]?.id || "").trim().toLowerCase();
  const navigation = manifest.surface.navigation.find((item) => item.id === route);
  if (!navigation) {
    throw Object.assign(new Error("Plugin surface route was not found."), { status: 404 });
  }
  const uiRoute = manifest.surface.ui?.routes?.find((item) => item.id === route) || null;
  const url = String(navigation.path || "").startsWith("collection:")
    ? new URL(manifest.surface.entryPath, manifest.surface.upstreamUrl)
    : new URL(navigation.path, manifest.surface.upstreamUrl);
  return { manifest, navigation, uiRoute, url };
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
