import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import {
  normalizeMarketplaceRegistry
} from "./plugin-marketplace.mjs";
import {
  publisherIdentity,
  sha256,
  verifyPluginPackageSignature
} from "./plugin-package.mjs";

const APPLICATION_CONTEXT = "Codmes Publisher Application v1\0";
const MAX_PACKAGE_BYTES = 5 * 1024 * 1024;

export function createPublisherApplication({
  signingKey,
  publisherId,
  name,
  repositoryUrl,
  contact = null
}) {
  if (!signingKey || !publisherId || !String(name || "").trim()) {
    throw new Error("Publisher application requires a signing key, publisher id, and name.");
  }
  const privateKey = crypto.createPrivateKey(signingKey);
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new Error("Publisher application signing key must be Ed25519.");
  }
  const identity = publisherIdentity(publisherId, crypto.createPublicKey(privateKey));
  const repository = normalizeHttpsUrl(repositoryUrl, "Publisher repository URL");
  const submittedAt = new Date().toISOString();
  const payload = {
    schemaVersion: 1,
    type: "codmes-publisher-application",
    submittedAt,
    publisher: {
      id: identity.publisherId,
      name: String(name).trim(),
      repositoryUrl: repository,
      contact: String(contact || "").trim() || null
    },
    key: identity
  };
  return {
    ...payload,
    proof: {
      algorithm: "ed25519",
      keyId: identity.keyId,
      signature: crypto.sign(
        null,
        applicationPayload(payload),
        privateKey
      ).toString("base64")
    }
  };
}

export function verifyPublisherApplication(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Number(value.schemaVersion) !== 1
      || value.type !== "codmes-publisher-application") {
    throw new Error("Publisher application schema is invalid.");
  }
  const publisher = value.publisher;
  const key = value.key;
  if (!publisher || publisher.id !== key?.publisherId
      || !String(publisher.name || "").trim()) {
    throw new Error("Publisher application identity is invalid.");
  }
  normalizeHttpsUrl(publisher.repositoryUrl, "Publisher repository URL");
  const normalizedIdentity = publisherIdentity(key.publisherId, {
    key: Buffer.from(String(key.publicKey || ""), "base64"),
    format: "der",
    type: "spki"
  });
  if (key.algorithm !== "ed25519"
      || key.keyId !== normalizedIdentity.keyId
      || value.proof?.algorithm !== "ed25519"
      || value.proof?.keyId !== normalizedIdentity.keyId) {
    throw new Error("Publisher application key metadata is invalid.");
  }
  const payload = {
    schemaVersion: 1,
    type: value.type,
    submittedAt: String(value.submittedAt || ""),
    publisher: {
      id: normalizedIdentity.publisherId,
      name: String(publisher.name).trim(),
      repositoryUrl: String(publisher.repositoryUrl),
      contact: String(publisher.contact || "").trim() || null
    },
    key: normalizedIdentity
  };
  const valid = crypto.verify(
    null,
    applicationPayload(payload),
    {
      key: Buffer.from(normalizedIdentity.publicKey, "base64"),
      format: "der",
      type: "spki"
    },
    Buffer.from(String(value.proof.signature || ""), "base64")
  );
  if (!valid) throw new Error("Publisher application proof is invalid.");
  return { valid: true, application: payload };
}

export async function approvePublisherApplication(registryPath, applicationPath) {
  const registry = await readRegistry(registryPath);
  const checked = verifyPublisherApplication(
    JSON.parse(await fs.readFile(path.resolve(applicationPath), "utf8"))
  );
  const application = checked.application;
  if (registry.publishers.some((publisher) => publisher.id === application.publisher.id)) {
    throw new Error("Publisher is already registered. Use key rotation for another key.");
  }
  const approvedAt = new Date().toISOString();
  registry.publishers.push({
    id: application.publisher.id,
    name: application.publisher.name,
    status: "approved",
    repositoryUrl: application.publisher.repositoryUrl,
    approvedAt,
    keys: [{
      algorithm: application.key.algorithm,
      keyId: application.key.keyId,
      publicKey: application.key.publicKey,
      status: "active",
      addedAt: approvedAt
    }]
  });
  registry.updatedAt = approvedAt;
  await writeRegistry(registryPath, registry);
  return {
    approved: true,
    publisherId: application.publisher.id,
    keyId: application.key.keyId,
    approvedAt
  };
}

export async function rotatePublisherKey(registryPath, identity, options = {}) {
  const registry = await readRegistry(registryPath);
  const normalized = publisherIdentity(identity.publisherId, {
    key: Buffer.from(String(identity.publicKey || ""), "base64"),
    format: "der",
    type: "spki"
  });
  if (identity.keyId && identity.keyId !== normalized.keyId) {
    throw new Error("Publisher identity key id is invalid.");
  }
  const publisher = registry.publishers.find((item) => item.id === normalized.publisherId);
  if (!publisher || publisher.status !== "approved") {
    throw new Error("Only an approved publisher can rotate keys.");
  }
  if (publisher.keys.some((key) => key.keyId === normalized.keyId)) {
    throw new Error("Publisher key is already registered.");
  }
  const rotatedAt = new Date().toISOString();
  if (options.retireCurrent !== false) {
    publisher.keys = publisher.keys.map((key) => key.status === "active"
      ? { ...key, status: "retired", retiredAt: rotatedAt }
      : key);
  }
  publisher.keys.push({
    algorithm: "ed25519",
    keyId: normalized.keyId,
    publicKey: normalized.publicKey,
    status: "active",
    addedAt: rotatedAt
  });
  registry.updatedAt = rotatedAt;
  await writeRegistry(registryPath, registry);
  return {
    rotated: true,
    publisherId: publisher.id,
    activeKeyId: normalized.keyId,
    rotatedAt
  };
}

export async function revokePublisherKey(
  registryPath,
  publisherId,
  keyId,
  reason
) {
  const registry = await readRegistry(registryPath);
  const publisher = registry.publishers.find((item) => item.id === String(publisherId));
  const key = publisher?.keys.find((item) => item.keyId === String(keyId));
  if (!publisher || !key) throw new Error("Publisher key was not found.");
  const revocationReason = String(reason || "").trim();
  if (!revocationReason) throw new Error("Publisher key revocation requires a reason.");
  if (key.status === "revoked") throw new Error("Publisher key is already revoked.");
  const revokedAt = new Date().toISOString();
  key.status = "revoked";
  key.revokedAt = revokedAt;
  key.revocationReason = revocationReason;
  const affected = registry.plugins.filter(
    (plugin) => plugin.signature?.publisherId === publisher.id
      && plugin.signature?.keyId === key.keyId
  );
  for (const plugin of affected) {
    upsertBlockedVersion(registry, {
      pluginId: plugin.id,
      version: plugin.version,
      severity: "critical",
      reason: `Publisher key revoked: ${revocationReason}`
    });
  }
  registry.updatedAt = revokedAt;
  await writeRegistry(registryPath, registry);
  return {
    revoked: true,
    publisherId: publisher.id,
    keyId: key.keyId,
    affectedVersions: affected.map((plugin) => ({
      pluginId: plugin.id,
      version: plugin.version
    })),
    revokedAt
  };
}

export async function setBlockedMarketplaceVersion(
  registryPath,
  pluginId,
  version,
  options = {}
) {
  const registry = await readRegistry(registryPath);
  const blocked = {
    pluginId: String(pluginId || "").trim().toLowerCase(),
    version: String(version || "").trim(),
    severity: String(options.severity || "high").trim().toLowerCase(),
    reason: String(options.reason || "").trim()
  };
  upsertBlockedVersion(registry, blocked);
  registry.updatedAt = new Date().toISOString();
  await writeRegistry(registryPath, registry);
  return { blocked: true, ...blocked };
}

export async function removeBlockedMarketplaceVersion(registryPath, pluginId, version) {
  const registry = await readRegistry(registryPath);
  const before = registry.blockedVersions.length;
  registry.blockedVersions = registry.blockedVersions.filter(
    (entry) => entry.pluginId !== String(pluginId).trim().toLowerCase()
      || entry.version !== String(version).trim()
  );
  if (registry.blockedVersions.length === before) {
    throw new Error("Blocked Marketplace version was not found.");
  }
  registry.updatedAt = new Date().toISOString();
  await writeRegistry(registryPath, registry);
  return { unblocked: true, pluginId, version };
}

export async function validateRegistryForPublication(registryPath, options = {}) {
  const file = path.resolve(String(registryPath || ""));
  const registry = await readRegistry(file);
  const errors = [];
  const warnings = [];
  if (options.production) {
    if (registry.signaturePolicy !== "required") {
      errors.push("Production Registry must require package signatures.");
    }
    if (registry.governancePolicy !== "reviewed") {
      errors.push("Production Registry must use reviewed publisher governance.");
    }
    if (!registry.updatedAt || !Number.isFinite(Date.parse(registry.updatedAt))) {
      errors.push("Production Registry requires a valid updatedAt timestamp.");
    }
  }
  for (const plugin of registry.plugins) {
    if (options.production && registry.blockedVersions.some(
      (entry) => entry.pluginId === plugin.id && entry.version === plugin.version
    )) {
      errors.push(`${plugin.id}@${plugin.version} is both the latest and a blocked version.`);
    }
    if (!plugin.signature) {
      if (options.production || registry.signaturePolicy === "required") {
        errors.push(`${plugin.id}@${plugin.version} is unsigned.`);
      } else {
        warnings.push(`${plugin.id}@${plugin.version} is unsigned.`);
      }
      continue;
    }
    const publisher = registry.publishers.find(
      (item) => item.id === plugin.signature.publisherId
    );
    const key = publisher?.keys.find((item) => item.keyId === plugin.signature.keyId);
    if (!publisher || publisher.status !== "approved") {
      errors.push(`${plugin.id}@${plugin.version} does not use an approved publisher.`);
    } else if (!key || key.status === "revoked") {
      errors.push(`${plugin.id}@${plugin.version} uses an unavailable publisher key.`);
    }
    if (options.production && (!plugin.sha256 || !plugin.releaseNotes)) {
      errors.push(`${plugin.id}@${plugin.version} requires checksum and release notes.`);
    }
  }
  if (options.production) {
    for (const publisher of registry.publishers) {
      if (publisher.status === "approved"
          && !publisher.keys.some((key) => key.status === "active")) {
        errors.push(`${publisher.id} does not have an active signing key.`);
      }
    }
  }
  if (options.verifyAssets) {
    await verifyRegistryAssets(file, registry, errors);
  }
  return {
    valid: errors.length === 0,
    production: options.production === true,
    registryPath: file,
    pluginCount: registry.plugins.length,
    publisherCount: registry.publishers.length,
    blockedVersionCount: registry.blockedVersions.length,
    errors,
    warnings,
    registry
  };
}

export async function buildStaticMarketplaceRegistry({
  registryPath,
  outputDirectory,
  production = false,
  force = false
}) {
  const source = path.resolve(String(registryPath || ""));
  const output = path.resolve(String(outputDirectory || ""));
  const sourceWithinOutput = path.relative(output, source);
  if (output === path.parse(output).root
      || !sourceWithinOutput
      || (!sourceWithinOutput.startsWith("..") && !path.isAbsolute(sourceWithinOutput))) {
    throw new Error("Registry output must not contain or replace the source Registry.");
  }
  const validation = await validateRegistryForPublication(source, {
    production,
    verifyAssets: true
  });
  if (!validation.valid) {
    throw new Error(`Registry publication validation failed:\n- ${validation.errors.join("\n- ")}`);
  }
  if (await pathExists(output)) {
    if (!force) throw new Error(`Registry output already exists: ${output}`);
  }
  const staging = `${output}.${crypto.randomBytes(6).toString("hex")}.building`;
  await fs.mkdir(staging, { recursive: true });
  try {
    const registry = {
      ...validation.registry,
      updatedAt: new Date().toISOString()
    };
    for (const plugin of registry.plugins) {
      if (!plugin.packagePath) continue;
      const sourcePackage = resolveInside(path.dirname(source), plugin.packagePath);
      const destination = resolveInside(staging, plugin.packagePath);
      await fs.mkdir(path.dirname(destination), { recursive: true });
      await fs.copyFile(sourcePackage, destination);
    }
    const index = Buffer.from(JSON.stringify(registry, null, 2) + "\n", "utf8");
    await fs.writeFile(path.join(staging, "index.json"), index);
    await fs.writeFile(path.join(staging, "health.json"), JSON.stringify({
      schemaVersion: 1,
      generatedAt: registry.updatedAt,
      registrySha256: sha256(index),
      pluginCount: registry.plugins.length,
      publisherCount: registry.publishers.length
    }, null, 2) + "\n");
    await fs.writeFile(path.join(staging, "_headers"), [
      "/index.json",
      "  Cache-Control: public, max-age=300, must-revalidate",
      "/health.json",
      "  Cache-Control: no-cache",
      "/packages/*",
      "  Cache-Control: public, max-age=31536000, immutable",
      ""
    ].join("\n"));
    if (await pathExists(output)) await fs.rm(output, { recursive: true, force: true });
    await fs.rename(staging, output);
    return {
      built: true,
      outputDirectory: output,
      registryPath: path.join(output, "index.json"),
      healthPath: path.join(output, "health.json"),
      pluginCount: registry.plugins.length,
      production
    };
  } catch (error) {
    await fs.rm(staging, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

async function verifyRegistryAssets(registryPath, registry, errors) {
  const base = path.dirname(registryPath);
  for (const plugin of registry.plugins) {
    try {
      const archive = plugin.packagePath
        ? await fs.readFile(resolveInside(base, plugin.packagePath))
        : await fetchRegistryAsset(plugin.packageUrl);
      if (archive.byteLength > MAX_PACKAGE_BYTES) {
        throw new Error("package exceeds the maximum size");
      }
      if (plugin.sha256 && sha256(archive) !== plugin.sha256) {
        errors.push(`${plugin.id}@${plugin.version} checksum does not match its package.`);
        continue;
      }
      if (plugin.signature) {
        const publisher = registry.publishers.find(
          (item) => item.id === plugin.signature.publisherId
        );
        const key = publisher?.keys.find((item) => item.keyId === plugin.signature.keyId);
        if (publisher?.status === "approved" && key && key.status !== "revoked") {
          const verified = verifyPluginPackageSignature(archive, {
            schemaVersion: 1,
            publisherId: publisher.id,
            algorithm: key.algorithm,
            keyId: key.keyId,
            publicKey: key.publicKey
          }, plugin.signature);
          if (verified.pluginId !== plugin.id || verified.version !== plugin.version) {
            throw new Error("signed package id or version does not match the Registry");
          }
        }
      }
    } catch (error) {
      errors.push(`${plugin.id}@${plugin.version} asset verification failed: ${error.message}`);
    }
  }
}

async function fetchRegistryAsset(value) {
  const url = new URL(String(value || ""));
  const loopback = ["localhost", "127.0.0.1", "::1"].includes(
    url.hostname.replace(/^\[|\]$/g, "")
  );
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new Error("remote package URL must use HTTPS");
  }
  const response = await fetch(url, {
    redirect: "follow",
    signal: AbortSignal.timeout(30_000)
  });
  if (!response.ok) throw new Error(`remote package returned ${response.status}`);
  const finalUrl = new URL(response.url);
  const finalLoopback = ["localhost", "127.0.0.1", "::1"].includes(
    finalUrl.hostname.replace(/^\[|\]$/g, "")
  );
  if (finalUrl.protocol !== "https:" && !(finalUrl.protocol === "http:" && finalLoopback)) {
    throw new Error("remote package redirected to an insecure URL");
  }
  return Buffer.from(await response.arrayBuffer());
}

function upsertBlockedVersion(registry, blocked) {
  const candidate = normalizeMarketplaceRegistry({
    ...registry,
    blockedVersions: [
      ...registry.blockedVersions.filter(
        (entry) => entry.pluginId !== blocked.pluginId || entry.version !== blocked.version
      ),
      blocked
    ]
  });
  registry.blockedVersions = candidate.blockedVersions;
}

async function readRegistry(file) {
  return normalizeMarketplaceRegistry(
    JSON.parse(await fs.readFile(path.resolve(String(file || "")), "utf8"))
  );
}

async function writeRegistry(file, registry) {
  const target = path.resolve(String(file || ""));
  const normalized = normalizeMarketplaceRegistry(registry);
  const temporary = `${target}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(temporary, JSON.stringify(normalized, null, 2) + "\n", "utf8");
  await fs.rename(temporary, target);
}

function applicationPayload(value) {
  return Buffer.concat([
    Buffer.from(APPLICATION_CONTEXT, "utf8"),
    Buffer.from(JSON.stringify(value), "utf8")
  ]);
}

function normalizeHttpsUrl(value, label) {
  let url;
  try {
    url = new URL(String(value || ""));
  } catch {
    throw new Error(`${label} must be an HTTPS URL.`);
  }
  if (url.protocol !== "https:" || url.username || url.password || url.hash) {
    throw new Error(`${label} must be an HTTPS URL without credentials or fragment.`);
  }
  return url.toString();
}

function resolveInside(root, relativePath) {
  const target = path.resolve(root, String(relativePath || ""));
  const relative = path.relative(root, target);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error("Registry package path must stay inside its directory.");
  }
  return target;
}

async function pathExists(file) {
  try {
    await fs.access(file);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}
