import fs from "node:fs/promises";
import { createReadStream } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { deflateRaw, inflateRaw } from "node:zlib";
import { promisify } from "node:util";

const compress = promisify(deflateRaw), expand = promisify(inflateRaw);
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const validHash = value => /^[a-f0-9]{64}$/.test(value ?? "");
const damaged = () => Object.assign(new Error("The synchronization base is damaged. Local changes were not discarded."), { status: 409 });
// Content-defined boundaries resynchronize after insertions. Blocks have no parent
// chains, so reading an old offline base does not replay a version history.
const gear = Array.from({ length: 256 }, (_, n) => createHash("sha256").update(Buffer.from([n])).digest().readUInt32LE(0));
function location(root, kind, revision) {
  if (!validHash(revision)) throw damaged();
  return path.join(root, ".codmes", "sync-bases", kind, revision);
}
async function durable(file, data, rejectSymlinks, root) {
  await rejectSymlinks(root, file);
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  const handle = await fs.open(temporary, "wx", 0o600);
  try { await handle.writeFile(data); await handle.sync(); }
  finally { await handle.close(); }
  try { await fs.rename(temporary, file); }
  finally { await fs.rm(temporary, { force: true }); }
}
async function descriptor(root, revision, rejectSymlinks) {
  const file = location(root, "revisions", revision);
  await rejectSymlinks(root, file);
  try {
    const value = JSON.parse(await fs.readFile(file, "utf8"));
    if (value.version !== 1 || !Number.isSafeInteger(value.size) || value.size < 0 || !Array.isArray(value.blocks) || value.blocks.some(id => !validHash(id))) throw damaged();
    return value;
  } catch (error) { if (error.code === "ENOENT") return null; throw error; }
}
async function block(root, id, rejectSymlinks) {
  const file = location(root, "blocks", id);
  await rejectSymlinks(root, file);
  const packed = await fs.readFile(file);
  let bytes;
  try {
    bytes = packed[0] === 1 ? await expand(packed.subarray(1), { maxOutputLength: 32 * 1024 }) : packed[0] === 0 ? packed.subarray(1) : null;
  } catch { throw damaged(); }
  if (!bytes || bytes.length > 32 * 1024 || hash(bytes) !== id) throw damaged();
  return bytes;
}
export async function preserveSyncBase(root, file, revision, rejectSymlinks) {
  if (!revision) return;
  const existing = await descriptor(root, revision, rejectSymlinks);
  if (existing) {
    // Validate reused data too: damaged bases must never overwrite current files.
    await readSyncBase(root, revision, rejectSymlinks, async () => {});
    return;
  }
  const blocks = [], whole = createHash("sha256");
  let size = 0, used = 0, fingerprint = 0;
  const buffer = Buffer.allocUnsafe(32 * 1024);
  const flush = async () => {
    if (!used) return;
    const bytes = buffer.subarray(0, used), id = hash(bytes);
    const destination = location(root, "blocks", id);
    await rejectSymlinks(root, destination);
    try { await fs.access(destination); await block(root, id, rejectSymlinks); }
    catch (error) {
      if (error.code !== "ENOENT") throw error;
      const packed = await compress(bytes, { level: 1 });
      await durable(destination, packed.length < bytes.length ? Buffer.concat([Buffer.from([1]), packed]) : Buffer.concat([Buffer.from([0]), bytes]), rejectSymlinks, root);
    }
    blocks.push(id); used = 0; fingerprint = 0;
  };
  for await (const input of createReadStream(file)) {
    whole.update(input); size += input.length;
    for (const byte of input) {
      buffer[used++] = byte;
      fingerprint = ((fingerprint << 1) + gear[byte]) >>> 0;
      if (used >= 32 * 1024 || (used >= 2048 && (fingerprint & 8191) === 0)) await flush();
    }
  }
  await flush();
  if (whole.digest("hex") !== revision) throw damaged();
  await durable(location(root, "revisions", revision), JSON.stringify({ version: 1, size, blocks }), rejectSymlinks, root);
}
// Optional consumer streams large PDF bases; small text/annotation merges use bytes.
export async function readSyncBase(root, revision, rejectSymlinks, consume) {
  if (!revision) return Buffer.alloc(0);
  let saved = await descriptor(root, revision, rejectSymlinks);
  if (!saved) {
    const legacy = path.join(root, ".codmes", "sync-history", revision);
    await rejectSymlinks(root, legacy);
    await preserveSyncBase(root, legacy, revision, rejectSymlinks);
    // Only replace this exact old copy after its durable, verified replacement exists.
    const verified = await readSyncBase(root, revision, rejectSymlinks, consume);
    await fs.unlink(legacy);
    return verified;
  }
  const whole = createHash("sha256"), buffers = [];
  let size = 0;
  for (const id of saved.blocks) {
    const bytes = await block(root, id, rejectSymlinks);
    whole.update(bytes); size += bytes.length;
    if (consume) await consume(bytes); else buffers.push(bytes);
  }
  if (size !== saved.size || whole.digest("hex") !== revision) throw damaged();
  return consume ? undefined : Buffer.concat(buffers, size);
}
export async function materializeSyncBase(root, revision, target, rejectSymlinks) {
  await rejectSymlinks(root, target);
  await fs.mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
  const handle = await fs.open(target, "wx", 0o600);
  try { await readSyncBase(root, revision, rejectSymlinks, bytes => handle.writeFile(bytes)); await handle.sync(); }
  catch (error) { await handle.close(); await fs.rm(target, { force: true }); throw error; }
  await handle.close();
}
