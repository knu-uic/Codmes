import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash, randomBytes } from "node:crypto";
import { preserveSyncBase, readSyncBase, materializeSyncBase } from "./workspace-sync-storage.mjs";

const hash = data => createHash("sha256").update(data).digest("hex");
const checked = async (root, file) => { assert.ok(!path.relative(root, file).startsWith("..")); };
async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-base-storage-"));
  t.after(() => fs.rm(root, { recursive: true, force: true })); return root;
}
async function sizes(root) {
  let total = 0;
  for (const kind of ["blocks", "revisions"]) {
    const dir = path.join(root, ".codmes", "sync-bases", kind);
    for (const name of await fs.readdir(dir)) total += (await fs.stat(path.join(dir, name))).size;
  }
  return total;
}
test("small PDF-style changes and insertions share unchanged blocks, not whole copies", async t => {
  const root = await fixture(t), source = path.join(root, "upload");
  let data = randomBytes(1024 * 1024); const originals = [];
  for (let n = 0; n < 20; n++) {
    data = Buffer.concat([data.subarray(0, 40000 + n * 10000), Buffer.from(`new ink ${n}`), data.subarray(40000 + n * 10000)]);
    const revision = hash(data); originals.push([revision, data]);
    await fs.writeFile(source, data); await preserveSyncBase(root, source, revision, checked);
  }
  const size = await sizes(root);
  assert.ok(size < 4 * 1024 * 1024, `Twenty ~1 MB versions stored ${size} bytes`);
  t.diagnostic(`20 × ~1 MiB binary edits: shared storage ${size} bytes (instead of ~20 MiB)`);
  for (const [revision, original] of originals) assert.deepEqual(await readSyncBase(root, revision, checked), original);
  const last = originals.at(-1), target = path.join(root, "materialized");
  await materializeSyncBase(root, last[0], target, checked); assert.deepEqual(await fs.readFile(target), last[1]);
});
test("identical content adds no storage; old whole copies migrate only after verification", async t => {
  const root = await fixture(t), data = Buffer.from("same text\n".repeat(10000)), revision = hash(data);
  const legacy = path.join(root, ".codmes", "sync-history", revision);
  await fs.mkdir(path.dirname(legacy), { recursive: true }); await fs.writeFile(legacy, data);
  assert.deepEqual(await readSyncBase(root, revision, checked), data);
  await assert.rejects(fs.stat(legacy), { code: "ENOENT" });
  const initial = await sizes(root), file = path.join(root, "upload"); await fs.writeFile(file, data);
  for (let n = 0; n < 10; n++) await preserveSyncBase(root, file, revision, checked);
  assert.equal(await sizes(root), initial);
});
test("corrupt blocks and missing blocks do not publish a partially reconstructed file", async t => {
  const root = await fixture(t), data = randomBytes(70000), revision = hash(data), source = path.join(root, "source");
  await fs.writeFile(source, data); await preserveSyncBase(root, source, revision, checked);
  const saved = JSON.parse(await fs.readFile(path.join(root, ".codmes", "sync-bases", "revisions", revision)));
  const block = path.join(root, ".codmes", "sync-bases", "blocks", saved.blocks.at(-1));
  await fs.writeFile(block, Buffer.from([1, 0xff]));
  const target = path.join(root, "target");
  await assert.rejects(materializeSyncBase(root, revision, target, checked), { status: 409 });
  await assert.rejects(fs.stat(target), { code: "ENOENT" });
  await fs.unlink(block); await assert.rejects(readSyncBase(root, revision, checked), { code: "ENOENT" });
});
