import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { readPluginManifestSource } from "./plugin-registry.mjs";
import { normalizeClientCompatibility } from "./plugin-compatibility.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const BUNDLED_ROOT = path.join(REPO_ROOT, "bundled", "plugins");
const BUNDLED_PLUGIN_NAMES = Object.freeze(["chat", "notes", "code", "planner"]);
let bundledPluginsPromise = null;

export function listBuiltInPluginIds() {
  return BUNDLED_PLUGIN_NAMES.map((name) => `com.codmes.${name}`);
}

export async function listBuiltInPlugins() {
  bundledPluginsPromise ||= Promise.all(BUNDLED_PLUGIN_NAMES.map(loadBuiltInPlugin));
  return await bundledPluginsPromise;
}

export async function getBuiltInPlugin(id) {
  const normalized = String(id || "").trim().toLowerCase();
  return (await listBuiltInPlugins()).find(
    (plugin) => plugin.id === normalized
      || plugin.views.some((view) => view.id === normalized)
  ) || null;
}

export async function ensureBuiltInPluginState() {
  await listBuiltInPlugins();
  return {
    builtInPluginIds: listBuiltInPluginIds()
  };
}

async function loadBuiltInPlugin(name) {
  const directory = path.join(BUNDLED_ROOT, name);
  const runtime = JSON.parse(
    await fs.readFile(path.join(directory, "runtime.json"), "utf8")
  );
  validateRuntimeManifest(runtime, name);
  const contribution = runtime.contribution
    ? await readPluginManifestSource(path.join(directory, runtime.contribution))
    : null;
  if (contribution && (contribution.id !== runtime.id || contribution.version !== runtime.version)) {
    throw new Error(`Built-in plugin '${runtime.id}' contribution metadata does not match.`);
  }
  const views = runtime.views.map((view) => {
    const contributed = contribution?.surface.id === view.id
      ? contribution.surface
      : null;
    return {
      id: view.id,
      title: String(view.title || contributed?.title || runtime.name),
      description: String(view.description || contributed?.description || runtime.description || ""),
      icon: String(view.icon || contributed?.icon || runtime.icon || "square.grid.2x2"),
      renderer: String(view.renderer || contributed?.type || "native"),
      order: Number.isFinite(view.order) ? Number(view.order) : Number(contributed?.order || 1000),
      navigation: contributed?.navigation || [],
      dataPath: contributed
        ? `/api/plugins/${encodeURIComponent(runtime.id)}/view-document`
        : null,
      hasAuthentication: Boolean(contributed?.auth)
    };
  });
  const compatibility = normalizeClientCompatibility({
    platforms: runtime.platforms,
    formFactors: runtime.formFactors,
    subject: `Built-in plugin '${runtime.id}'`
  });
  return Object.freeze({
    schemaVersion: 1,
    id: runtime.id,
    version: runtime.version,
    name: runtime.name,
    description: String(runtime.description || ""),
    publisher: "Codmes",
    icon: String(runtime.icon || "square.grid.2x2"),
    platforms: compatibility.platforms,
    formFactors: compatibility.formFactors,
    permissions: contribution?.permissions || [],
    distribution: "builtin",
    builtIn: true,
    removable: false,
    views,
    tools: contribution
      ? contribution.tools.map((tool) => ({
        ...tool,
        pluginId: runtime.id,
        group: tool.group || `builtin:${runtime.id}`
      }))
      : [],
    storage: contribution?.storage || null,
    contribution
  });
}

function validateRuntimeManifest(value, directoryName) {
  if (Number(value?.schemaVersion) !== 1) {
    throw new Error(`Built-in plugin '${directoryName}' runtime schema is invalid.`);
  }
  if (String(value.id || "") !== `com.codmes.${directoryName}`) {
    throw new Error(`Built-in plugin '${directoryName}' id is invalid.`);
  }
  if (!/^\d+\.\d+\.\d+/.test(String(value.version || ""))
      || !String(value.name || "").trim()
      || !Array.isArray(value.platforms)
      || !Array.isArray(value.formFactors)
      || !Array.isArray(value.views)
      || value.views.length === 0) {
    throw new Error(`Built-in plugin '${value.id}' metadata is incomplete.`);
  }
  for (const view of value.views) {
    if (!/^[a-z][a-z0-9_-]*$/.test(String(view?.id || ""))
        || !["native", "declarative"].includes(String(view.renderer || ""))) {
      throw new Error(`Built-in plugin '${value.id}' view is invalid.`);
    }
  }
}
