import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { strFromU8, strToU8, unzipSync, zipSync } from "fflate";

const MAX_PACKAGE_BYTES = 5 * 1024 * 1024;
const MAX_UNPACKED_BYTES = 12 * 1024 * 1024;
const SIGNATURE_FILE = "codmes-signature.json";
const PUBLISHER_ID_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)+$/;
const OPTIONAL_PACKAGE_FILES = [
  "README.md",
  "CHANGELOG.md",
  "LICENSE",
  "LICENSE.md",
  "icon.png",
  "tools.json",
  "storage.json",
  "migrations.json"
];

export async function packPluginPackage(sourcePath, destinationPath, options = {}) {
  const source = path.resolve(String(sourcePath || ""));
  const stat = await fs.stat(source);
  const directory = stat.isDirectory() ? source : path.dirname(source);
  const manifestPath = stat.isDirectory() ? path.join(source, "plugin.json") : source;
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const names = new Set(["plugin.json"]);
  if (typeof manifest?.surface?.ui === "string") names.add(normalizePackagePath(manifest.surface.ui));
  if (typeof manifest?.tools === "string") names.add(normalizePackagePath(manifest.tools));
  if (typeof manifest?.storage === "string") names.add(normalizePackagePath(manifest.storage));
  if (typeof manifest?.migrations === "string") names.add(normalizePackagePath(manifest.migrations));
  for (const name of OPTIONAL_PACKAGE_FILES) {
    try {
      if ((await fs.stat(path.join(directory, name))).isFile()) names.add(name);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }

  const files = {};
  let total = 0;
  for (const name of names) {
    const absolute = path.resolve(directory, name);
    assertInside(directory, absolute);
    const value = await fs.readFile(absolute);
    total += value.byteLength;
    if (total > MAX_UNPACKED_BYTES) throw new Error("Plugin package contents are too large.");
    files[name] = new Uint8Array(value);
  }
  files["codmes-package.json"] = strToU8(JSON.stringify({
    formatVersion: 1,
    pluginId: String(manifest.id || ""),
    version: String(manifest.version || "")
  }, null, 2) + "\n");
  let signature = null;
  if (options.signingKey) {
    const publisherId = normalizePublisherId(options.publisherId);
    const privateKey = crypto.createPrivateKey(options.signingKey);
    if (privateKey.asymmetricKeyType !== "ed25519") {
      throw new Error("Plugin signing key must be an Ed25519 private key.");
    }
    const publicKey = crypto.createPublicKey(privateKey);
    const keyId = publisherKeyId(publicKey);
    signature = {
      formatVersion: 1,
      algorithm: "ed25519",
      publisherId,
      keyId,
      signature: crypto.sign(null, signingPayload(files), privateKey).toString("base64")
    };
    files[SIGNATURE_FILE] = strToU8(JSON.stringify(signature, null, 2) + "\n");
  }

  const archive = Buffer.from(zipSync(files, { level: 9 }));
  if (archive.byteLength > MAX_PACKAGE_BYTES) throw new Error("Plugin package archive is too large.");
  const destination = path.resolve(String(destinationPath || ""));
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.writeFile(destination, archive);
  return {
    path: destination,
    bytes: archive.byteLength,
    sha256: sha256(archive),
    pluginId: String(manifest.id || ""),
    version: String(manifest.version || ""),
    signature: signature ? {
      algorithm: signature.algorithm,
      publisherId: signature.publisherId,
      keyId: signature.keyId
    } : null
  };
}

export function inspectPluginPackage(buffer) {
  const archive = Buffer.from(buffer);
  if (!archive.byteLength || archive.byteLength > MAX_PACKAGE_BYTES) {
    throw new Error("Plugin package archive size is invalid.");
  }
  let unpacked;
  try {
    unpacked = unzipSync(new Uint8Array(archive));
  } catch {
    throw new Error("Plugin package is not a valid ZIP archive.");
  }
  const files = new Map();
  let total = 0;
  for (const [rawName, bytes] of Object.entries(unpacked)) {
    const name = normalizePackagePath(rawName);
    total += bytes.byteLength;
    if (total > MAX_UNPACKED_BYTES) throw new Error("Plugin package contents are too large.");
    files.set(name, Buffer.from(bytes));
  }
  if (!files.has("plugin.json")) throw new Error("Plugin package must contain plugin.json.");
  const metadata = files.has("codmes-package.json")
    ? parseJson(files.get("codmes-package.json"), "codmes-package.json")
    : null;
  if (metadata && Number(metadata.formatVersion) !== 1) {
    throw new Error("Unsupported Codmes plugin package format.");
  }
  const manifest = parseJson(files.get("plugin.json"), "plugin.json");
  if (metadata?.pluginId && metadata.pluginId !== manifest.id) {
    throw new Error("Plugin package metadata id does not match its manifest.");
  }
  if (metadata?.version && metadata.version !== manifest.version) {
    throw new Error("Plugin package metadata version does not match its manifest.");
  }
  const signature = files.has(SIGNATURE_FILE)
    ? normalizePackageSignature(parseJson(files.get(SIGNATURE_FILE), SIGNATURE_FILE))
    : null;
  return { files, manifest, metadata, signature, sha256: sha256(archive), bytes: archive.byteLength };
}

export function verifyPluginPackageSignature(buffer, publisherIdentity, expected = {}) {
  const inspected = inspectPluginPackage(buffer);
  if (!inspected.signature) {
    throw new Error("Plugin package is not signed.");
  }
  const identity = normalizePublisherIdentity(publisherIdentity);
  if (identity.publisherId !== inspected.signature.publisherId) {
    throw new Error("Plugin signature publisher does not match the trusted publisher.");
  }
  if (identity.keyId !== inspected.signature.keyId) {
    throw new Error("Plugin signature key does not match the trusted publisher key.");
  }
  if (expected.publisherId && expected.publisherId !== inspected.signature.publisherId) {
    throw new Error("Plugin signature publisher does not match the registry entry.");
  }
  if (expected.keyId && expected.keyId !== inspected.signature.keyId) {
    throw new Error("Plugin signature key does not match the registry entry.");
  }
  const publicKey = crypto.createPublicKey({
    key: Buffer.from(identity.publicKey, "base64"),
    format: "der",
    type: "spki"
  });
  const files = Object.fromEntries(
    [...inspected.files].filter(([name]) => name !== SIGNATURE_FILE)
      .map(([name, bytes]) => [name, new Uint8Array(bytes)])
  );
  const valid = crypto.verify(
    null,
    signingPayload(files),
    publicKey,
    Buffer.from(inspected.signature.signature, "base64")
  );
  if (!valid) throw new Error("Plugin package signature is invalid.");
  return {
    valid: true,
    algorithm: inspected.signature.algorithm,
    publisherId: inspected.signature.publisherId,
    keyId: inspected.signature.keyId,
    pluginId: String(inspected.manifest.id || ""),
    version: String(inspected.manifest.version || ""),
    sha256: inspected.sha256
  };
}

export function createPublisherKeyPair(publisherId) {
  const id = normalizePublisherId(publisherId);
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const identity = publisherIdentity(id, publicKey);
  return {
    identity,
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }).toString()
  };
}

export function publisherIdentity(publisherId, publicKeyValue) {
  const id = normalizePublisherId(publisherId);
  const publicKey = publicKeyValue?.type === "public"
    ? publicKeyValue
    : crypto.createPublicKey(publicKeyValue);
  if (publicKey.asymmetricKeyType !== "ed25519") {
    throw new Error("Publisher public key must use Ed25519.");
  }
  return {
    schemaVersion: 1,
    publisherId: id,
    algorithm: "ed25519",
    keyId: publisherKeyId(publicKey),
    publicKey: publicKey.export({ format: "der", type: "spki" }).toString("base64")
  };
}

export async function extractPluginPackage(buffer, destinationPath) {
  const inspected = inspectPluginPackage(buffer);
  const destination = path.resolve(String(destinationPath || ""));
  await fs.mkdir(destination, { recursive: true });
  for (const [name, bytes] of inspected.files) {
    if (name === "codmes-package.json" || name === SIGNATURE_FILE) continue;
    const absolute = path.resolve(destination, name);
    assertInside(destination, absolute);
    await fs.mkdir(path.dirname(absolute), { recursive: true });
    await fs.writeFile(absolute, bytes);
  }
  return {
    manifest: inspected.manifest,
    signature: inspected.signature,
    sha256: inspected.sha256,
    bytes: inspected.bytes
  };
}

function signingPayload(files) {
  const chunks = [Buffer.from("Codmes Plugin Signature v1\0", "utf8")];
  for (const name of Object.keys(files).filter((item) => item !== SIGNATURE_FILE).sort()) {
    const nameBuffer = Buffer.from(name, "utf8");
    const value = Buffer.from(files[name]);
    const nameLength = Buffer.alloc(4);
    nameLength.writeUInt32BE(nameBuffer.byteLength);
    const valueLength = Buffer.alloc(8);
    valueLength.writeBigUInt64BE(BigInt(value.byteLength));
    chunks.push(nameLength, nameBuffer, valueLength, value);
  }
  return Buffer.concat(chunks);
}

function normalizePackageSignature(value) {
  const publisherId = normalizePublisherId(value?.publisherId);
  const keyId = String(value?.keyId || "").trim();
  const signature = String(value?.signature || "").trim();
  if (Number(value?.formatVersion) !== 1
      || value?.algorithm !== "ed25519"
      || !/^ed25519:[a-f0-9]{32}$/.test(keyId)
      || !/^[A-Za-z0-9+/]+={0,2}$/.test(signature)) {
    throw new Error("Plugin package signature metadata is invalid.");
  }
  return { formatVersion: 1, algorithm: "ed25519", publisherId, keyId, signature };
}

function normalizePublisherIdentity(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Number(value.schemaVersion) !== 1 || value.algorithm !== "ed25519") {
    throw new Error("Publisher identity is invalid.");
  }
  const normalized = publisherIdentity(value.publisherId, {
    key: Buffer.from(String(value.publicKey || ""), "base64"),
    format: "der",
    type: "spki"
  });
  if (value.keyId && value.keyId !== normalized.keyId) {
    throw new Error("Publisher identity key id is invalid.");
  }
  return normalized;
}

function normalizePublisherId(value) {
  const id = String(value || "").trim().toLowerCase();
  if (!PUBLISHER_ID_PATTERN.test(id)) {
    throw new Error("Publisher id must use reverse-domain style lowercase characters.");
  }
  return id;
}

function publisherKeyId(publicKey) {
  const der = publicKey.export({ format: "der", type: "spki" });
  return `ed25519:${sha256(der).slice(0, 32)}`;
}

export function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function normalizePackagePath(value) {
  const name = String(value || "").replaceAll("\\", "/").replace(/^\.\/+/, "");
  if (!name || name.startsWith("/") || name.endsWith("/")
      || name.split("/").some((segment) => !segment || segment === "." || segment === "..")) {
    throw new Error("Plugin package contains an unsafe file path.");
  }
  return name;
}

function assertInside(root, target) {
  const relative = path.relative(root, target);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error("Plugin package file must stay inside the package directory.");
  }
}

function parseJson(value, label) {
  try {
    return JSON.parse(strFromU8(new Uint8Array(value)));
  } catch {
    throw new Error(`${label} must contain valid JSON.`);
  }
}
