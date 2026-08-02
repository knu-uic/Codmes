import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import { normalizeMarketplaceRegistry } from "./plugin-marketplace.mjs";
import {
  packPluginPackage,
  publisherIdentity,
  verifyPluginPackageSignature
} from "./plugin-package.mjs";
import { readPluginManifestSource } from "./plugin-registry.mjs";

export async function preparePluginRelease({
  sourcePath,
  outputDirectory = null,
  registryPath,
  packageUrl = null,
  packageDirectory = null,
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
  if (!sourcePath || !registryPath || !signingKey || !publisherId) {
    throw new Error("Release preparation requires source, registry, signing key, and publisher id.");
  }
  const source = path.resolve(String(sourcePath));
  const registry = path.resolve(String(registryPath));
  const manifest = await readPluginManifestSource(source);
  const filename = `${manifest.id}-${manifest.version}.codmes-plugin`;
  const url = packageUrl ? normalizeReleasePackageUrl(packageUrl) : null;
  if (url && !url.pathname.endsWith(`/${filename}`)) {
    throw new Error(`Release package URL must end with '/${filename}'.`);
  }
  // 공개 Marketplace 저장소처럼 Registry가 package를 직접 미러링하는 경우
  // package URL을 생략한다. 버전과 파일명을 manifest에서 읽어 packages/ 아래에
  // 서명 archive를 만들고 Registry에는 상대 packagePath를 기록한다.
  const registryDirectory = url
    ? null
    : normalizePackageDirectoryName(packageDirectory || manifest.id);
  const registryPackagePath = url
    ? null
    : `packages/${registryDirectory}/${manifest.version}.codmes-plugin`;
  const output = url
    ? path.resolve(String(outputDirectory || path.join("dist", "plugins")))
    : path.dirname(path.resolve(path.dirname(registry), registryPackagePath));
  await fs.mkdir(output, { recursive: true });
  const destination = url
    ? path.join(output, filename)
    : path.resolve(path.dirname(registry), registryPackagePath);
  const identity = publisherIdentity(publisherId, crypto.createPublicKey(signingKey));

  let packed;
  if (!force && await pathExists(destination)) {
    // GitHub Release에 이미 올린 archive를 Marketplace 브랜치에 복사한 뒤 이
    // 명령을 실행할 수 있다. 같은 version을 다시 pack하면 archive timestamp
    // 때문에 SHA가 달라질 수 있으므로 기존 byte를 그대로 검증·재사용한다.
    const archive = await fs.readFile(destination);
    const verified = verifyPluginPackageSignature(archive, identity);
    if (!verified.valid
        || verified.pluginId !== manifest.id
        || verified.version !== manifest.version) {
      throw new Error(`Existing release package is invalid or does not match ${manifest.id}@${manifest.version}.`);
    }
    packed = {
      sha256: verified.sha256,
      signature: {
        algorithm: verified.algorithm,
        publisherId: verified.publisherId,
        keyId: verified.keyId
      }
    };
  } else {
    const temporaryPackage = path.join(
      output,
      `.${filename}.${crypto.randomBytes(6).toString("hex")}.tmp`
    );
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
  }

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
    ...(url
      ? { packageUrl: url.toString() }
      : { packagePath: registryPackagePath }),
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
    packageUrl: url?.toString() || null,
    registryPackagePath,
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

function normalizePackageDirectoryName(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(normalized)) {
    throw new Error("Marketplace package directory must be a lowercase id or slug.");
  }
  return normalized;
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
