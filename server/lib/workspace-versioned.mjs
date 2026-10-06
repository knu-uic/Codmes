import fs from "node:fs/promises";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { mergeText, mergeAnnotationsPrecise } from "./workspace-merge.mjs";
import { preserveSyncBase as preserve, readSyncBase as blob, materializeSyncBase } from "./workspace-sync-storage.mjs";

const digest = data => createHash("sha256").update(data).digest("hex");
const fail = (message, status = 409) => Object.assign(new Error(message), { status });
const textPath = /\.(md|markdown|txt|swift|js|mjs|cjs|ts|jsx|tsx|py|go|rs|java|c|cpp|h|cs|html|css|json|yaml|yml|toml|sh|xml|csv)$/i;
const lexical = (a, b) => a === b ? 0 : a < b ? -1 : 1;
const compare = (a, b) => a.time - b.time || a.counter - b.counter || lexical(a.deviceId, b.deviceId) || lexical(a.id, b.id);
const emptyAnnotations = { schemaVersion: 2, pages: [], objects: [], elements: [] };

function directory(root, logicalPath, resource) {
  return path.join(root, ".codmes", "sync-v2", digest(JSON.stringify([logicalPath, resource])));
}
async function json(file) {
  try { return JSON.parse(await fs.readFile(file, "utf8")); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
}
async function atomic(file, value) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const handle = await fs.open(temporary, "wx", 0o600);
  try { await handle.writeFile(JSON.stringify(value)); await handle.sync(); }
  finally { await handle.close(); }
  await fs.rename(temporary, file);
}
export async function relocateVersionedJournals(root, from, to, states, rejectSymlinks) {
  for (const original of states) {
    const destination = to + original.path.slice(from.length);
    const moved = { ...original, path: destination };
    const newFile = path.join(directory(root, destination, original.resource), "state.json");
    await rejectSymlinks(root, newFile); await atomic(newFile, moved);
    // Retain aliases for old offline edits, but do not resurrect the old path.
    const old = { ...original, materializedRevision: null, materializedVersion: `move_${digest(destination).slice(0, 32)}`, pendingProjection: false, modifiedAt: new Date().toISOString() };
    await atomic(path.join(directory(root, original.path, original.resource), "state.json"), old);
  }
}
export function validateOperation(change) {
  if (!/^[A-Za-z0-9_-]{16,80}$/.test(change.operationId ?? "") || !/^[A-Za-z0-9_.:-]{1,128}$/.test(change.deviceId ?? "")) throw fail("A stable operation and device ID are required.", 400);
  const time = Date.parse(change.modifiedAt);
  if (!Number.isFinite(time) || time < Date.UTC(2000, 0, 1)) throw fail("A valid local modification time is required.", 400);
  if (time > Date.now() + 5 * 60_000) throw fail("The device clock is more than five minutes ahead. Correct its time before retrying; local changes are retained.");
  if (change.baseVersion != null && !/^(?:[A-Za-z0-9_-]{16,80}|legacy:[a-f0-9]{64})$/.test(change.baseVersion)) throw fail("Invalid base version.", 400);
  return time;
}

// State is a write-ahead intent. A crash after committing an operation is repaired
// before serving a manifest/history. Raw inputs AND projected outcomes are immutable.
export async function recoverVersionedDocument(root, target, state, rejectSymlinks) {
  if (!state?.pendingProjection) return;
  await rejectSymlinks(root, target.absolutePath);
  if (state.materializedRevision == null) {
    try {
      // Its existing bytes already belong to the immutable merge base store.
      // A second whole-file trash copy adds no synchronization safety.
      await fs.unlink(target.absolutePath);
    } catch (error) { if (error.code !== "ENOENT") throw error; }
  } else {
    await fs.mkdir(path.dirname(target.absolutePath), { recursive: true });
    const temporary = path.join(directory(root, state.path, state.resource), `${randomUUID()}.sync-tmp`);
    await rejectSymlinks(root, temporary);
    await materializeSyncBase(root, state.materializedRevision, temporary, rejectSymlinks);
    await fs.rename(temporary, target.absolutePath);
  }
  state.pendingProjection = false;
  await atomic(path.join(directory(root, state.path, state.resource), "state.json"), state);
}

export async function readVersionedState(root, logicalPath, resource, rejectSymlinks) {
  const file = path.join(directory(root, logicalPath, resource), "state.json");
  await rejectSymlinks(root, file);
  const state = await json(file);
  if (state && (state.version !== 2 || state.path !== logicalPath || state.resource !== resource)) throw fail("Invalid synchronization journal.");
  return state;
}

export async function versionedJournals(root, rejectSymlinks) {
  const base = path.join(root, ".codmes", "sync-v2");
  await rejectSymlinks(root, base);
  let names;
  try { names = await fs.readdir(base); } catch (error) { if (error.code === "ENOENT") return []; throw error; }
  const states = [];
  for (const name of names) {
    if (!/^[a-f0-9]{64}$/.test(name)) continue;
    const file = path.join(base, name, "state.json");
    await rejectSymlinks(root, file);
    const state = await json(file);
    if (state) states.push(state);
  }
  return states;
}

export function validateVersionedAnnotations(doc) {
  const visit = value => {
    if (!value || typeof value !== "object") return;
    if (Object.keys(value).some(key => ["__proto__", "prototype", "constructor"].includes(key))) throw fail("Unsafe annotation property.", 400);
    for (const child of Object.values(value)) visit(child);
  };
  visit(doc);
  const items = values => {
    if (values == null) return;
    if (!Array.isArray(values)) throw fail("Annotation entities must be arrays.", 400);
    const ids = new Set();
    for (const value of values) {
      if (!value || typeof value.id !== "string" || !value.id || ids.has(value.id)) throw fail("Invalid or duplicate annotation ID.", 400);
      ids.add(value.id);
    }
  };
  items(doc.objects); items(doc.elements);
  const pages = new Set();
  const indexes = new Set();
  for (const page of doc.pages) {
    if (!page || !Number.isSafeInteger(page.pageIndex) || page.pageIndex < 0 || (page.pageId != null && (typeof page.pageId !== "string" || !page.pageId))) throw fail("Invalid annotation page.", 400);
    const id = page.pageId ?? `index:${page.pageIndex}`;
    if (pages.has(id) || indexes.has(page.pageIndex)) throw fail("Duplicate annotation page.", 400);
    indexes.add(page.pageIndex);
    pages.add(id); items(page.objects); items(page.elements); items(page.inkStrokes);
  }
}

async function project(root, state, rejectSymlinks, previous, added) {
  const ordered = [...state.operations].sort(compare);
  const incremental = previous && ordered.at(-1).id === added.id;
  let revision = incremental ? previous.materializedRevision : state.rootRevision;
  let data = null;
  const events = incremental ? [added] : ordered;
  for (let index = 0; index < events.length; index++) {
    const event = events[index];
    if (event.action === "delete") { revision = null; data = null; continue; }
    if (state.resource === "annotations") {
      const parse = async rev => rev ? JSON.parse((await blob(root, rev, rejectSymlinks)).toString("utf8")) : structuredClone(emptyAnnotations);
      const before = await parse(event.baseRevision);
      const current = data ? JSON.parse(data.toString("utf8")) : await parse(revision);
      const incoming = await parse(event.revision);
      data = Buffer.from(JSON.stringify(mergeAnnotationsPrecise(before, current, incoming, state.path, new Date(event.time).toISOString())));
      // Concurrent structural edits cannot map two different pages onto one index.
      // Keep the operation pending instead of attaching ink to the wrong page.
      validateVersionedAnnotations(JSON.parse(data));
      if (data.length > 16 * 1024 * 1024) throw fail("Merged PDF annotations exceed 16 MB.", 413);
      revision = digest(data);
    } else if (textPath.test(state.path) && revision && event.baseRevision) {
      const before = await blob(root, event.baseRevision, rejectSymlinks), incoming = await blob(root, event.revision, rejectSymlinks);
      const current = data ?? await blob(root, revision, rejectSymlinks);
      if (Math.max(before.length, incoming.length, current.length) > 8 * 1024 * 1024) {
        if (!current.equals(before) && !current.equals(incoming)) throw fail("This text conflict exceeds the safe merge size. Local edits remain pending.");
        data = incoming;
      } else {
        const decode = new TextDecoder("utf-8", { fatal: true });
        let strings;
        try { strings = [before, current, incoming].map(buffer => decode.decode(buffer)); }
        catch { strings = null; }
        data = strings ? Buffer.from(mergeText(...strings, { precise: true })) : incoming;
      }
      revision = digest(data);
    } else { revision = event.revision; data = null; }
    if (index % 16 === 15) await new Promise(resolve => setImmediate(resolve));
  }
  return { revision, data, events: ordered };
}

export async function applyVersionedChange(root, change, staged, context) {
  const { target, current, rejectSymlinks, entryFor } = context;
  const time = validateOperation(change);
  if (change.resource === "folder") throw fail("Folders retain conditional structural synchronization.", 400);
  let state = await readVersionedState(root, change.path, change.resource, rejectSymlinks);
  if (state?.pendingProjection) { await recoverVersionedDocument(root, target, state, rejectSymlinks); return applyVersionedChange(root, change, staged, { ...context, current: await entryFor(root, change.path, change.resource) }); }
  if (current && !state) await preserve(root, target.absolutePath, current.revision, rejectSymlinks);
  // Original client snapshots can become bases for subsequent offline edits even
  // when their acknowledged projection contains changes from other devices.
  if (!state) {
    const rootRevision = change.baseRevision ?? current?.revision ?? null;
    if (rootRevision) {
      try { await blob(root, rootRevision, rejectSymlinks); }
      catch (error) { if (error.code === "ENOENT") return { status: "conflict", entry: current, reason: "base-missing" }; throw error; }
    }
    state = { version: 2, path: change.path, resource: change.resource, rootRevision, operations: [], versions: {}, snapshots: [], materializedRevision: current?.revision ?? null };
    if (rootRevision) {
      state.versions[`legacy:${rootRevision}`] = { revision: rootRevision, time: 0, counter: 0 };
      state.snapshots.push({ versionId: `legacy:${rootRevision}`, revision: rootRevision, modifiedAt: current?.modifiedAt ?? new Date(0).toISOString(), deviceId: "legacy", operationId: null, deleted: false, baseline: true });
    }
    if (current && current.revision !== rootRevision) {
      const seed = { id: `legacy_${current.revision}`, deviceId: "legacy", time: Date.parse(current.modifiedAt), counter: 0, action: "put", baseRevision: rootRevision, revision: current.revision, parents: [], localModifiedAt: current.modifiedAt };
      state.operations.push(seed);
      state.versions[`legacy:${current.revision}`] = { revision: current.revision, time: seed.time, counter: seed.counter };
    }
  }
  // Never silently overwrite a file modified through an older API or externally.
  // Its source time is unknown: let the user sync a fresh base rather than invent it.
  if ((current?.revision ?? null) !== state.materializedRevision) return { status: "conflict", entry: current, reason: "untracked-change" };
  const revision = staged?.revision ?? null;
  const duplicate = state.operations.find(event => event.id === change.operationId);
  if (duplicate) {
    if (duplicate.revision !== revision || duplicate.baseRevision !== change.baseRevision || duplicate.action !== change.action || duplicate.deviceId !== change.deviceId || duplicate.localModifiedAt !== change.modifiedAt || duplicate.baseVersion !== (change.baseVersion ?? null)) throw fail("An operation ID was reused with different content.", 400);
    return { status: "applied", entry: current, operationId: change.operationId };
  }
  let base;
  if (change.baseVersion) base = state.versions[change.baseVersion];
  else if (change.baseRevision == null) base = { revision: null, parents: [] };
  else base = state.versions[`legacy:${change.baseRevision}`];
  if (!base || base.revision !== change.baseRevision) return { status: "conflict", entry: current, reason: "base-missing" };
  // Only the observed causal clock is needed for ordering. Storing every ancestor
  // on every save makes a long-lived autosave journal grow quadratically.
  const causal = base.time != null ? base : state.operations.filter(event => (base.parents ?? []).includes(event.id)).sort(compare).at(-1);
  const effectiveTime = Math.max(time, causal?.time ?? 0);
  const event = { id: change.operationId, deviceId: change.deviceId, time: effectiveTime, counter: causal?.time === effectiveTime ? causal.counter + 1 : 0, action: change.action, baseRevision: change.baseRevision, baseVersion: change.baseVersion ?? null, revision, localModifiedAt: change.modifiedAt };
  if (staged) await preserve(root, staged.file, staged.revision, rejectSymlinks);
  const next = structuredClone(state);
  next.operations.push(event);
  next.versions[event.id] = { revision, time: event.time, counter: event.counter };
  const projected = await project(root, next, rejectSymlinks, state.operations.length ? state : null, event);
  if (projected.data) {
    const temporary = path.join(directory(root, change.path, change.resource), `${randomUUID()}.projection`);
    await rejectSymlinks(root, temporary);
    await fs.mkdir(path.dirname(temporary), { recursive: true, mode: 0o700 });
    try { await fs.writeFile(temporary, projected.data, { mode: 0o600 }); await preserve(root, temporary, projected.revision, rejectSymlinks); }
    finally { await fs.rm(temporary, { force: true }); }
  }
  const versionId = digest(JSON.stringify([next.rootRevision, projected.events.map(item => item.id)]));
  const latest = projected.events.at(-1);
  next.versions[versionId] = { revision: projected.revision, time: latest.time, counter: latest.counter };
  next.materializedRevision = projected.revision;
  next.materializedVersion = versionId;
  next.modifiedAt = new Date(projected.events.at(-1).time).toISOString();
  // Not a user-facing archive. Only the latest projection metadata is needed;
  // version aliases and shared base blocks remain for long-offline clients.
  next.snapshots = [{ versionId, revision: projected.revision, modifiedAt: next.modifiedAt, localModifiedAt: event.localModifiedAt, deviceId: event.deviceId, operationId: event.id, deleted: projected.revision == null }];
  next.pendingProjection = true;
  const journal = path.join(directory(root, change.path, change.resource), "state.json");
  await rejectSymlinks(root, journal);
  await atomic(journal, next);
  await recoverVersionedDocument(root, target, next, rejectSymlinks);
  return { status: "applied", entry: await entryFor(root, change.path, change.resource), operationId: event.id };
}

export async function versionedHistory(root, logicalPath, resource, rejectSymlinks, offset = 0) {
  const state = await readVersionedState(root, logicalPath, resource, rejectSymlinks);
  const snapshots = state ? [...state.snapshots].reverse() : [];
  const originals = state ? state.operations.map(event => ({ versionId: event.id, revision: event.revision, modifiedAt: event.localModifiedAt, deviceId: event.deviceId, operationId: event.id, deleted: event.action === "delete", original: true })).reverse() : [];
  const entries = [...snapshots, ...originals];
  return { entries: entries.slice(offset, offset + 100), nextOffset: entries.length > offset + 100 ? offset + 100 : null };
}

export async function historicalBlob(root, logicalPath, resource, versionId, rejectSymlinks) {
  const state = await readVersionedState(root, logicalPath, resource, rejectSymlinks);
  const version = state?.versions[versionId];
  if (!version || !version.revision) throw fail("This version is missing or represents a deletion.", 404);
  // Authorization is document-scoped, not an arbitrary content hash lookup.
  return blob(root, version.revision, rejectSymlinks);
}

export async function historicalFile(root, logicalPath, resource, versionId, rejectSymlinks) {
  const state = await readVersionedState(root, logicalPath, resource, rejectSymlinks);
  const version = state?.versions[versionId];
  if (!version?.revision || !/^[a-f0-9]{64}$/.test(version.revision)) throw fail("This version is missing or represents a deletion.", 404);
  const file = path.join(directory(root, logicalPath, resource), `${randomUUID()}.sync-tmp`);
  await materializeSyncBase(root, version.revision, file, rejectSymlinks);
  return { file, revision: version.revision, temporary: true };
}
