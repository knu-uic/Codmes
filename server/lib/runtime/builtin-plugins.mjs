import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  getInstalledPlugin,
  getPluginInstallState,
  installPlugin,
  readPluginManifestSource
} from "./plugin-registry.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

const BUILTIN_PLUGINS = Object.freeze([
  {
    id: "com.codmes.planner",
    sourcePath: path.join(REPO_ROOT, "bundled", "plugins", "planner")
  }
]);

export async function ensureBuiltInPlugins(workspaceRoot) {
  const results = [];
  for (const descriptor of BUILTIN_PLUGINS) {
    const bundled = await readPluginManifestSource(descriptor.sourcePath);
    if (bundled.id !== descriptor.id) {
      throw new Error(`Bundled plugin id does not match '${descriptor.id}'.`);
    }
    const installed = await getInstalledPlugin(workspaceRoot, descriptor.id);
    const state = installed
      ? await getPluginInstallState(workspaceRoot, descriptor.id)
      : null;
    const alreadyCurrent = installed?.version === bundled.version
      && state?.source?.type === "builtin";
    if (alreadyCurrent) {
      results.push({ pluginId: descriptor.id, action: "unchanged", version: bundled.version });
      continue;
    }
    if (installed && compareSemver(installed.version, bundled.version) > 0) {
      results.push({
        pluginId: descriptor.id,
        action: "newer-version-preserved",
        version: installed.version
      });
      continue;
    }
    const result = await installPlugin(workspaceRoot, descriptor.sourcePath, {
      acceptedPermissions: bundled.permissions,
      source: {
        type: "builtin",
        pluginId: descriptor.id,
        version: bundled.version
      }
    });
    results.push({
      pluginId: descriptor.id,
      action: installed ? "migrated-or-updated" : "installed",
      version: result.plugin.version
    });
  }
  return results;
}

function compareSemver(left, right) {
  const a = String(left).split(/[+-]/, 1)[0].split(".").map(Number);
  const b = String(right).split(/[+-]/, 1)[0].split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
  }
  return 0;
}
