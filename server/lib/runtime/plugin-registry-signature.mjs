import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import { sha256 } from "./plugin-package.mjs";

const SIGNATURE_CONTEXT = "Codmes Marketplace Registry Signature v1\0";
const ROOT_ID_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)+$/;

export function createRegistryRootKeyPair(rootId) {
  const id = normalizeRootId(rootId);
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  return {
    identity: registryRootIdentity(id, publicKey),
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }).toString()
  };
}

export function registryRootIdentity(rootId, publicKeyValue) {
  const id = normalizeRootId(rootId);
  const publicKey = publicKeyValue?.type === "public"
    ? publicKeyValue
    : crypto.createPublicKey(publicKeyValue);
  if (publicKey.asymmetricKeyType !== "ed25519") {
    throw new Error("Registry root public key must use Ed25519.");
  }
  const der = publicKey.export({ format: "der", type: "spki" });
  return {
    schemaVersion: 1,
    rootId: id,
    algorithm: "ed25519",
    keyId: `ed25519:${sha256(der).slice(0, 32)}`,
    publicKey: der.toString("base64")
  };
}

export async function signMarketplaceRegistryFile(
  registryPath,
  outputPath,
  options = {}
) {
  const source = path.resolve(String(registryPath || ""));
  const destination = path.resolve(String(outputPath || ""));
  const bytes = await fs.readFile(source);
  const signature = signMarketplaceRegistry(bytes, options);
  await fs.mkdir(path.dirname(destination), { recursive: true });
  const temporary = `${destination}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  await fs.writeFile(temporary, JSON.stringify(signature, null, 2) + "\n", "utf8");
  await fs.rename(temporary, destination);
  return {
    signed: true,
    registryPath: source,
    signaturePath: destination,
    rootId: signature.rootId,
    keyId: signature.keyId,
    registrySha256: signature.registrySha256
  };
}

export function signMarketplaceRegistry(bytes, { signingKey, rootId } = {}) {
  if (!signingKey || !rootId) {
    throw new Error("Registry signing requires a private key and root id.");
  }
  const privateKey = crypto.createPrivateKey(signingKey);
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new Error("Registry signing key must use Ed25519.");
  }
  const identity = registryRootIdentity(rootId, crypto.createPublicKey(privateKey));
  const value = Buffer.from(bytes);
  return {
    schemaVersion: 1,
    algorithm: "ed25519",
    rootId: identity.rootId,
    keyId: identity.keyId,
    registrySha256: sha256(value),
    signature: crypto.sign(
      null,
      signaturePayload(value),
      privateKey
    ).toString("base64")
  };
}

export function verifyMarketplaceRegistrySignature(bytes, signature, identity) {
  const root = normalizeRegistryRootIdentity(identity);
  if (!signature || Number(signature.schemaVersion) !== 1
      || signature.algorithm !== "ed25519"
      || signature.rootId !== root.rootId
      || signature.keyId !== root.keyId
      || !/^[a-f0-9]{64}$/.test(String(signature.registrySha256 || ""))
      || !/^[A-Za-z0-9+/]+={0,2}$/.test(String(signature.signature || ""))) {
    throw new Error("Marketplace Registry signature metadata is invalid.");
  }
  const value = Buffer.from(bytes);
  if (sha256(value) !== signature.registrySha256) {
    throw new Error("Marketplace Registry checksum does not match its signature.");
  }
  const valid = crypto.verify(
    null,
    signaturePayload(value),
    {
      key: Buffer.from(root.publicKey, "base64"),
      format: "der",
      type: "spki"
    },
    Buffer.from(signature.signature, "base64")
  );
  if (!valid) throw new Error("Marketplace Registry signature is invalid.");
  return {
    valid: true,
    rootId: root.rootId,
    keyId: root.keyId,
    registrySha256: signature.registrySha256
  };
}

export function normalizeRegistryRootIdentity(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Number(value.schemaVersion) !== 1
      || value.algorithm !== "ed25519") {
    throw new Error("Marketplace Registry root identity is invalid.");
  }
  const normalized = registryRootIdentity(value.rootId, {
    key: Buffer.from(String(value.publicKey || ""), "base64"),
    format: "der",
    type: "spki"
  });
  if (value.keyId && value.keyId !== normalized.keyId) {
    throw new Error("Marketplace Registry root key id is invalid.");
  }
  return normalized;
}

function signaturePayload(bytes) {
  return Buffer.concat([
    Buffer.from(SIGNATURE_CONTEXT, "utf8"),
    Buffer.from(bytes)
  ]);
}

function normalizeRootId(value) {
  const id = String(value || "").trim().toLowerCase();
  if (!ROOT_ID_PATTERN.test(id)) {
    throw new Error("Registry root id must use reverse-domain style lowercase characters.");
  }
  return id;
}
