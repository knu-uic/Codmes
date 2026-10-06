import fs from "node:fs/promises";
import { createReadStream } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { fileKind, resolveWorkspacePath } from "./path-utils.mjs";
import { annotationsPathForDocument } from "./document-ingest.mjs";
import { mergeText, mergeAnnotations } from "./workspace-merge.mjs";
import { applyVersionedChange, readVersionedState, recoverVersionedDocument, versionedHistory, historicalBlob, historicalFile, versionedJournals, validateVersionedAnnotations, validateOperation, relocateVersionedJournals } from "./workspace-versioned.mjs";
import { catalogManifest, readCatalog, writeCatalog, catalogKey, recordCatalogChange, reportDevicePolicies, validIdentity, annotationFingerprint } from "./workspace-catalog.mjs";

const locks = new Map();
const fail = (message, status = 400) => Object.assign(new Error(message), { status });

// All HTTP file mutations (including older clients) share this workspace lock.
export async function withWorkspaceFileLock(root, action) {
  const key = path.resolve(root);
  const previous = locks.get(key) || Promise.resolve();
  let release;
  const next = new Promise((resolve) => { release = resolve; });
  locks.set(key, next);
  await previous;
  let owned = false;
  const directory = path.join(key, ".codmes", "sync-writer-lock");
  try {
    await rejectSymlinks(root, directory);
    await fs.mkdir(path.dirname(directory), { recursive: true, mode: 0o700 });
    const deadline = Date.now() + 30000;
    while (!owned) {
      try {
        await fs.mkdir(directory, { mode: 0o700 }); owned = true;
        await fs.writeFile(path.join(directory, "owner.json"), JSON.stringify({ pid: process.pid }), { flag: "wx", mode: 0o600 });
      } catch (error) {
        if (owned || error.code !== "EEXIST") throw error;
        await rejectSymlinks(root, path.join(directory, "owner.json"));
        let stale = false;
        try {
          const owner = JSON.parse(await fs.readFile(path.join(directory, "owner.json"), "utf8"));
          if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw fail("Invalid synchronization lock owner.", 500);
          try { process.kill(owner.pid, 0); } catch (probe) { stale = probe.code === "ESRCH"; }
        } catch (probe) {
          if (probe.code !== "ENOENT") throw probe;
          // The owner may release the lock after mkdir reported EEXIST but
          // before these reads. A missing directory means retry acquisition,
          // not a synchronization failure or a stale lock to delete.
          const info = await fs.stat(directory).catch(error => {
            if (error.code === "ENOENT") return null;
            throw error;
          });
          stale = info != null && Date.now() - info.mtimeMs > 10000;
        }
        if (stale) {
          // Multiple processes may discover the same dead owner. Recheck after
          // exclusively claiming recovery, so a late waiter cannot erase a new owner.
          const claim = path.join(directory, "recovery.json"); await rejectSymlinks(root, claim);
          const beforeClaim = await fs.stat(directory).catch(probe => { if (probe.code === "ENOENT") return null; throw probe; });
          let recovery;
          try { recovery = await fs.open(claim, "wx", 0o600); }
          catch (claimError) { if (!["EEXIST", "ENOENT"].includes(claimError.code)) throw claimError; }
          if (recovery) {
            try {
              let dead = false;
              try {
                const latest = JSON.parse(await fs.readFile(path.join(directory, "owner.json"), "utf8"));
                if (!Number.isSafeInteger(latest.pid) || latest.pid <= 0) throw fail("Invalid synchronization lock owner.", 500);
                try { process.kill(latest.pid, 0); } catch (probe) { dead = probe.code === "ESRCH"; }
              } catch (probe) { if (probe.code !== "ENOENT") throw probe; dead = beforeClaim != null && Date.now() - beforeClaim.mtimeMs > 10000; }
              if (dead) await fs.rm(path.join(directory, "owner.json"), { force: true });
              await recovery.close(); recovery = null; await fs.unlink(claim);
              if (dead) try { await fs.rmdir(directory); } catch (cleanup) { if (!["ENOENT", "ENOTEMPTY"].includes(cleanup.code)) throw cleanup; }
            } finally { if (recovery) { await recovery.close(); await fs.rm(claim, { force: true }); } }
          }
        }
        if (Date.now() > deadline) throw fail("Another process is synchronizing this workspace. Retry shortly.", 503);
        await new Promise(resolve => setTimeout(resolve, 25));
      }
    }
    await recoverSyncMove(root);
    await recoverSyncBundle(root);
    return await action();
  } finally {
    try { if (owned) { await fs.rm(path.join(directory, "owner.json"), { force: true }); await fs.rmdir(directory); } }
    finally { release(); if (locks.get(key) === next) locks.delete(key); }
  }
}

async function rejectSymlinks(root, target) {
  const relative = path.relative(path.resolve(root), target);
  if (relative.startsWith("..") || path.isAbsolute(relative)) throw fail("Invalid sync path.");
  let current = path.resolve(root);
  for (const part of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    try {
      if ((await fs.lstat(current)).isSymbolicLink()) throw fail("Symlinks cannot be synchronized.");
    } catch (error) { if (error.code !== "ENOENT") throw error; }
  }
}

async function syncTarget(root, input, resource = "file") {
  if (typeof input !== "string" || !["file", "folder", "annotations"].includes(resource)) throw fail("Invalid sync resource.");
  const parts = input.split("/");
  if (!/^(Notes|Code)\//.test(input) || parts.some((part) => !part || [".", "..", ".codmes", ".git"].includes(part)) || input.includes("\\") || input.includes("\0")) {
    throw fail("Only Notes and Code content can be synchronized.");
  }
  const resolved = resolveWorkspacePath(root, input);
  await rejectSymlinks(root, resolved.absolutePath);
  const absolutePath = resource === "annotations" ? annotationsPathForDocument(root, resolved.relativePath) : resolved.absolutePath;
  await rejectSymlinks(root, absolutePath);
  return { relativePath: resolved.relativePath, absolutePath };
}

async function hashFile(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

async function entryFor(root, logicalPath, resource, hint = null) {
  const target = await syncTarget(root, logicalPath, resource);
  const journal = resource === "folder" ? null : await readVersionedState(root, logicalPath, resource, rejectSymlinks);
  await recoverVersionedDocument(root, target, journal, rejectSymlinks);
  let stat;
  try { stat = await fs.stat(target.absolutePath); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  if (resource === "folder" ? !stat.isDirectory() : !stat.isFile()) throw fail("Sync resource type changed.", 409);
  const signature = `${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}:${stat.ino}:${stat.dev}`;
  const revision = stat.isDirectory() ? "directory" : hint?.statSignature === signature && /^[a-f0-9]{64}$/.test(hint.revision) ? hint.revision : await hashFile(target.absolutePath);
  const tracked = journal?.materializedRevision === revision;
  return {
    path: logicalPath, resource, kind: resource === "annotations" ? "annotations" : fileKind(logicalPath, stat.isDirectory()),
    isDirectory: stat.isDirectory(), size: stat.isDirectory() ? 0 : stat.size,
    modifiedAt: tracked ? journal.modifiedAt : stat.mtime.toISOString(), revision,
    ...(tracked && { versionId: journal.materializedVersion, logicalModifiedAt: journal.modifiedAt }), _statSignature: signature
  };
}

export async function syncManifest(root) {
  const entries = [];
  const hints = (await readCatalog(root, rejectSymlinks)).entries;
  const journals = await versionedJournals(root, rejectSymlinks);
  for (const state of journals) {
    const target = await syncTarget(root, state.path, state.resource);
    await recoverVersionedDocument(root, target, state, rejectSymlinks);
  }
  async function walk(relative) {
    const target = resolveWorkspacePath(root, relative).absolutePath;
    await rejectSymlinks(root, target);
    let children;
    try { children = await fs.readdir(target, { withFileTypes: true }); }
    catch (error) { if (error.code === "ENOENT") return; throw error; }
    for (const child of children.sort((a, b) => a.name.localeCompare(b.name))) {
      if ([".codmes", ".git"].includes(child.name) || child.isSymbolicLink()) continue;
      const item = `${relative}/${child.name}`;
      if (!child.isDirectory() && !child.isFile()) continue;
      const entry = await entryFor(root, item, child.isDirectory() ? "folder" : "file", hints[`${child.isDirectory() ? "folder" : "file"}:${item}`]);
      if (!entry) continue;
      entries.push(entry);
      if (child.isDirectory()) await walk(item);
      else if (child.name.toLowerCase().endsWith(".pdf")) {
        const annotations = await entryFor(root, item, "annotations");
        if (annotations) entries.push(annotations);
      }
    }
  }
  await walk("Notes"); await walk("Code");
  const keys = new Set(entries.map(entry => `${entry.resource}:${entry.path}`));
  const deletedEntries = journals.filter(state => state.materializedRevision == null && !keys.has(`${state.resource}:${state.path}`)).map(state => ({ path: state.path, resource: state.resource, versionId: state.materializedVersion, modifiedAt: state.modifiedAt }));
  return catalogManifest(root, { version: 1, documentBundleVersion: 1, conflictPolicies: ["merge-latest", "merge-modified-v2"], entries, deletedEntries }, rejectSymlinks, async logicalPath => {
    const target = await syncTarget(root, logicalPath, "annotations");
    try { return JSON.parse(await fs.readFile(target.absolutePath, "utf8")); }
    catch (error) { if (error.code === "ENOENT") return null; throw error; }
  });
}

export async function syncDevicePolicies(root, deviceId, policies) {
  if (policies) return reportDevicePolicies(root, deviceId, policies, rejectSymlinks);
  return { devices: (await readCatalog(root, rejectSymlinks)).devices };
}

async function recoverSyncMove(root) {
  const file = path.join(root, ".codmes", "sync-move.json"); await rejectSymlinks(root, file);
  let intent; try { intent = JSON.parse(await fs.readFile(file, "utf8")); } catch (error) { if (error.code === "ENOENT") return; throw error; }
  const source = await syncTarget(root, intent.from, intent.resource);
  const destination = await syncTarget(root, intent.to, intent.resource);
  const exists = async file => fs.lstat(file).then(() => true, error => { if (error.code === "ENOENT") return false; throw error; });
  if (await exists(source.absolutePath)) {
    if (await exists(destination.absolutePath)) throw fail("Move recovery destination is occupied. Both files were preserved.", 409);
    for (const [, entry] of intent.entries) if (entry.resource === "file" && (await entryFor(root, entry.path, "file"))?.revision !== entry.revision) throw fail("Move recovery source changed. Files were preserved.", 409);
    await fs.mkdir(path.dirname(destination.absolutePath), { recursive: true }); await fs.rename(source.absolutePath, destination.absolutePath);
  } else {
    for (const [, entry] of intent.entries) if (entry.resource === "file" && (await entryFor(root, intent.to + entry.path.slice(intent.from.length), "file"))?.revision !== entry.revision) throw fail("Move recovery destination changed. Files were preserved.", 409);
    await fs.access(destination.absolutePath);
  }
  for (const document of intent.documents) {
    const before = await syncTarget(root, document.from, "annotations"), after = await syncTarget(root, document.to, "annotations");
    if (await exists(path.dirname(before.absolutePath))) {
      if (await exists(path.dirname(after.absolutePath))) throw fail("Move recovery annotation destination is occupied. Both copies were preserved.", 409);
      await fs.mkdir(path.dirname(path.dirname(after.absolutePath)), { recursive: true }); await fs.rename(path.dirname(before.absolutePath), path.dirname(after.absolutePath));
    }
  }
  await relocateVersionedJournals(root, intent.from, intent.to, intent.states, rejectSymlinks);
  const catalog = await readCatalog(root, rejectSymlinks);
  for (const [key, record] of intent.entries) {
    catalog.entries[key] = { ...record, deleted: true };
    const relocated = { ...record, path: intent.to + record.path.slice(intent.from.length), deleted: false };
    catalog.entries[catalogKey(relocated)] = relocated;
  }
  catalog.revision++; await writeCatalog(root, catalog, rejectSymlinks); await fs.unlink(file);
}

export async function applySyncMove(root, change) {
  if (!validIdentity(change.fileId)) throw fail("A stable file identity is required.");
  const catalog = await readCatalog(root, rejectSymlinks);
  const owner = Object.values(catalog.entries).find(record => record.fileId === change.fileId && !record.deleted);
  if (!owner) return { status: "conflict", entry: null, reason: "file-missing" };
  if (owner.path === change.to) return { status: "applied", entry: { ...await entryFor(root, owner.path, owner.resource), fileId: owner.fileId } };
  if (owner.path !== change.from) return { status: "conflict", entry: null, reason: "file-moved" };
  const source = await syncTarget(root, change.from, owner.resource), destination = await syncTarget(root, change.to, owner.resource);
  if (change.to.startsWith(change.from + "/") || change.to === change.from) throw fail("Invalid move destination.");
  const current = await entryFor(root, change.from, owner.resource);
  if (!current || current.revision !== change.expectedRevision) return { status: "conflict", entry: current, reason: "decision-stale" };
  try { await fs.access(destination.absolutePath); return { status: "conflict", entry: null, reason: "destination-exists" }; }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  const entries = Object.entries(catalog.entries).filter(([, entry]) => !entry.deleted && (entry.path === change.from || entry.path.startsWith(change.from + "/")));
  const documents = entries.filter(([, entry]) => entry.resource === "file").map(([, entry]) => ({ from: entry.path, to: change.to + entry.path.slice(change.from.length) }));
  for (const document of documents) {
    const after = await syncTarget(root, document.to, "annotations");
    try { await fs.access(path.dirname(after.absolutePath)); return { status: "conflict", entry: null, reason: "destination-state-exists" }; }
    catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  const states = (await versionedJournals(root, rejectSymlinks)).filter(state => state.path === change.from || state.path.startsWith(change.from + "/"));
  const intent = { from: change.from, to: change.to, resource: owner.resource, entries, documents, states };
  const file = path.join(root, ".codmes", "sync-move.json"); await rejectSymlinks(root, file);
  const temporary = `${file}.${randomUUID()}.tmp`; const handle = await fs.open(temporary, "wx", 0o600);
  try { await handle.writeFile(JSON.stringify(intent)); await handle.sync(); } finally { await handle.close(); }
  await fs.rename(temporary, file); await recoverSyncMove(root);
  return { status: "applied", entry: { ...await entryFor(root, change.to, owner.resource), fileId: owner.fileId } };
}

export async function readSyncBlob(root, logicalPath, resource, revision) {
  if (resource === "folder") throw fail("Folders do not have file content.");
  const target = await syncTarget(root, logicalPath, resource);
  const data = await fs.readFile(target.absolutePath);
  const digest = createHash("sha256").update(data).digest("hex");
  if (!revision || revision !== digest) throw fail("The server file changed. Refresh the sync manifest.", 409);
  return data;
}

// Copy under the writer lock, then stream an immutable snapshot without allocating a whole PDF.
export async function snapshotSyncBlob(root, logicalPath, resource, revision) {
  if (resource === "folder") throw fail("Folders do not have file content.");
  const target = await syncTarget(root, logicalPath, resource);
  const directory = path.join(root, ".codmes", "sync-staging");
  await rejectSymlinks(root, directory);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, randomUUID());
  try {
    await fs.copyFile(target.absolutePath, file);
    if (!revision || await hashFile(file) !== revision) throw fail("The server file changed. Refresh the sync manifest.", 409);
    return { file, size: (await fs.stat(file)).size };
  } catch (error) { await fs.rm(file, { force: true }); throw error; }
}

// Stream uploads to disk, rather than holding an entire book PDF/base64 JSON in memory.
export async function stageSyncUpload(root, stream) {
  const directory = path.join(root, ".codmes", "sync-staging");
  await rejectSymlinks(root, directory);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, randomUUID());
  const handle = await fs.open(file, "wx", 0o600);
  const hash = createHash("sha256");
  let size = 0;
  try {
    for await (const chunk of stream) {
      size += chunk.length;
      if (size > 2 * 1024 * 1024 * 1024) throw fail("Sync upload exceeds 2 GB.", 413);
      hash.update(chunk);
      await handle.writeFile(chunk);
    }
    await handle.sync();
  } catch (error) { await fs.rm(file, { force: true }); throw error; }
  finally { await handle.close(); }
  return { file, revision: hash.digest("hex"), size };
}

// Wire framing: uint32 BE JSON header length, header, original PDF, annotation JSON.
// Everything is staged before the writer lock; large originals are never base64 encoded.
export async function stageSyncBundle(root, stream) {
  const combined = await stageSyncUpload(root, stream); const parts = [];
  try {
    const handle = await fs.open(combined.file, "r"); let header;
    try {
      const lengthBytes = Buffer.alloc(4); if ((await handle.read(lengthBytes, 0, 4, 0)).bytesRead !== 4) throw fail("Incomplete document bundle.");
      const length = lengthBytes.readUInt32BE(); if (length < 2 || length > 65536) throw fail("Invalid document bundle header.");
      const bytes = Buffer.alloc(length); if ((await handle.read(bytes, 0, length, 4)).bytesRead !== length) throw fail("Incomplete document bundle header.");
      header = JSON.parse(bytes.toString("utf8"));
      if (![header.fileSize, header.annotationSize].every(n => Number.isSafeInteger(n) && n > 0) || header.annotationSize > 16 * 1024 * 1024 || combined.size !== 4 + length + header.fileSize + header.annotationSize) throw fail("Invalid document bundle lengths.");
      parts.push(await stageSyncUpload(root, createReadStream(combined.file, { start: 4 + length, end: 3 + length + header.fileSize })));
      parts.push(await stageSyncUpload(root, createReadStream(combined.file, { start: 4 + length + header.fileSize, end: combined.size - 1 })));
    } finally { await handle.close(); }
    return { header, parts };
  } catch (error) { for (const part of parts) await discardStagedSyncUpload(part); throw error; }
  finally { await discardStagedSyncUpload(combined); }
}

async function durableJSON(file, value) {
  const temporary = `${file}.${randomUUID()}.tmp`; const handle = await fs.open(temporary, "wx", 0o600);
  try { await handle.writeFile(JSON.stringify(value)); await handle.sync(); } finally { await handle.close(); }
  await fs.rename(temporary, file);
}

async function recoverSyncBundle(root) {
  const file = path.join(root, ".codmes", "sync-bundle.json"); await rejectSymlinks(root, file);
  let intent; try { intent = JSON.parse(await fs.readFile(file, "utf8")); } catch (error) { if (error.code === "ENOENT") return; throw error; }
  // Intent paths are never accepted from the network.
  if (!validIdentity(intent.id) || !Array.isArray(intent.changes) || intent.changes.length !== 2) throw fail("Invalid document transaction.", 500);
  const directory = path.join(root, ".codmes", "sync-bundles", intent.id); await rejectSymlinks(root, directory);
  for (let index = 0; index < 2; index++) {
    const staged = { ...intent.parts[index], file: path.join(directory, String(index)) }; await rejectSymlinks(root, staged.file);
    if (await hashFile(staged.file) !== staged.revision) throw fail("Damaged document transaction; existing data was preserved.", 500);
    const change = intent.changes[index];
    const result = await applySyncChangeContent(root, change, staged);
    if (result.status !== "applied") throw fail("Document transaction requires recovery; existing and staged data were preserved.", 409);
    await recordCatalogChange(root, change, result.entry, rejectSymlinks);
  }
  // Remove the commit marker first. Unreferenced staging cleanup cannot undo a commit.
  await fs.unlink(file); await fs.rm(directory, { recursive: true, force: true });
}

export async function applySyncBundle(root, bundle) {
  const changes = [bundle.header.fileChange, bundle.header.annotationChange];
  const [original, ink] = changes;
  if (!original || !ink || original.resource !== "file" || ink.resource !== "annotations" || original.path !== ink.path || !original.path.toLowerCase().endsWith(".pdf") || original.fileId !== ink.fileId || !validIdentity(original.fileId)) throw fail("Invalid PDF document bundle.");
  for (const change of changes) {
    if (change.action !== "put" || change.conflictPolicy !== "merge-modified-v2" || !validIdentity(change.operationId) || typeof change.deviceId !== "string" || !Number.isFinite(Date.parse(change.modifiedAt)) || !Object.hasOwn(change, "baseRevision")) throw fail("Invalid document operation.");
    await syncTarget(root, change.path, change.resource);
    validateOperation(change);
    if (change.baseRevision !== null && !/^[a-f0-9]{64}$/.test(change.baseRevision)) throw fail("Invalid document base.");
  }
  const doc = JSON.parse(await fs.readFile(bundle.parts[1].file, "utf8")); validateVersionedAnnotations(doc);
  const catalog = await readCatalog(root, rejectSymlinks), owner = catalog.entries[catalogKey(original)];
  const observed = await identifiedEntry(root, original.path, "file");
  const journals = await Promise.all(changes.map(change => readVersionedState(root, change.path, change.resource, rejectSymlinks)));
  const retries = changes.map((change, index) => journals[index]?.operations?.some(op => op.id === change.operationId));
  if (retries.every(Boolean)) {
    // applyVersionedChange checks that retried IDs still have exactly the same payload.
    for (let index = 0; index < 2; index++) await applySyncChangeContent(root, changes[index], bundle.parts[index]);
    return { status: "applied", entry: observed && { ...observed, fileId: owner?.fileId } };
  }
  if (retries.some(Boolean)) throw fail("Incomplete document receipt; recover the document transaction.", 409);
  if (owner && !owner.deleted && owner.fileId !== original.fileId || observed && original.baseRevision == null && !original.baseVersion) return { status: "conflict", entry: observed && { ...observed, fileId: owner?.fileId }, reason: "first-registration" };
  if (Object.values(catalog.entries).some(item => item.fileId === original.fileId && !item.deleted && item.path !== original.path)) return { status: "conflict", entry: observed, reason: "file-moved" };
  for (let index = 0; index < 2; index++) {
    const change = changes[index], current = await entryFor(root, change.path, change.resource), journal = journals[index];
    if ((current?.revision ?? "missing") !== (change.expectedRevision ?? change.baseRevision ?? "missing")) return { status: "conflict", entry: observed, reason: "decision-stale" };
    if (journal && (current?.revision ?? null) !== journal.materializedRevision) return { status: "conflict", entry: observed, reason: "untracked-change" };
    const legacyBase = !journal && current?.revision === change.baseRevision && (!change.baseVersion || change.baseVersion === `legacy:${change.baseRevision}`) ? { revision: current.revision } : null;
    const base = change.baseVersion ? journal?.versions?.[change.baseVersion] ?? legacyBase : change.baseRevision == null ? { revision: null } : journal?.versions?.[`legacy:${change.baseRevision}`] ?? legacyBase;
    if (!base || base.revision !== change.baseRevision) return { status: "conflict", entry: observed, reason: "base-missing" };
  }
  const id = randomUUID(), directory = path.join(root, ".codmes", "sync-bundles", id); await rejectSymlinks(root, directory); await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  let committed = false;
  try {
  for (let index = 0; index < 2; index++) {
    const file = path.join(directory, String(index)); await fs.copyFile(bundle.parts[index].file, file);
    const handle = await fs.open(file, "r+"); try { await handle.sync(); } finally { await handle.close(); }
  }
  // Both expected revisions were checked inside one lock. All readers recover this
  // durable intent before observing a document, including after process termination.
  await durableJSON(path.join(root, ".codmes", "sync-bundle.json"), { id, changes, parts: bundle.parts.map(({ revision, size }) => ({ revision, size })) });
  committed = true;
  await recoverSyncBundle(root);
  return { status: "applied", entry: { ...await entryFor(root, original.path, "file"), fileId: original.fileId } };
  } finally { if (!committed) await fs.rm(directory, { recursive: true, force: true }); }
}

export async function discardSyncBundle(bundle) { for (const part of bundle?.parts ?? []) await discardStagedSyncUpload(part); }

async function identifiedEntry(root, logicalPath, resource) {
  const entry = await entryFor(root, logicalPath, resource); if (!entry) return null;
  entry.fileId = (await readCatalog(root, rejectSymlinks)).entries[catalogKey(entry)]?.fileId;
  if (resource === "file" && entry.kind === "pdf") {
    const target = await syncTarget(root, logicalPath, "annotations");
    let doc; try { doc = JSON.parse(await fs.readFile(target.absolutePath, "utf8")); } catch (error) { if (error.code !== "ENOENT") throw error; }
    entry.annotationFingerprint = annotationFingerprint(doc);
  }
  delete entry._statSignature; return entry;
}

export async function applySyncChange(root, change, staged = null) {
  const observed = await identifiedEntry(root, change.path, change.resource ?? "file");
  const receiptState = change.operationId ? await readVersionedState(root, change.path, change.resource ?? "file", rejectSymlinks) : null;
  const retry = receiptState?.operations?.some(operation => operation.id === change.operationId);
  if (change.conflictPolicy === "merge-modified-v2" && (change.resource ?? "file") === "file" && observed && change.baseRevision == null && !change.baseVersion && !retry) {
    return { status: "conflict", entry: observed, reason: "first-registration" };
  }
  // Stable identity is a condition, not proof that independent local files match.
  if (change.fileId != null) {
    if (!validIdentity(change.fileId)) throw fail("Invalid file identity.");
    const target = await syncTarget(root, change.path, change.resource ?? "file");
    const current = await entryFor(root, change.path, change.resource ?? "file");
    const catalog = await readCatalog(root, rejectSymlinks);
    const owner = catalog.entries[catalogKey(change)];
    if (Object.values(catalog.entries).some(item => item.fileId === change.fileId && !item.deleted && item.path !== change.path)) {
      return { status: "conflict", entry: current, reason: "file-moved" };
    }
    if (owner && !owner.deleted && owner.fileId !== change.fileId) return { status: "conflict", entry: current && { ...current, fileId: owner.fileId }, reason: "first-registration" };
    if (change.firstRegistration && current) {
      const journal = await readVersionedState(root, change.path, change.resource ?? "file", rejectSymlinks);
      if (!journal?.operations?.some(operation => operation.id === change.operationId)) return { status: "conflict", entry: { ...current, fileId: owner?.fileId }, reason: "first-registration" };
    }
    if (!retry && change.expectedRevision != null && (current?.revision ?? "missing") !== change.expectedRevision) return { status: "conflict", entry: current, reason: "decision-stale" };
    void target;
  }
  const result = await applySyncChangeContent(root, change, staged);
  if (result.status === "applied") await recordCatalogChange(root, change, result.entry, rejectSymlinks);
  return result;
}

async function applySyncChangeContent(root, change, staged = null) {
  const { path: logicalPath, resource = "file", action = "put", baseRevision, conflictPolicy } = change;
  if (conflictPolicy !== undefined && !["merge-latest", "merge-modified-v2"].includes(conflictPolicy)) throw fail("Invalid conflict policy.");
  if (!Object.hasOwn(change, "baseRevision") || (baseRevision !== null && !/^(directory|[a-f0-9]{64})$/.test(baseRevision))) throw fail("A base revision is required.");
  if (!["put", "delete"].includes(action)) throw fail("Invalid sync action.");
  const target = await syncTarget(root, logicalPath, resource);
  let current;
  try { current = await entryFor(root, logicalPath, resource); }
  catch (error) { if (error.status === 409) return { status: "conflict", entry: null }; throw error; }
  if (action === "put" && resource !== "folder" && !staged) throw fail("Missing staged file content.");
  if (conflictPolicy === "merge-modified-v2" && resource !== "folder") {
    if (resource === "annotations" && action === "put") {
      if (staged.size > 16 * 1024 * 1024) throw fail("Annotations exceed 16 MB.", 413);
      const doc = JSON.parse(await fs.readFile(staged.file, "utf8"));
      if (!doc || typeof doc !== "object" || !Array.isArray(doc.pages)) throw fail("Invalid annotation document.");
      validateVersionedAnnotations(doc);
      const document = await syncTarget(root, logicalPath, "file");
      // Older annotation edits must not resurrect a deleted PDF.
      try { if (!(await fs.stat(document.absolutePath)).isFile()) return { status: "conflict", entry: current, reason: "document-missing" }; }
      catch (error) { if (error.code === "ENOENT") return { status: "conflict", entry: current, reason: "document-missing" }; throw error; }
    }
    return applyVersionedChange(root, { ...change, action, resource }, staged, { target, current, rejectSymlinks, entryFor });
  }
  if (resource !== "folder" && await readVersionedState(root, logicalPath, resource, rejectSymlinks)) {
    return { status: "conflict", entry: current, reason: "client-upgrade-required" };
  }
  const desiredRevision = resource === "folder" ? "directory" : staged?.revision;
  // Retries of an already merged upload must not restore stale edits after another writer.
  const receipt = conflictPolicy === "merge-latest" && resource !== "folder" && action === "put"
    ? path.join(root, ".codmes", "sync-receipts", createHash("sha256").update(JSON.stringify([logicalPath, resource, baseRevision, desiredRevision])).digest("hex")) : null;
  if (receipt) {
    await rejectSymlinks(root, receipt);
    try { await fs.access(receipt); return { status: "applied", entry: current }; }
    catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  // Safe retries after a successful write whose response was lost.
  if ((action === "delete" && !current) || (action === "put" && current?.revision === desiredRevision)) {
    return { status: "applied", entry: current };
  }
  const stale = (current?.revision ?? null) !== baseRevision;
  // Structural/delete collisions remain conditional; never recursively erase another device's children.
  if (stale && (conflictPolicy !== "merge-latest" || action === "delete" || resource === "folder")) return { status: "conflict", entry: current };
  if (action === "delete") {
    if (resource === "folder" && (await fs.readdir(target.absolutePath)).length) return { status: "conflict", entry: current };
    const trash = path.join(root, ".codmes", "sync-trash", randomUUID());
    await rejectSymlinks(root, trash);
    await fs.mkdir(trash, { recursive: true, mode: 0o700 });
    await fs.writeFile(path.join(trash, "original.json"), JSON.stringify({ path: logicalPath, resource, deletedAt: new Date().toISOString() }));
    await fs.rename(target.absolutePath, path.join(trash, "content"));
    return { status: "applied", entry: null };
  }
  await fs.mkdir(path.dirname(target.absolutePath), { recursive: true });
  if (resource === "folder") await fs.mkdir(target.absolutePath, { recursive: true });
  else {
    if (resource === "annotations") {
      if (staged.size > 16 * 1024 * 1024) throw fail("Annotations exceed 16 MB.", 413);
      const doc = JSON.parse(await fs.readFile(staged.file, "utf8"));
      if (!doc || typeof doc !== "object" || !Array.isArray(doc.pages)) throw fail("Invalid annotation document.");
      const document = await syncTarget(root, logicalPath, "file");
      if (!(await fs.stat(document.absolutePath)).isFile()) throw fail("Annotation document is missing.", 409);
    }
    if (stale && current) {
      let ancestor = null;
      if (baseRevision) {
        const history = path.join(root, ".codmes", "sync-history", baseRevision);
        await rejectSymlinks(root, history);
        try {
          // Hash-check recovery history before using it as a three-way ancestor.
          if ((await fs.stat(history)).size <= 16 * 1024 * 1024 && await hashFile(history) === baseRevision) ancestor = await fs.readFile(history);
        } catch (error) { if (error.code !== "ENOENT") throw error; }
      }
      if (resource === "annotations" && (ancestor || baseRevision === null) && current.size <= 16 * 1024 * 1024) {
        try {
          const base = ancestor ? JSON.parse(ancestor.toString("utf8")) : { pages: [], objects: [], elements: [] };
          const merged = mergeAnnotations(base, JSON.parse(await fs.readFile(target.absolutePath, "utf8")), JSON.parse(await fs.readFile(staged.file, "utf8")), logicalPath);
          const data = Buffer.from(JSON.stringify(merged));
          if (data.length > 16 * 1024 * 1024) throw fail("Merged annotations exceed 16 MB.", 413);
          await fs.writeFile(staged.file, data);
        } catch (error) { if (error.status) throw error; throw fail(`Invalid annotation merge: ${error.message}`); }
      } else if (resource === "file" && ancestor && staged.size <= 8 * 1024 * 1024 && current.size <= 8 * 1024 * 1024 && /\.(md|markdown|txt|swift|js|mjs|cjs|ts|jsx|tsx|py|go|rs|java|c|cpp|h|cs|html|css|json|yaml|yml|toml|sh|xml|csv)$/i.test(logicalPath)) {
        const decode = new TextDecoder("utf-8", { fatal: true });
        let merged;
        try { merged = mergeText(decode.decode(ancestor), decode.decode(await fs.readFile(target.absolutePath)), decode.decode(await fs.readFile(staged.file))); }
        catch { /* Binary/non-UTF8 content uses arrival-order replacement. */ }
        if (merged !== undefined) await fs.writeFile(staged.file, merged);
      }
      // Binary PDF originals, missing ancestors and oversized text use arrival-order LWW.
      // Structured PDF annotations are a separate resource and merge independently.
    }
    // Preserve the previous revision as well as deleting to a recoverable trash.
    if (current) {
      const history = path.join(root, ".codmes", "sync-history", current.revision);
      await rejectSymlinks(root, history);
      await fs.mkdir(path.dirname(history), { recursive: true, mode: 0o700 });
      await fs.copyFile(target.absolutePath, history);
    }
    await fs.rename(staged.file, target.absolutePath);
  }
  if (receipt) {
    await fs.mkdir(path.dirname(receipt), { recursive: true, mode: 0o700 });
    await fs.writeFile(receipt, JSON.stringify({ appliedAt: new Date().toISOString() }), { mode: 0o600 });
  }
  return { status: "applied", entry: await entryFor(root, logicalPath, resource) };
}

export async function discardStagedSyncUpload(staged) {
  if (staged) await fs.rm(staged.file, { force: true });
}

export async function syncHistory(root, logicalPath, resource = "file", offset = 0) {
  const target = await syncTarget(root, logicalPath, resource);
  const state = await readVersionedState(root, logicalPath, resource, rejectSymlinks);
  await recoverVersionedDocument(root, target, state, rejectSymlinks);
  if (!Number.isSafeInteger(offset) || offset < 0) throw fail("Invalid history offset.");
  return versionedHistory(root, logicalPath, resource, rejectSymlinks, offset);
}

export async function readHistoricalSyncBlob(root, logicalPath, resource, versionId) {
  await syncTarget(root, logicalPath, resource);
  return historicalBlob(root, logicalPath, resource, versionId, rejectSymlinks);
}

export async function snapshotHistoricalSyncBlob(root, logicalPath, resource, versionId) {
  await syncTarget(root, logicalPath, resource);
  const source = await historicalFile(root, logicalPath, resource, versionId, rejectSymlinks);
  const directory = path.join(root, ".codmes", "sync-staging");
  await rejectSymlinks(root, directory);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, randomUUID());
  try { if (await hashFile(source.file) !== source.revision) throw fail("The saved version is damaged.", 409); await fs.copyFile(source.file, file); return { file, size: (await fs.stat(file)).size }; }
  catch (error) { await fs.rm(file, { force: true }); throw error; }
  finally { if (source.temporary) await fs.rm(source.file, { force: true }); }
}

export async function syncRecoveryIndex(root) {
  const entries = [];
  for (const state of await versionedJournals(root, rejectSymlinks)) {
    await syncTarget(root, state.path, state.resource);
    if (state.resource === "file" && state.materializedRevision == null) entries.push({ path: state.path, modifiedAt: state.modifiedAt });
  }
  return { entries };
}

export async function assertLegacyMutationAllowed(root, logicalPath) {
  for (const state of await versionedJournals(root, rejectSymlinks)) {
    if (state.path === logicalPath || state.path.startsWith(logicalPath + "/")) throw fail("This document uses change-based synchronization. Update the client instead of overwriting its history.", 409);
  }
}

export async function isVersionedDocument(root, logicalPath, resource = "file") {
  await syncTarget(root, logicalPath, resource);
  return !!await readVersionedState(root, logicalPath, resource, rejectSymlinks);
}
