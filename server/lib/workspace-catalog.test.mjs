import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { spawn } from "node:child_process";
import { syncManifest, applySyncChange, applySyncMove, stageSyncBundle, applySyncBundle, discardSyncBundle, syncDevicePolicies, withWorkspaceFileLock, stageSyncUpload, discardStagedSyncUpload } from "./workspace-sync.mjs";
import { annotationFingerprint } from "./workspace-catalog.mjs";

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-catalog-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, "Notes")); await fs.mkdir(path.join(root, "Code")); return root;
}
async function put(root, content, options = {}) {
  const staged = await stageSyncUpload(root, Readable.from([Buffer.from(content)]));
  try {
    return await withWorkspaceFileLock(root, () => applySyncChange(root, {
      path: "Notes/book.md", resource: "file", action: "put", baseRevision: null,
      conflictPolicy: "merge-modified-v2", operationId: randomUUID(), deviceId: "catalog-test-device", modifiedAt: new Date().toISOString(), ...options
    }, staged));
  } finally { await discardStagedSyncUpload(staged); }
}
test("catalog IDs persist across scans and workspace restart and isolate profiles", async t => {
  const root = await fixture(t), other = await fixture(t);
  await put(root, "book");
  const first = await withWorkspaceFileLock(root, () => syncManifest(root));
  const second = await withWorkspaceFileLock(root, () => syncManifest(root));
  assert.equal(first.entries[0].fileId, second.entries[0].fileId);
  assert.equal(first.serverId, second.serverId); assert.equal(first.catalogRevision, second.catalogRevision);
  assert.equal((await syncManifest(other)).entries.length, 0);
});
test("independent first registration cannot overwrite a same-name book", async t => {
  const root = await fixture(t), phoneId = randomUUID(), macId = randomUUID();
  const original = await put(root, "phone book", { fileId: phoneId, firstRegistration: true });
  const rejected = await put(root, "mac book", { fileId: macId, firstRegistration: true });
  assert.equal(rejected.status, "conflict"); assert.equal(rejected.reason, "first-registration");
  assert.equal(await fs.readFile(path.join(root, "Notes/book.md"), "utf8"), "phone book");
  assert.equal(original.entry.fileId, phoneId);
});
test("legacy native clients also cannot blindly overwrite unrelated first contents", async t => {
  const root = await fixture(t);
  await put(root, "phone"); const rejected = await put(root, "tablet");
  assert.equal(rejected.reason, "first-registration"); assert.equal(await fs.readFile(path.join(root, "Notes/book.md"), "utf8"), "phone");
});
test("simultaneous first uploads allow exactly one durable registration", async t => {
  const root = await fixture(t);
  const results = await Promise.all([put(root, "A", { fileId: randomUUID(), firstRegistration: true }), put(root, "B", { fileId: randomUUID(), firstRegistration: true })]);
  assert.deepEqual(results.map(result => result.status).sort(), ["applied", "conflict"]);
  assert.equal((await syncManifest(root)).entries.length, 1);
});
test("conditional user decisions are invalidated by a newer server edit", async t => {
  const root = await fixture(t), fileId = randomUUID(); const first = await put(root, "base", { fileId });
  await put(root, "new", { fileId, baseRevision: first.entry.revision, baseVersion: first.entry.versionId });
  const stale = await put(root, "replace", { fileId, baseRevision: first.entry.revision, baseVersion: first.entry.versionId, expectedRevision: first.entry.revision });
  assert.equal(stale.reason, "decision-stale"); assert.equal(await fs.readFile(path.join(root, "Notes/book.md"), "utf8"), "new");
});
test("a successful conditional write can retry after its acknowledgement is lost", async t => {
  const root = await fixture(t), fileId = randomUUID(); const first = await put(root, "base", { fileId });
  const change = { fileId, operationId: randomUUID(), modifiedAt: new Date().toISOString(), baseRevision: first.entry.revision, baseVersion: first.entry.versionId, expectedRevision: first.entry.revision };
  assert.equal((await put(root, "replacement", change)).status, "applied");
  assert.equal((await put(root, "replacement", change)).status, "applied");
});
test("identity-preserving move retains causal merge bases and retries safely", async t => {
  const root = await fixture(t), fileId = randomUUID(); const first = await put(root, "base", { fileId });
  const move = { from: "Notes/book.md", to: "Code/renamed.md", fileId, expectedRevision: first.entry.revision };
  assert.equal((await withWorkspaceFileLock(root, () => applySyncMove(root, move))).status, "applied");
  assert.equal((await withWorkspaceFileLock(root, () => applySyncMove(root, move))).status, "applied");
  const updated = await put(root, "edited", { path: move.to, fileId, baseRevision: first.entry.revision, baseVersion: first.entry.versionId });
  assert.equal(updated.status, "applied"); assert.equal(updated.entry.fileId, fileId);
  const manifest = await syncManifest(root); assert.equal(manifest.entries.length, 1); assert.equal(manifest.entries[0].path, move.to);
  assert.equal(await fs.readFile(path.join(root, move.to), "utf8"), "edited");
});
test("move into an occupied path is rejected without touching either file", async t => {
  const root = await fixture(t), fileId = randomUUID(); const first = await put(root, "book", { fileId });
  await put(root, "other", { path: "Code/other.md" });
  const result = await withWorkspaceFileLock(root, () => applySyncMove(root, { from: "Notes/book.md", to: "Code/other.md", fileId, expectedRevision: first.entry.revision }));
  assert.equal(result.reason, "destination-exists");
  assert.equal(await fs.readFile(path.join(root, "Code/other.md"), "utf8"), "other");
});
test("reusing a moved-away name needs a new creation base and preserves the moved document", async t => {
  const root = await fixture(t), originalId = randomUUID();
  const first = await put(root, "original", { fileId: originalId, firstRegistration: true });
  const move = { from: "Notes/book.md", to: "Code/moved.md", fileId: originalId, expectedRevision: first.entry.revision };
  await withWorkspaceFileLock(root, () => applySyncMove(root, move));
  const tombstone = (await syncManifest(root)).deletedEntries.find(entry => entry.path === move.from && entry.resource === "file");
  assert.match(tombstone.versionId, /^move_/);
  const newId = randomUUID();
  const invalid = await put(root, "independent", { fileId: newId, firstRegistration: true, baseVersion: tombstone.versionId });
  assert.equal(invalid.reason, "base-missing");
  const created = await put(root, "independent", { fileId: newId, firstRegistration: true, baseVersion: null });
  assert.equal(created.status, "applied");
  assert.equal(created.entry.fileId, newId);
  assert.equal(await fs.readFile(path.join(root, move.from), "utf8"), "independent");
  assert.equal(await fs.readFile(path.join(root, move.to), "utf8"), "original");
  const collision = await put(root, "must not replace", { fileId: randomUUID(), firstRegistration: true, baseVersion: null });
  assert.equal(collision.reason, "first-registration");
  assert.equal(await fs.readFile(path.join(root, move.from), "utf8"), "independent");
});
test("device policies are independent and survive reload without storing local-only paths", async t => {
  const root = await fixture(t); const first = await put(root, "book"); const phone = randomUUID(), tablet = randomUUID();
  await withWorkspaceFileLock(root, () => syncDevicePolicies(root, phone, [{ fileId: first.entry.fileId, mode: "local" }]));
  await withWorkspaceFileLock(root, () => syncDevicePolicies(root, tablet, [{ fileId: first.entry.fileId, mode: "server" }]));
  const result = await syncDevicePolicies(root);
  assert.equal(result.devices[phone].policies[first.entry.fileId].mode, "local");
  assert.equal(result.devices[tablet].policies[first.entry.fileId].mode, "server");
  await assert.rejects(syncDevicePolicies(root, phone, [{ fileId: randomUUID(), mode: "sync" }]), { status: 400 });
  assert.ok(!JSON.stringify(result).includes("Notes/"));
});
test("PDF fingerprints include ink and ignore transport-only metadata", () => {
  const first = { schemaVersion: 2, documentPath: "Notes/a.pdf", updatedAt: "a", pages: [{ pageIndex: 0, objects: [{ id: "a", text: "ink" }] }] };
  const second = structuredClone(first); second.documentPath = "Notes/b.pdf"; second.updatedAt = "b";
  assert.equal(annotationFingerprint(first), annotationFingerprint(second));
  second.pages[0].objects[0].text = "different ink"; assert.notEqual(annotationFingerprint(first), annotationFingerprint(second));
  assert.equal(annotationFingerprint({ schemaVersion: 2, pages: [], objects: [] }), "none");
});
async function bundle(root, pdf, ink, options = {}) {
  const identity = options.fileId ?? randomUUID(), time = new Date().toISOString();
  const common = { path: "Notes/book.pdf", action: "put", baseRevision: null, conflictPolicy: "merge-modified-v2", deviceId: "bundle-test", modifiedAt: time, fileId: identity };
  const original = Buffer.from(pdf), annotations = Buffer.from(JSON.stringify(ink));
  const header = Buffer.from(JSON.stringify({ fileChange: { ...common, resource: "file", operationId: randomUUID(), ...options.fileChange }, annotationChange: { ...common, resource: "annotations", operationId: randomUUID(), ...options.annotationChange }, fileSize: original.length, annotationSize: annotations.length }));
  const length = Buffer.alloc(4); length.writeUInt32BE(header.length);
  return stageSyncBundle(root, Readable.from([length, header, original, annotations]));
}
test("PDF first registration publishes original and ink together and retries as one receipt", async t => {
  const root = await fixture(t), ink = { schemaVersion: 2, pages: [{ pageIndex: 0, objects: [{ id: "text", text: "hello" }] }] };
  const staged = await bundle(root, "%PDF-original", ink); t.after(() => discardSyncBundle(staged));
  assert.equal((await withWorkspaceFileLock(root, () => applySyncBundle(root, staged))).status, "applied");
  assert.equal((await withWorkspaceFileLock(root, () => applySyncBundle(root, staged))).status, "applied");
  const manifest = await withWorkspaceFileLock(root, () => syncManifest(root));
  assert.equal(manifest.entries.filter(e => e.path === "Notes/book.pdf").length, 2);
  assert.equal(manifest.entries.find(e => e.resource === "file").annotationFingerprint, annotationFingerprint(ink));
});
test("two first PDF uploads do not mix either originals or annotations", async t => {
  const root = await fixture(t), ink = name => ({ schemaVersion: 2, pages: [{ pageIndex: 0, objects: [{ id: "text", text: name }] }] });
  const a = await bundle(root, "%PDF-A", ink("A")), b = await bundle(root, "%PDF-B", ink("B")); t.after(async () => { await discardSyncBundle(a); await discardSyncBundle(b); });
  const results = await Promise.all([a, b].map(value => withWorkspaceFileLock(root, () => applySyncBundle(root, value))));
  assert.deepEqual(results.map(r => r.status).sort(), ["applied", "conflict"]);
  const winner = results[0].status === "applied" ? "A" : "B";
  const manifest = await withWorkspaceFileLock(root, () => syncManifest(root));
  assert.equal(await fs.readFile(path.join(root, "Notes/book.pdf"), "utf8"), `%PDF-${winner}`);
  assert.equal(manifest.entries.find(e => e.resource === "file").annotationFingerprint, annotationFingerprint(ink(winner)));
});
test("PDF replacement conditions both revisions and can explicitly clear old ink", async t => {
  const root = await fixture(t), first = await bundle(root, "%PDF-A", { schemaVersion: 2, pages: [{ pageIndex: 0, objects: [{ id: "text", text: "A" }] }] }); t.after(() => discardSyncBundle(first));
  await withWorkspaceFileLock(root, () => applySyncBundle(root, first));
  const manifest = await syncManifest(root), original = manifest.entries.find(e => e.resource === "file"), ink = manifest.entries.find(e => e.resource === "annotations");
  const replacement = await bundle(root, "%PDF-B", { schemaVersion: 2, pages: [], objects: [] }, { fileId: original.fileId, fileChange: { baseRevision: original.revision, baseVersion: original.versionId, expectedRevision: original.revision }, annotationChange: { baseRevision: ink.revision, baseVersion: ink.versionId, expectedRevision: ink.revision } }); t.after(() => discardSyncBundle(replacement));
  assert.equal((await withWorkspaceFileLock(root, () => applySyncBundle(root, replacement))).status, "applied");
  assert.equal((await syncManifest(root)).entries.find(e => e.resource === "file").annotationFingerprint, "none");
  const stale = await bundle(root, "%PDF-C", { schemaVersion: 2, pages: [] }, { fileId: original.fileId, fileChange: { baseRevision: original.revision, baseVersion: original.versionId }, annotationChange: { baseRevision: ink.revision, baseVersion: ink.versionId } }); t.after(() => discardSyncBundle(stale));
  assert.equal((await withWorkspaceFileLock(root, () => applySyncBundle(root, stale))).reason, "decision-stale");
  assert.equal(await fs.readFile(path.join(root, "Notes/book.pdf"), "utf8"), "%PDF-B");
});
test("truncated bundles never register any file", async t => {
  const root = await fixture(t); await assert.rejects(stageSyncBundle(root, Readable.from([Buffer.from([0, 0, 0, 9]), Buffer.from("{}")])));
  assert.equal((await syncManifest(root)).entries.length, 0);
});
test("committed PDF transaction recovers after termination before the next reader", async t => {
  const root = await fixture(t), staged = await bundle(root, "%PDF-recover", { schemaVersion: 2, pages: [] }); t.after(() => discardSyncBundle(staged));
  const id = randomUUID(), directory = path.join(root, ".codmes", "sync-bundles", id); await fs.mkdir(directory, { recursive: true });
  for (let index = 0; index < 2; index++) await fs.copyFile(staged.parts[index].file, path.join(directory, String(index)));
  await fs.writeFile(path.join(root, ".codmes", "sync-bundle.json"), JSON.stringify({ id, changes: [staged.header.fileChange, staged.header.annotationChange], parts: staged.parts.map(({ revision, size }) => ({ revision, size })) }));
  const manifest = await withWorkspaceFileLock(root, () => syncManifest(root));
  assert.equal(manifest.entries.filter(e => e.path === "Notes/book.pdf").length, 2);
  assert.equal(await fs.readFile(path.join(root, "Notes/book.pdf"), "utf8"), "%PDF-recover");
  await assert.rejects(fs.access(path.join(root, ".codmes", "sync-bundle.json")), { code: "ENOENT" });
});
test("explicit PDF replacement also accepts a legacy external original as its base", async t => {
  const root = await fixture(t); await fs.writeFile(path.join(root, "Notes/book.pdf"), "%PDF-legacy");
  const original = (await syncManifest(root)).entries.find(e => e.resource === "file");
  const staged = await bundle(root, "%PDF-new", { schemaVersion: 2, pages: [] }, { fileId: original.fileId, fileChange: { baseRevision: original.revision, baseVersion: `legacy:${original.revision}`, expectedRevision: original.revision } }); t.after(() => discardSyncBundle(staged));
  assert.equal((await withWorkspaceFileLock(root, () => applySyncBundle(root, staged))).status, "applied");
});
test("writer lock prevents independent server processes from registering both paths", async t => {
  const root = await fixture(t); const moduleURL = new URL("./workspace-sync.mjs", import.meta.url).href;
  const program = `import {Readable} from 'node:stream'; import {randomUUID} from 'node:crypto'; import {withWorkspaceFileLock,stageSyncUpload,applySyncChange,discardStagedSyncUpload} from ${JSON.stringify(moduleURL)};
    const root=process.argv[1], bytes=process.argv[2], staged=await stageSyncUpload(root,Readable.from([bytes]));
    try { const result=await withWorkspaceFileLock(root,()=>applySyncChange(root,{path:'Notes/book.md',resource:'file',baseRevision:null,conflictPolicy:'merge-modified-v2',operationId:randomUUID(),deviceId:'process-test',modifiedAt:new Date().toISOString(),fileId:randomUUID(),firstRegistration:true},staged)); process.stdout.write(result.status); } finally {await discardStagedSyncUpload(staged);}`;
  const run = bytes => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--input-type=module", "-e", program, root, bytes]); let out = "", err = "";
    child.stdout.on("data", chunk => out += chunk); child.stderr.on("data", chunk => err += chunk);
    child.on("error", reject); child.on("close", code => code === 0 ? resolve(out) : reject(new Error(err)));
  });
  assert.deepEqual((await Promise.all([run("A"), run("B")])).sort(), ["applied", "conflict"]);
});
