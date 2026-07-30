import fs from "node:fs/promises";
import path from "node:path";

import {
  ensureBuiltInPluginState,
  listBuiltInPlugins
} from "./builtin-plugin-registry.mjs";
import {
  listInstalledPlugins
} from "./plugin-registry.mjs";

export async function ensurePluginRuntime(workspaceRoot) {
  void workspaceRoot;
  return await ensureBuiltInPluginState();
}

export async function listRuntimePlugins(workspaceRoot) {
  const [builtIn, installed, settings] = await Promise.all([
    listBuiltInPlugins(),
    listInstalledPlugins(workspaceRoot),
    readPluginSettings(workspaceRoot)
  ]);
  const builtInIds = new Set(builtIn.map((plugin) => plugin.id));
  const community = installed
    .filter((plugin) => !builtInIds.has(plugin.id))
    .map(createCommunityRuntimePlugin);
  return [...builtIn, ...community]
    .map((plugin) => applyPluginSettings(plugin, settings[plugin.id]))
    .sort((left, right) => {
      const a = Math.min(...left.views.map((view) => view.order ?? 1000));
      const b = Math.min(...right.views.map((view) => view.order ?? 1000));
      return a - b || left.name.localeCompare(right.name);
    });
}

export async function listPublicRuntimePlugins(workspaceRoot) {
  return (await listRuntimePlugins(workspaceRoot)).map((plugin) => {
    const { contribution: _contribution, storage: _storage, tools, ...summary } = plugin;
    return {
      ...summary,
      views: plugin.views.map((view) => ({
        ...view,
        kind: plugin.distribution === "builtin" ? "builtin" : "plugin",
        pluginId: plugin.id,
        pluginName: plugin.name,
        distribution: plugin.distribution,
        enabled: plugin.enabled,
        removable: plugin.removable
      })),
      toolNames: tools.map((tool) => tool.name)
    };
  });
}

export async function getRuntimePlugin(workspaceRoot, id) {
  const normalized = String(id || "").trim().toLowerCase();
  return (await listRuntimePlugins(workspaceRoot)).find(
    (plugin) => plugin.id === normalized
      || plugin.views.some((view) => view.id === normalized)
  ) || null;
}

export async function listRuntimeViews(workspaceRoot) {
  return (await listRuntimePlugins(workspaceRoot)).flatMap((plugin) =>
    plugin.views.map((view) => ({
      ...view,
      kind: plugin.distribution === "builtin" ? "builtin" : "plugin",
      pluginId: plugin.id,
      pluginName: plugin.name,
      distribution: plugin.distribution,
      enabled: plugin.enabled,
      removable: plugin.removable
    }))
  );
}

export async function listRuntimeToolProviders(workspaceRoot) {
  const plugins = await listRuntimePlugins(workspaceRoot);
  return plugins
    .filter((plugin) => plugin.enabled !== false && plugin.tools.length > 0)
    .map((plugin) => plugin);
}

export async function getRuntimeContribution(workspaceRoot, id) {
  const plugin = await getRuntimePlugin(workspaceRoot, id);
  if (!plugin) return null;
  return plugin.contribution || null;
}

export async function savePluginConfiguration(workspaceRoot, id, config = {}) {
  const plugin = await getRuntimePlugin(workspaceRoot, id);
  if (!plugin) {
    throw Object.assign(new Error("Plugin was not found."), { status: 404 });
  }
  if (config.remove === true) {
    throw Object.assign(
      new Error(
        plugin.builtIn
          ? "Built-in plugins cannot be removed."
          : "Community plugins are removed from Marketplace settings."
      ),
      { status: 409, code: plugin.builtIn ? "builtin_plugin_cannot_be_removed" : "use_marketplace_remove" }
    );
  }
  const settings = await readPluginSettings(workspaceRoot);
  settings[plugin.id] = {
    ...(settings[plugin.id] || {}),
    ...(typeof config.enabled === "boolean" ? { enabled: config.enabled } : {})
  };
  await writePluginSettings(workspaceRoot, settings);
  return await getRuntimePlugin(workspaceRoot, plugin.id);
}

function createCommunityRuntimePlugin(plugin) {
  return {
    schemaVersion: 1,
    id: plugin.id,
    version: plugin.version,
    name: plugin.name,
    description: plugin.description,
    publisher: plugin.publisher,
    icon: plugin.surface.icon,
    platforms: plugin.platforms,
    permissions: plugin.permissions,
    distribution: "community",
    builtIn: false,
    removable: true,
    views: [{
      id: plugin.surface.id,
      title: plugin.surface.title,
      description: plugin.surface.description || plugin.description,
      icon: plugin.surface.icon,
      renderer: plugin.surface.type,
      order: plugin.surface.order,
      navigation: plugin.surface.navigation,
      dataPath: `/api/plugins/${encodeURIComponent(plugin.id)}/view-document`,
      hasAuthentication: Boolean(plugin.surface.auth)
    }],
    tools: plugin.tools || [],
    storage: plugin.storage || null,
    contribution: plugin
  };
}

function applyPluginSettings(plugin, setting = null) {
  return {
    ...plugin,
    enabled: setting?.enabled !== false
  };
}

function settingsPath(workspaceRoot) {
  return path.join(workspaceRoot, ".codmes", "plugin-runtime", "settings.json");
}

async function readPluginSettings(workspaceRoot) {
  try {
    return JSON.parse(await fs.readFile(settingsPath(workspaceRoot), "utf8"));
  } catch {
    return {};
  }
}

async function writePluginSettings(workspaceRoot, settings) {
  const target = settingsPath(workspaceRoot);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, JSON.stringify(settings, null, 2) + "\n", "utf8");
}
