export const BUILTIN_PLUGIN_IDS = Object.freeze([
  "com.codmes.planner"
]);

const BUILTIN_PLUGIN_ID_SET = new Set(BUILTIN_PLUGIN_IDS);

export function isBuiltInPluginId(pluginId) {
  return BUILTIN_PLUGIN_ID_SET.has(String(pluginId || "").trim().toLowerCase());
}

export function pluginDistribution(pluginId) {
  return isBuiltInPluginId(pluginId) ? "builtin" : "community";
}
