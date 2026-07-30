import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const ID_PATTERN = /^[a-z][a-z0-9_-]{0,63}$/;
const collectionLocks = new Map();

export function normalizePluginStorage(value) {
  if (value == null) return null;
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Number(value.schemaVersion) !== 1 || !Array.isArray(value.collections)) {
    throw new Error("Plugin storage document schema is invalid.");
  }
  const collections = value.collections.map((item) => {
    const id = String(item?.id || "").trim();
    if (!ID_PATTERN.test(id)) throw new Error("Plugin collection id is invalid.");
    if (!item.itemSchema || item.itemSchema.type !== "object") {
      throw new Error(`Plugin collection '${id}' requires an object itemSchema.`);
    }
    return { id, itemSchema: JSON.parse(JSON.stringify(item.itemSchema)) };
  });
  if (new Set(collections.map((item) => item.id)).size !== collections.length) {
    throw new Error("Plugin collection ids must be unique.");
  }
  return { schemaVersion: 1, collections };
}

export function parsePluginCollectionTool(value) {
  const match = /^collection\.([a-z][a-z0-9_-]{0,63})\.(list|get|create|update|delete)$/.exec(String(value || ""));
  if (!match) throw new Error("Plugin provider tool must use collection.<id>.<operation>.");
  return { collectionId: match[1], operation: match[2] };
}

export async function previewPluginCollectionTool(workspaceRoot, descriptor, args = {}) {
  const operation = parsePluginCollectionTool(descriptor.provider.tool);
  const current = ["update", "delete"].includes(operation.operation)
    ? await findItem(workspaceRoot, descriptor.pluginId, operation.collectionId, args.id)
    : null;
  return {
    provider: "plugin",
    pluginId: descriptor.pluginId,
    collection: operation.collectionId,
    operation: operation.operation,
    itemId: args.id || null,
    before: current,
    after: operation.operation === "delete" ? null : (args.item || null)
  };
}

export async function readPluginCollection(workspaceRoot, manifest, collectionId) {
  const id = String(collectionId || "");
  if (!manifest.storage?.collections?.some((item) => item.id === id)) {
    throw Object.assign(new Error("Plugin collection was not found."), { status: 404 });
  }
  return await readCollection(workspaceRoot, manifest.id, id);
}

export async function executePluginCollectionTool(workspaceRoot, manifest, descriptor, args = {}) {
  const { collectionId, operation } = parsePluginCollectionTool(descriptor.provider.tool);
  return await mutatePluginCollection(workspaceRoot, manifest, collectionId, operation, args);
}

export async function mutatePluginCollection(workspaceRoot, manifest, collectionId, operation, args = {}) {
  if (!["list", "get", "create", "update", "delete"].includes(operation)) {
    throw Object.assign(new Error("Unsupported plugin collection operation."), { status: 400 });
  }
  if (["list", "get"].includes(operation)) {
    return await executeUnlocked(workspaceRoot, manifest, args, collectionId, operation);
  }
  const key = `${path.resolve(workspaceRoot)}\0${manifest.id}\0${collectionId}`;
  const previous = collectionLocks.get(key) || Promise.resolve();
  const current = previous.catch(() => {}).then(
    () => executeUnlocked(workspaceRoot, manifest, args, collectionId, operation)
  );
  collectionLocks.set(key, current);
  try { return await current; }
  finally { if (collectionLocks.get(key) === current) collectionLocks.delete(key); }
}

async function executeUnlocked(workspaceRoot, manifest, args, collectionId, operation) {
  const collection = manifest.storage?.collections?.find((item) => item.id === collectionId);
  if (!collection) throw Object.assign(new Error("Plugin collection is not declared."), { status: 400 });
  const state = await readCollection(workspaceRoot, manifest.id, collectionId);
  if (operation === "list") return { items: state.items };
  if (operation === "get") return { item: requireItem(state.items, args.id) };
  if (operation === "create") {
    const item = { ...validatePluginCollectionItem(args.item, collection.itemSchema), id: String(args.item?.id || crypto.randomUUID()) };
    if (state.items.some((value) => value.id === item.id)) throw Object.assign(new Error("Plugin item already exists."), { status: 409 });
    state.items.push(item);
    await writeCollection(workspaceRoot, manifest.id, collectionId, state);
    return { created: true, item };
  }
  const index = state.items.findIndex((item) => item.id === String(args.id || ""));
  if (index < 0) throw Object.assign(new Error("Plugin item was not found."), { status: 404 });
  const before = state.items[index];
  if (operation === "delete") {
    state.items.splice(index, 1);
    await writeCollection(workspaceRoot, manifest.id, collectionId, state);
    return { deleted: true, item: before };
  }
  const item = { ...validatePluginCollectionItem({ ...before, ...(args.item || {}) }, collection.itemSchema), id: before.id };
  state.items[index] = item;
  await writeCollection(workspaceRoot, manifest.id, collectionId, state);
  return { updated: true, before, item };
}

async function findItem(root, pluginId, collectionId, id) {
  return (await readCollection(root, pluginId, collectionId)).items.find((item) => item.id === String(id || "")) || null;
}
function requireItem(items, id) {
  const item = items.find((value) => value.id === String(id || ""));
  if (!item) throw Object.assign(new Error("Plugin item was not found."), { status: 404 });
  return item;
}
export function validatePluginCollectionItem(value, schema) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Plugin item must be an object.");
  for (const key of schema.required || []) if (value[key] == null) throw new Error(`Plugin item requires '${key}'.`);
  for (const [key, rule] of Object.entries(schema.properties || {})) {
    if (value[key] == null) continue;
    if (rule.type === "string" && typeof value[key] !== "string") throw new Error(`Plugin item '${key}' must be a string.`);
    if (rule.type === "boolean" && typeof value[key] !== "boolean") throw new Error(`Plugin item '${key}' must be a boolean.`);
    if (rule.type === "number" && typeof value[key] !== "number") throw new Error(`Plugin item '${key}' must be a number.`);
  }
  return JSON.parse(JSON.stringify(value));
}
function collectionPath(root, pluginId, collectionId) {
  return path.join(root, ".codmes", "plugin-data", pluginId, `${collectionId}.json`);
}
async function readCollection(root, pluginId, collectionId) {
  try { return JSON.parse(await fs.readFile(collectionPath(root, pluginId, collectionId), "utf8")); }
  catch (error) {
    if (error?.code === "ENOENT") return { schemaVersion: 1, revision: 0, items: [] };
    throw error;
  }
}
async function writeCollection(root, pluginId, collectionId, state) {
  const target = collectionPath(root, pluginId, collectionId);
  await fs.mkdir(path.dirname(target), { recursive: true });
  const next = { schemaVersion: 1, revision: Number(state.revision || 0) + 1, updatedAt: new Date().toISOString(), items: state.items };
  const temporary = `${target}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  await fs.writeFile(temporary, JSON.stringify(next, null, 2) + "\n", "utf8");
  await fs.rename(temporary, target);
}
