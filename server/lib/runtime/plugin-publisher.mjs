import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import { normalizeMarketplaceRegistry } from "./plugin-marketplace.mjs";
import {
  packPluginPackage,
  publisherIdentity
} from "./plugin-package.mjs";
import { readPluginManifestSource } from "./plugin-registry.mjs";

export async function preparePluginRelease({
  sourcePath,
  outputDirectory,
  registryPath,
  packageUrl,
  signingKey,
  publisherId,
  category = null,
  icon = null,
  repositoryUrl = null,
  privacyUrl = null,
  releaseNotes = null,
  featured = false,
  verified = false,
  force = false
}) {
  if (!sourcePath || !outputDirectory || !registryPath || !packageUrl
      || !signingKey || !publisherId) {
    throw new Error("Release preparation requires source, output, registry, package URL, signing key, and publisher id.");
  }
  const url = normalizeReleasePackageUrl(packageUrl);
  const source = path.resolve(String(sourcePath));
  const output = path.resolve(String(outputDirectory));
  const registry = path.resolve(String(registryPath));
  const manifest = await readPluginManifestSource(source);
  const filename = `${manifest.id}-${manifest.version}.codmes-plugin`;
  if (!url.pathname.endsWith(`/${filename}`)) {
    throw new Error(`Release package URL must end with '/${filename}'.`);
  }
  await fs.mkdir(output, { recursive: true });
  const destination = path.join(output, filename);
  if (!force && await pathExists(destination)) {
    throw new Error(`Release package already exists: ${destination}`);
  }

  const temporaryPackage = path.join(
    output,
    `.${filename}.${crypto.randomBytes(6).toString("hex")}.tmp`
  );
  let packed;
  try {
    packed = await packPluginPackage(source, temporaryPackage, {
      signingKey,
      publisherId
    });
    if (force) await fs.rm(destination, { force: true });
    await fs.rename(temporaryPackage, destination);
  } finally {
    await fs.rm(temporaryPackage, { force: true }).catch(() => {});
  }

  const identity = publisherIdentity(publisherId, crypto.createPublicKey(signingKey));
  const existing = await readRegistryOrDefault(registry);
  const existingPlugin = existing.plugins.find((plugin) => plugin.id === manifest.id) || null;
  const existingPublisher = existing.publishers.find(
    (publisher) => publisher.id === identity.publisherId
  ) || null;
  if (existing.governancePolicy === "reviewed") {
    if (existingPublisher?.status !== "approved") {
      throw new Error("Reviewed Registry requires an approved publisher before release preparation.");
    }
    const approvedKey = existingPublisher.keys.find(
      (key) => key.keyId === identity.keyId && key.status === "active"
    );
    if (!approvedKey) {
      throw new Error("Reviewed Registry requires the signing key to be active before release preparation.");
    }
  }
  const nextPublisher = {
    id: identity.publisherId,
    name: String(manifest.publisher || identity.publisherId),
    status: "approved",
    keys: [{
      algorithm: identity.algorithm,
      keyId: identity.keyId,
      publicKey: identity.publicKey,
      status: "active"
    }]
  };
  const publishers = existing.governancePolicy === "reviewed"
    ? existing.publishers
    : upsertPublisher(existing.publishers, nextPublisher);
  const entry = {
    id: manifest.id,
    name: manifest.name,
    version: manifest.version,
    description: manifest.description,
    publisher: manifest.publisher || nextPublisher.name,
    category: category || existingPlugin?.category || "Other",
    icon: icon || manifest.surface.icon || existingPlugin?.icon || "shippingbox",
    verified: verified || existingPlugin?.verified === true,
    featured: featured || existingPlugin?.featured === true,
    packageUrl: url.toString(),
    sha256: packed.sha256,
    signature: packed.signature,
    platforms: manifest.platforms,
    permissions: manifest.permissions,
    repositoryUrl: repositoryUrl || existingPlugin?.repositoryUrl || null,
    privacyUrl: privacyUrl || existingPlugin?.privacyUrl || null,
    dataVersion: manifest.dataVersion,
    releaseNotes: releaseNotes || existingPlugin?.releaseNotes || ""
  };
  const normalized = normalizeMarketplaceRegistry({
    schemaVersion: 1,
    updatedAt: new Date().toISOString(),
    signaturePolicy: existing.signaturePolicy || "required",
    governancePolicy: existing.governancePolicy || "open",
    publishers,
    blockedVersions: existing.blockedVersions || [],
    plugins: [
      ...existing.plugins.filter((plugin) => plugin.id !== manifest.id),
      entry
    ]
  });
  await writeJsonAtomic(registry, normalized);
  return {
    pluginId: manifest.id,
    version: manifest.version,
    tag: `${manifest.id}-v${manifest.version}`,
    packagePath: destination,
    packageUrl: url.toString(),
    sha256: packed.sha256,
    signature: packed.signature,
    publisher: identity,
    registryPath: registry,
    registryEntry: normalized.plugins.find((plugin) => plugin.id === manifest.id)
  };
}

async function readRegistryOrDefault(file) {
  try {
    return normalizeMarketplaceRegistry(JSON.parse(await fs.readFile(file, "utf8")));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    return {
      schemaVersion: 1,
      updatedAt: null,
      signaturePolicy: "required",
      governancePolicy: "open",
      publishers: [],
      blockedVersions: [],
      plugins: []
    };
  }
}

function upsertPublisher(publishers, next) {
  const current = publishers.find((publisher) => publisher.id === next.id);
  if (!current) return [...publishers, next];
  return [
    ...publishers.filter((publisher) => publisher.id !== next.id),
    {
      ...current,
      name: current.name || next.name,
      status: current.status || "approved",
      keys: [
        ...current.keys.filter((key) => key.keyId !== next.keys[0].keyId),
        next.keys[0]
      ]
    }
  ];
}

function normalizeReleasePackageUrl(value) {
  const url = new URL(String(value || ""));
  const loopback = ["localhost", "127.0.0.1", "::1"].includes(
    url.hostname.replace(/^\[|\]$/g, "")
  );
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new Error("Release package URL must use HTTPS except for loopback testing.");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("Release package URL must not contain credentials, query, or fragment.");
  }
  return url;
}

async function writeJsonAtomic(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const temporary = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${crypto.randomBytes(6).toString("hex")}.tmp`
  );
  await fs.writeFile(temporary, JSON.stringify(value, null, 2) + "\n", "utf8");
  await fs.rename(temporary, file);
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
