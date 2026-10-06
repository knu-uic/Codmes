import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { applySyncChange, stageSyncUpload, discardStagedSyncUpload, syncManifest, syncHistory, readHistoricalSyncBlob, withWorkspaceFileLock } from "./workspace-sync.mjs";
import { mergeText, mergeAnnotationsPrecise } from "./workspace-merge.mjs";
import { validateVersionedAnnotations } from "./workspace-versioned.mjs";

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-v2-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.mkdir(path.join(root, "Notes")); await fs.mkdir(path.join(root, "Code"));
  return root;
}
const time = n => new Date(Date.UTC(2026, 0, 1, 0, 0, n)).toISOString();
const operation = (entry, n, deviceId = "iPhone", extra = {}) => ({ path: "Notes/book.md", resource: "file", action: "put", conflictPolicy: "merge-modified-v2", operationId: randomUUID(), deviceId, modifiedAt: time(n), baseRevision: entry?.revision ?? null, baseVersion: entry?.versionId ?? (entry ? `legacy:${entry.revision}` : null), ...extra });
async function apply(root, change, content) {
  const staged = change.action === "put" ? await stageSyncUpload(root, Readable.from([Buffer.from(content)])) : null;
  try { return await withWorkspaceFileLock(root, () => applySyncChange(root, change, staged)); }
  finally { await discardStagedSyncUpload(staged); }
}
const read = root => fs.readFile(path.join(root, "Notes/book.md"), "utf8");

test("precise text merge preserves different words, Korean, emoji and CRLF", () => {
  const merge = (a, b, c) => mergeText(a, b, c, { precise: true });
  assert.equal(merge("red cat\n", "blue cat\n", "red dog\n"), "blue dog\n");
  assert.equal(merge("안녕하세요 친구 👩🏽‍💻\r\n", "반갑습니다 친구 👩🏽‍💻\r\n", "안녕하세요 동료 👩🏽‍💻\r\n"), "반갑습니다 동료 👩🏽‍💻\r\n");
  assert.equal(merge("hello\n", "hello!\n", "hello?\n"), "hello!?\n");
  assert.equal(merge("same\n", "phone\n", "tablet\n"), "tablet\n");
});

test("local modification order wins regardless of network arrival; disjoint words survive", async t => {
  for (const order of [[1, 2], [2, 1]]) {
    const root = await fixture(t);
    const base = (await apply(root, operation(null, 0), "red cat\n")).entry;
    const changes = { 1: [operation(base, 10, "Android"), "blue cat\n"], 2: [operation(base, 20, "Windows"), "red dog\n"] };
    for (const id of order) await apply(root, ...changes[id]);
    assert.equal(await read(root), "blue dog\n");
    const old = operation(base, 5, "iPad");
    await apply(root, old, "green cat\n");
    assert.equal(await read(root), "blue dog\n");
    assert.equal((await syncManifest(root)).entries.filter(e => !e.isDirectory).length, 1);
  }
});

test("each offline save keeps its own time, original base and content", async t => {
  const root = await fixture(t);
  const base = (await apply(root, operation(null, 0), "a\nb\nc\n")).entry;
  const morning = operation(base, 10, "phone");
  const first = await apply(root, morning, "morning\nb\nc\n");
  await apply(root, operation(base, 20, "tablet"), "tablet\nB\nc\n");
  // The phone's second offline edit is based on its ORIGINAL first snapshot,
  // not the server's merged acknowledgement.
  const evening = operation(first.entry, 30, "phone", { baseRevision: first.entry.revision, baseVersion: morning.operationId });
  await apply(root, evening, "morning\nb\nevening\n");
  assert.equal(await read(root), "tablet\nB\nevening\n");
});

test("same property chooses newest local edit and independent PDF attributes merge", async t => {
  const root = await fixture(t);
  await apply(root, operation(null, 0, "Mac", { path: "Notes/book.pdf" }), "%PDF original");
  const doc = { schemaVersion: 2, pages: [{ pageIndex: 0, objects: [{ id: "box", text: "base", bbox: { x: .1, y: .2, width: .3, height: .1 }, metadata: { color: "black" } }], inkStrokes: [] }], objects: [] };
  const initial = operation(null, 0, "Mac", { path: "Notes/book.pdf", resource: "annotations" });
  const base = (await apply(root, initial, JSON.stringify(doc))).entry;
  const move = structuredClone(doc); move.pages[0].objects[0].bbox.x = .7; move.pages[0].inkStrokes.push({ id: "android-ink", points: [{ x: .1, y: .2, pressure: .5 }] });
  const text = structuredClone(doc); text.pages[0].objects[0].text = "latest text"; text.pages[0].objects[0].metadata.color = "red";
  const changes = [operation(base, 20, "Windows", { path: "Notes/book.pdf", resource: "annotations" }), operation(base, 10, "Android", { path: "Notes/book.pdf", resource: "annotations" })];
  await apply(root, changes[0], JSON.stringify(text)); await apply(root, changes[1], JSON.stringify(move));
  const entry = (await syncManifest(root)).entries.find(e => e.resource === "annotations");
  const history = await syncHistory(root, "Notes/book.pdf", "annotations");
  const merged = JSON.parse(await readHistoricalSyncBlob(root, "Notes/book.pdf", "annotations", entry.versionId));
  const box = merged.pages[0].objects[0];
  assert.equal(box.text, "latest text"); assert.equal(box.bbox.x, .7); assert.equal(box.bbox.y, .2); assert.equal(box.metadata.color, "red");
  assert.equal(merged.pages[0].inkStrokes[0].id, "android-ink");
  assert.ok(history.entries.some(e => e.original));
});

test("stable page IDs preserve annotations across a page reordering", () => {
  const before = { pages: [{ pageId: "p1", pageIndex: 0, objects: [{ id: "box", text: "base" }] }, { pageId: "p2", pageIndex: 1, objects: [] }], objects: [] };
  const current = structuredClone(before), incoming = structuredClone(before);
  current.pages[0].pageIndex = 1; current.pages[1].pageIndex = 0;
  incoming.pages[0].objects[0].text = "edited on phone";
  const merged = mergeAnnotationsPrecise(before, current, incoming, "Notes/a.pdf", time(5));
  assert.equal(merged.pages[1].pageId, "p1"); assert.equal(merged.pages[1].objects[0].text, "edited on phone");
});

test("delete tombstones prevent late older edits from resurrecting a document; history can restore", async t => {
  const root = await fixture(t);
  const base = (await apply(root, operation(null, 0), "base")).entry;
  const deletion = operation(base, 30, "Windows", { action: "delete" });
  await apply(root, deletion);
  const late = await apply(root, operation(base, 20, "Android"), "older offline edit");
  assert.equal(late.entry, null);
  assert.equal((await syncManifest(root)).entries.length, 0);
  const history = await syncHistory(root, "Notes/book.md");
  const original = history.entries.find(e => e.revision === base.revision && !e.deleted);
  assert.ok(original);
  const saved = await readHistoricalSyncBlob(root, "Notes/book.md", "file", original.versionId);
  await apply(root, operation(null, 40, "iPhone"), saved);
  assert.equal(await read(root), "base");
});

test("retries are idempotent across intervening updates and reused IDs are rejected", async t => {
  const root = await fixture(t);
  const base = (await apply(root, operation(null, 0), "base")).entry;
  const old = operation(base, 10); await apply(root, old, "old");
  const latest = operation(base, 20, "iPad"); await apply(root, latest, "latest");
  await apply(root, old, "old"); assert.equal(await read(root), "latest");
  await assert.rejects(apply(root, old, "different"), { status: 400 });
});

test("causal edits override their observed base even if the device clock moved backwards", async t => {
  const root = await fixture(t);
  const base = (await apply(root, operation(null, 30), "base")).entry;
  await apply(root, operation(base, 10, "Android"), "causal successor");
  assert.equal(await read(root), "causal successor");
});

test("history is document/profile scoped and traversal or unavailable bases are rejected", async t => {
  const a = await fixture(t), b = await fixture(t);
  const entry = (await apply(a, operation(null, 0), "private")).entry;
  await assert.rejects(readHistoricalSyncBlob(b, "Notes/book.md", "file", entry.versionId), { status: 404 });
  await assert.rejects(readHistoricalSyncBlob(a, "Notes/../Code/private", "file", entry.versionId), { status: 400 });
  const unknown = operation({ revision: "0".repeat(64), versionId: "1".repeat(64) }, 5);
  assert.equal((await apply(a, unknown, "pending")).reason, "base-missing");
  assert.equal(await read(a), "private");
});

test("a client without the new policy cannot bypass an already managed document", async t => {
  const root = await fixture(t);
  const entry = (await apply(root, operation(null, 0), "managed")).entry;
  const result = await apply(root, { path: "Notes/book.md", resource: "file", action: "put", baseRevision: entry.revision, conflictPolicy: "merge-latest" }, "old protocol");
  assert.equal(result.reason, "client-upgrade-required"); assert.equal(await read(root), "managed");
});

test("future-clock uploads and invalid operation IDs retain the original file", async t => {
  const root = await fixture(t);
  const entry = (await apply(root, operation(null, 0), "safe")).entry;
  await assert.rejects(apply(root, operation(entry, 5, "iPad", { modifiedAt: "2099-01-01T00:00:00Z" }), "bad clock"), { status: 409 });
  await assert.rejects(apply(root, operation(entry, 5, "iPad", { operationId: "../escape" }), "bad ID"), { status: 400 });
  assert.equal(await read(root), "safe");
});

test("all arrival permutations including equal timestamps converge to one version", async t => {
  const permutations = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]];
  let expectedVersion;
  const ids = [randomUUID(), randomUUID(), randomUUID()]; const seedId = randomUUID();
  for (const order of permutations) {
    const root = await fixture(t);
    const base = (await apply(root, operation(null, 0, "seed", { operationId: seedId }), "red cat runs\n")).entry;
    const changes = [
      [operation(base, 10, "Android", { operationId: ids[0] }), "blue cat runs\n"],
      [operation(base, 10, "Windows", { operationId: ids[1] }), "red dog runs\n"],
      [operation(base, 20, "iPad", { operationId: ids[2] }), "red cat jumps\n"]
    ];
    for (const index of order) await apply(root, ...changes[index]);
    assert.equal(await read(root), "blue dog jumps\n");
    const entry = (await syncManifest(root)).entries[0];
    expectedVersion ??= entry.versionId; assert.equal(entry.versionId, expectedVersion);
  }
});

test("committed projection intent survives restart; corrupted recovery blob is rejected", async t => {
  const root = await fixture(t);
  const base = (await apply(root, operation(null, 0), "saved")).entry;
  const journals = await fs.readdir(path.join(root, ".codmes", "sync-v2"));
  const file = path.join(root, ".codmes", "sync-v2", journals[0], "state.json");
  const state = JSON.parse(await fs.readFile(file)); state.pendingProjection = true;
  await fs.writeFile(file, JSON.stringify(state)); await fs.unlink(path.join(root, "Notes/book.md"));
  assert.equal((await syncManifest(root)).entries[0].revision, base.revision);
  assert.equal(await read(root), "saved");
  state.pendingProjection = true; await fs.writeFile(file, JSON.stringify(state));
  const saved = JSON.parse(await fs.readFile(path.join(root, ".codmes", "sync-bases", "revisions", base.revision)));
  await fs.writeFile(path.join(root, ".codmes", "sync-bases", "blocks", saved.blocks[0]), "corrupted");
  await assert.rejects(syncManifest(root), { status: 409 });
  assert.equal(await read(root), "saved");
});

test("PDF deleted entities stay deleted and structural page collisions stay pending", () => {
  const base = { pages: [{ pageId: "p1", pageIndex: 0, objects: [{ id: "box", text: "base", metadata: { color: "black" } }], inkStrokes: [] }], objects: [] };
  const older = structuredClone(base), newer = structuredClone(base);
  older.pages[0].objects[0].metadata.color = "red"; newer.pages[0].objects = [];
  const merged = mergeAnnotationsPrecise(base, older, newer, "Notes/book.pdf", time(20));
  assert.equal(merged.pages[0].objects.length, 0);
  assert.throws(() => validateVersionedAnnotations({ pages: [{ pageId: "p1", pageIndex: 0 }, { pageId: "p2", pageIndex: 0 }] }), { status: 400 });
});

test("bounded projection metadata still merges old offline bases and preserves retries", async t => {
  const root = await fixture(t), seed = operation(null, 0), base = (await apply(root, seed, "red cat\n")).entry;
  let current = base;
  for (let n = 1; n <= 25; n++) current = (await apply(root, operation(current, n), `red dog${n}\n`)).entry;
  const offline = operation(base, 26, "old-offline-device");
  await apply(root, offline, "blue cat\n"); assert.equal(await read(root), "blue dog25\n");
  await apply(root, offline, "blue cat\n"); assert.equal(await read(root), "blue dog25\n");
  const journals = await fs.readdir(path.join(root, ".codmes", "sync-v2"));
  const saved = JSON.parse(await fs.readFile(path.join(root, ".codmes", "sync-v2", journals[0], "state.json")));
  assert.equal(saved.snapshots.length, 1);
  assert.equal(saved.operations.length, 27);
  assert.equal((await readHistoricalSyncBlob(root, "Notes/book.md", "file", seed.operationId)).toString(), "red cat\n");
});

test("long-lived autosave documents no longer stop at ten thousand edits", async t => {
  const root = await fixture(t), base = (await apply(root, operation(null, 0), "base\n")).entry;
  const journals = await fs.readdir(path.join(root, ".codmes", "sync-v2"));
  const file = path.join(root, ".codmes", "sync-v2", journals[0], "state.json"), saved = JSON.parse(await fs.readFile(file));
  const event = saved.operations[0];
  // Seed equivalent, already acknowledged no-op metadata without 10k fsyncs.
  for (let n = 1; n < 10000; n++) saved.operations.push({ ...event, id: `operation_${String(n).padStart(16, "0")}` });
  await fs.writeFile(file, JSON.stringify(saved));
  assert.equal((await apply(root, operation(base, 1), "next\n")).status, "applied");
  assert.equal(await read(root), "next\n");
});
