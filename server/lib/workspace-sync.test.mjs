import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { syncManifest, stageSyncUpload, applySyncChange, discardStagedSyncUpload, readSyncBlob, snapshotSyncBlob, withWorkspaceFileLock } from "./workspace-sync.mjs";

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-sync-test-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, "Notes")); await fs.mkdir(path.join(root, "Code"));
  return root;
}
async function put(root, content, baseRevision = null, file = "Notes/book.md", resource = "file", conflictPolicy) {
  const staged = await stageSyncUpload(root, Readable.from([Buffer.from(content)]));
  try { return await withWorkspaceFileLock(root, () => applySyncChange(root, { path: file, resource, baseRevision, conflictPolicy }, staged)); }
  finally { await discardStagedSyncUpload(staged); }
}

test("two devices exchange Notes and retry writes without overwriting a conflict", async (t) => {
  const root = await fixture(t);
  const created = await put(root, "phone version");
  assert.equal(created.status, "applied");
  const first = (await syncManifest(root)).entries[0];
  assert.equal((await readSyncBlob(root, first.path, first.resource, first.revision)).toString(), "phone version");
  const updated = await put(root, "tablet version", first.revision);
  assert.equal(updated.status, "applied");
  const retry = await put(root, "tablet version", first.revision);
  assert.equal(retry.status, "applied");
  const conflict = await put(root, "offline phone version", first.revision);
  assert.equal(conflict.status, "conflict");
  assert.equal(await fs.readFile(path.join(root, "Notes/book.md"), "utf8"), "tablet version");
  await assert.rejects(readSyncBlob(root, first.path, first.resource, first.revision), (error) => error.status === 409);
});

test("merge-latest preserves disjoint lines, replaces the overlapping line and creates no copies", async (t) => {
  const root = await fixture(t);
  const base = await put(root, "a\nb\nc\n");
  await put(root, "phone\nB\nc\n", base.entry.revision, "Notes/book.md", "file", "merge-latest");
  const result = await put(root, "a\nlatest B\nC\n", base.entry.revision, "Notes/book.md", "file", "merge-latest");
  assert.equal(result.status, "applied");
  assert.equal(await fs.readFile(path.join(root, "Notes/book.md"), "utf8"), "phone\nlatest B\nC\n");
  assert.equal((await syncManifest(root)).entries.length, 1);
  assert.equal(await fs.readFile(path.join(root, ".codmes/sync-history", base.entry.revision), "utf8"), "a\nb\nc\n");
});

test("merged retry after another device's edit does not apply the old edit again", async (t) => {
  const root = await fixture(t);
  const base = await put(root, "a\nb\n");
  await put(root, "A\nb\n", base.entry.revision, "Notes/book.md", "file", "merge-latest");
  const merged = await put(root, "a\nB\n", base.entry.revision, "Notes/book.md", "file", "merge-latest");
  const latest = await put(root, "A\nlatest\n", merged.entry.revision, "Notes/book.md", "file", "merge-latest");
  const retry = await put(root, "a\nB\n", base.entry.revision, "Notes/book.md", "file", "merge-latest");
  assert.equal(retry.entry.revision, latest.entry.revision);
  assert.equal(await fs.readFile(path.join(root, "Notes/book.md"), "utf8"), "A\nlatest\n");
});

test("retry after a later deletion acknowledges absence instead of resurrecting a file", async (t) => {
  const root = await fixture(t);
  const saved = await put(root, "saved", null, "Notes/book.md", "file", "merge-latest");
  await applySyncChange(root, { path: "Notes/book.md", resource: "file", action: "delete", baseRevision: saved.entry.revision });
  const retry = await put(root, "saved", null, "Notes/book.md", "file", "merge-latest");
  assert.equal(retry.status, "applied"); assert.equal(retry.entry, null);
  assert.equal((await syncManifest(root)).entries.length, 0);
});

test("PDF binary uses latest arrival while annotations merge object additions on the same page", async (t) => {
  const root = await fixture(t);
  const pdf = await put(root, "%PDF base", null, "Notes/book.pdf");
  await put(root, "%PDF phone", pdf.entry.revision, "Notes/book.pdf", "file", "merge-latest");
  await put(root, "%PDF latest tablet", pdf.entry.revision, "Notes/book.pdf", "file", "merge-latest");
  assert.equal(await fs.readFile(path.join(root, "Notes/book.pdf"), "utf8"), "%PDF latest tablet");
  const body = pages => JSON.stringify({ schemaVersion: 2, pages, objects: [] });
  const base = await put(root, body([{ pageIndex: 0, objects: [] }]), null, "Notes/book.pdf", "annotations");
  await put(root, body([{ pageIndex: 0, objects: [{ id: "a", text: "phone" }] }]), base.entry.revision, "Notes/book.pdf", "annotations", "merge-latest");
  const result = await put(root, body([{ pageIndex: 0, objects: [{ id: "b", text: "tablet" }] }]), base.entry.revision, "Notes/book.pdf", "annotations", "merge-latest");
  const merged = JSON.parse(await readSyncBlob(root, "Notes/book.pdf", "annotations", result.entry.revision));
  assert.deepEqual(merged.pages[0].objects.map(o => o.id), ["a", "b"]);
  assert.equal((await syncManifest(root)).entries.length, 2);
});

test("simultaneous writes with the same base allow exactly one winner", async (t) => {
  const root = await fixture(t);
  const created = await put(root, "base");
  const results = await Promise.all([put(root, "device A", created.entry.revision), put(root, "device B", created.entry.revision)]);
  assert.deepEqual(results.map((value) => value.status).sort(), ["applied", "conflict"]);
});

test("download snapshots stay immutable when another device changes the original", async (t) => {
  const root = await fixture(t);
  const created = await put(root, "snapshot content");
  const snapshot = await withWorkspaceFileLock(root, () => snapshotSyncBlob(root, created.entry.path, "file", created.entry.revision));
  try {
    await put(root, "new content", created.entry.revision);
    assert.equal(await fs.readFile(snapshot.file, "utf8"), "snapshot content");
    await assert.rejects(snapshotSyncBlob(root, created.entry.path, "file", created.entry.revision), { status: 409 });
  } finally { await discardStagedSyncUpload(snapshot); }
  assert.deepEqual(await fs.readdir(path.join(root, ".codmes/sync-staging")), []);
});

test("deletions retain recovery data and cannot erase changed or nonempty folders", async (t) => {
  const root = await fixture(t);
  const created = await put(root, "keep me");
  await put(root, "updated remotely", created.entry.revision);
  const staleDelete = await applySyncChange(root, { path: created.entry.path, resource: "file", action: "delete", baseRevision: created.entry.revision });
  assert.equal(staleDelete.status, "conflict");
  const latest = (await syncManifest(root)).entries[0];
  const deleted = await applySyncChange(root, { path: latest.path, action: "delete", resource: "file", baseRevision: latest.revision });
  assert.equal(deleted.status, "applied");
  const trash = await fs.readdir(path.join(root, ".codmes/sync-trash"));
  assert.equal(await fs.readFile(path.join(root, ".codmes/sync-trash", trash[0], "content"), "utf8"), "updated remotely");
  await applySyncChange(root, { path: "Notes/folder", resource: "folder", baseRevision: null });
  await put(root, "new remote child", null, "Notes/folder/new.md");
  assert.equal((await applySyncChange(root, { path: "Notes/folder", resource: "folder", action: "delete", baseRevision: "directory" })).status, "conflict");
});

test("account roots, internal files and symlinks are isolated", async (t) => {
  const a = await fixture(t), b = await fixture(t);
  await put(a, "A private data");
  assert.equal((await syncManifest(b)).entries.length, 0);
  for (const invalid of ["../outside", "Notes/../Code/secret", ".codmes/accounts", "Notes/.codmes/secret", "Notes/.git/config", "Notes//x"]) {
    await assert.rejects(put(a, "bad", null, invalid), (error) => error.status === 400);
  }
  await fs.symlink(b, path.join(a, "Notes/link"));
  await assert.rejects(put(a, "bad", null, "Notes/link/stolen.md"), (error) => error.status === 400);
  assert.ok(!(await syncManifest(a)).entries.some((entry) => entry.path.includes("link")));
});

test("PDF annotation sidecars synchronize independently from the PDF binary", async (t) => {
  const root = await fixture(t);
  await put(root, "%PDF fake fixture", null, "Notes/book.pdf");
  const body = JSON.stringify({ schemaVersion: 2, documentPath: "Notes/book.pdf", pages: [], objects: [] });
  const saved = await put(root, body, null, "Notes/book.pdf", "annotations");
  assert.equal(saved.status, "applied");
  const entries = (await syncManifest(root)).entries;
  assert.equal(entries.length, 2);
  assert.equal(entries.filter((entry) => entry.resource === "annotations").length, 1);
});
