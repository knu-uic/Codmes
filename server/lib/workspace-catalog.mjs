import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";

const fail = (message, status = 400) => Object.assign(new Error(message), { status });
export const validIdentity = value => typeof value === "string" && /^[A-Za-z0-9_-]{16,80}$/.test(value);
export const catalogKey = entry => `${entry.resource === "folder" ? "folder" : "file"}:${entry.path}`;
const target = root => path.join(root, ".codmes", "sync-catalog.json");
export async function readCatalog(root, safe) {
  await safe(root, target(root));
  try {
    const state = JSON.parse(await fs.readFile(target(root), "utf8"));
    if (state.version !== 1 || !state.entries || !state.devices) throw fail("Invalid file catalog.", 500);
    return state;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return { version: 1, serverId: randomUUID(), revision: 0, entries: {}, devices: {} };
  }
}
export async function writeCatalog(root, state, safe) {
  const file = target(root); await safe(root, file);
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  const handle = await fs.open(temporary, "wx", 0o600);
  try { await handle.writeFile(JSON.stringify(state)); await handle.sync(); }
  finally { await handle.close(); }
  try { await fs.rename(temporary, file); }
  finally { await fs.rm(temporary, { force: true }); }
}
export function annotationFingerprint(value) {
  if (!value) return "none";
  const doc = structuredClone(value); delete doc.updatedAt; delete doc.documentPath;
  for (const key of ["objects", "elements", "pages"]) doc[key] ??= [];
  for (const page of doc.pages) {
    page.pageId ??= `index:${page.pageIndex}`;
    for (const key of ["objects", "elements", "inkStrokes"]) page[key] ??= [];
  }
  doc.pages.sort((a, b) => a.pageIndex - b.pageIndex);
  // No ink and no properties other than default arrays is equivalent to no sidecar.
  if (![...doc.objects, ...doc.elements, ...doc.pages].length && Object.keys(doc).every(k => ["schemaVersion", "pages", "objects", "elements"].includes(k))) return "none";
  const canonical = object => Array.isArray(object) ? object.map(canonical) : object && typeof object === "object"
    ? Object.fromEntries(Object.keys(object).sort().map(key => [key, canonical(object[key])])) : object;
  return createHash("sha256").update(JSON.stringify(canonical(doc))).digest("hex");
}
export async function catalogManifest(root, manifest, safe, annotationReader) {
  const state = await readCatalog(root, safe);
  let changed = false; const present = new Set();
  for (const entry of manifest.entries) {
    const key = catalogKey(entry); present.add(key);
    if (entry.resource === "annotations") continue;
    let record = state.entries[key];
    if (!record || record.deleted) { record = { fileId: randomUUID(), path: entry.path, resource: entry.resource }; changed = true; }
    if (record.revision !== entry.revision || record.versionId !== entry.versionId || record.statSignature !== entry._statSignature) changed = true;
    state.entries[key] = { ...record, revision: entry.revision, versionId: entry.versionId, statSignature: entry._statSignature, deleted: false };
  }
  for (const [key, record] of Object.entries(state.entries)) if (!present.has(key) && !record.deleted) { record.deleted = true; changed = true; }
  if (changed || state.revision === 0) { state.revision++; await writeCatalog(root, state, safe); }
  for (const entry of manifest.entries) {
    entry.fileId = state.entries[catalogKey(entry)]?.fileId;
    if (entry.resource === "file" && entry.kind === "pdf") entry.annotationFingerprint = annotationFingerprint(await annotationReader(entry.path));
    delete entry._statSignature;
  }
  for (const entry of manifest.deletedEntries ?? []) entry.fileId = state.entries[catalogKey(entry)]?.fileId;
  return { ...manifest, serverId: state.serverId, catalogRevision: state.revision, selectiveSyncVersion: 1 };
}
export async function recordCatalogChange(root, change, entry, safe) {
  const state = await readCatalog(root, safe); const key = catalogKey(change);
  const old = state.entries[key];
  if (entry) {
    const fileId = old && !old.deleted ? old.fileId : validIdentity(change.fileId) ? change.fileId : randomUUID();
    // A PDF's annotations must use the document identity, not create another file.
    if (change.resource === "annotations") {
      if (old) state.entries[key] = { ...old, annotationRevision: entry.revision };
    } else state.entries[key] = { ...old, fileId, path: change.path, resource: change.resource === "folder" ? "folder" : "file", revision: entry.revision, statSignature: entry._statSignature, deleted: false };
    entry.fileId = state.entries[key]?.fileId;
    delete entry._statSignature;
  } else if (old && change.resource !== "annotations") state.entries[key] = { ...old, deleted: true };
  state.revision++; await writeCatalog(root, state, safe);
}
export async function reportDevicePolicies(root, deviceId, policies, safe) {
  if (!validIdentity(deviceId) || !Array.isArray(policies) || policies.length > 10000) throw fail("Invalid device policy report.");
  const state = await readCatalog(root, safe);
  const known = new Set(Object.values(state.entries).map(entry => entry.fileId));
  const previous = state.devices[deviceId]?.policies ?? {};
  for (const item of policies) {
    if (!known.has(item.fileId) || !["local", "server", "sync"].includes(item.mode)) throw fail("Unknown file or storage mode.");
    previous[item.fileId] = { mode: item.mode, locallyAvailable: item.locallyAvailable === true, pending: item.pending === true };
  }
  state.devices[deviceId] = { policies: previous, reportedAt: new Date().toISOString() };
  await writeCatalog(root, state, safe);
  return { deviceId, ...state.devices[deviceId] };
}
