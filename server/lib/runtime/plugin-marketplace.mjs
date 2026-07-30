import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  getInstalledPlugin,
  getPluginInstallState,
  getPluginVersionManifest,
  installPlugin
} from "./plugin-registry.mjs";
import {
  extractPluginPackage,
  sha256,
  verifyPluginPackageSignature
} from "./plugin-package.mjs";
import {
  normalizeRegistryRootIdentity,
  verifyMarketplaceRegistrySignature
} from "./plugin-registry-signature.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const DEFAULT_REGISTRY_PATH = path.join(REPO_ROOT, "marketplace", "index.json");
const TRUSTED_REGISTRIES_PATH = path.join(
  REPO_ROOT,
  "marketplace",
  "trusted-registry-roots.json"
);
const PLUGIN_ID_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)+$/;
const SEMVER_PATTERN = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
const MAX_REGISTRY_BYTES = 1024 * 1024;
const MAX_PACKAGE_BYTES = 5 * 1024 * 1024;

export async function listMarketplacePlugins(workspaceRoot, options = {}) {
  const loaded = await loadMarketplaceRegistry(options);
  const plugins = [];
  for (const entry of loaded.registry.plugins) {
    const installed = await getInstalledPlugin(workspaceRoot, entry.id);
    const state = installed ? await getPluginInstallState(workspaceRoot, entry.id) : null;
    const acceptedPermissions = state?.acceptedPermissions || installed?.permissions || [];
    const addedPermissions = installed
      ? entry.permissions.filter((permission) => !acceptedPermissions.includes(permission))
      : [];
    const targetBlock = findBlockedVersion(loaded.registry, entry.id, entry.version);
    const installedBlock = installed
      ? findBlockedVersion(loaded.registry, entry.id, installed.version)
      : null;
    const rollbackBlock = state?.previousVersion
      ? findBlockedVersion(loaded.registry, entry.id, state.previousVersion)
      : null;
    const rollbackManifest = state?.previousVersion
      ? await getPluginVersionManifest(workspaceRoot, entry.id, state.previousVersion)
      : null;
    const rollbackDataMismatch = Boolean(
      rollbackManifest
      && Number(rollbackManifest.dataVersion || 1)
        !== Number(state?.dataVersion || installed?.dataVersion || 1)
    );
    plugins.push({
      ...entry,
      installed: Boolean(installed),
      installedVersion: installed?.version || null,
      updateAvailable: Boolean(
        installed && compareSemver(entry.version, installed.version) > 0 && !targetBlock
      ),
      canRollback: Boolean(state?.previousVersion && !rollbackBlock && !rollbackDataMismatch),
      previousVersion: state?.previousVersion || null,
      addedPermissions,
      permissionChangeRequired: addedPermissions.length > 0,
      blocked: Boolean(targetBlock),
      blockReason: targetBlock?.reason || null,
      installedVersionBlocked: Boolean(installedBlock),
      installedBlockReason: installedBlock?.reason || null,
      rollbackBlockedReason: rollbackBlock?.reason
        || (rollbackDataMismatch ? "The previous version uses an incompatible data schema." : null)
    });
  }
  return {
    schemaVersion: loaded.registry.schemaVersion,
    source: loaded.publicSource,
    plugins
  };
}

export async function getMarketplacePlugin(pluginId, options = {}) {
  const id = normalizePluginId(pluginId);
  const loaded = await loadMarketplaceRegistry(options);
  const plugin = loaded.registry.plugins.find((entry) => entry.id === id);
  if (!plugin) throw Object.assign(new Error("Marketplace plugin was not found."), { status: 404 });
  return { plugin, loaded };
}

export async function assertMarketplaceVersionAllowed(pluginId, version, options = {}) {
  const id = normalizePluginId(pluginId);
  const loaded = await loadMarketplaceRegistry(options);
  const blocked = findBlockedVersion(loaded.registry, id, String(version || ""));
  if (blocked) {
    throw Object.assign(new Error(`Plugin version is blocked: ${blocked.reason}`), {
      status: 409,
      code: "plugin_version_blocked",
      details: blocked
    });
  }
  return { allowed: true, pluginId: id, version: String(version || "") };
}

export async function installMarketplacePlugin(workspaceRoot, pluginId, options = {}) {
  const { plugin, loaded } = await getMarketplacePlugin(pluginId, options);
  if (options.version && String(options.version) !== plugin.version) {
    throw Object.assign(new Error("Requested Marketplace plugin version is unavailable."), { status: 404 });
  }
  const blocked = findBlockedVersion(loaded.registry, plugin.id, plugin.version);
  if (blocked) {
    throw Object.assign(new Error(`Plugin version is blocked: ${blocked.reason}`), {
      status: 409,
      code: "plugin_version_blocked",
      details: blocked
    });
  }
  const installed = await getInstalledPlugin(workspaceRoot, plugin.id);
  const state = installed ? await getPluginInstallState(workspaceRoot, plugin.id) : null;
  const acceptedBefore = state?.acceptedPermissions || installed?.permissions || [];
  const pinnedPublisherId = String(state?.source?.publisherId || "").trim() || null;
  const nextPublisherId = plugin.signature?.publisherId || null;
  if (pinnedPublisherId && nextPublisherId !== pinnedPublisherId) {
    throw Object.assign(
      new Error("Plugin update publisher does not match the installed publisher."),
      {
        status: 409,
        code: "plugin_publisher_changed",
        details: {
          pluginId: plugin.id,
          installedPublisherId: pinnedPublisherId,
          requestedPublisherId: nextPublisherId
        }
      }
    );
  }
  const addedPermissions = installed
    ? plugin.permissions.filter((permission) => !acceptedBefore.includes(permission))
    : [];
  const acceptedNow = Array.isArray(options.acceptedPermissions)
    ? options.acceptedPermissions.map(String)
    : [];
  if (addedPermissions.some((permission) => !acceptedNow.includes(permission))) {
    throw Object.assign(
      new Error("Plugin update requires consent for new permissions."),
      {
        status: 409,
        code: "plugin_permissions_required",
        details: {
          pluginId: plugin.id,
          version: plugin.version,
          addedPermissions
        }
      }
    );
  }
  const archive = await readMarketplacePackage(plugin, loaded);
  const digest = sha256(archive);
  if (plugin.sha256 && digest !== plugin.sha256) {
    throw Object.assign(new Error("Marketplace plugin package checksum does not match."), { status: 502 });
  }
  const trustedPublisher = plugin.signature
    ? loaded.registry.publishers.find(
      (publisher) => publisher.id === plugin.signature.publisherId
        && publisher.status === "approved"
    )
    : null;
  const publisherKey = trustedPublisher?.keys.find(
    (key) => key.keyId === plugin.signature.keyId && key.status !== "revoked"
  ) || null;
  if (plugin.signature && !publisherKey) {
    throw new Error("Marketplace plugin references an untrusted publisher key.");
  }
  if (plugin.signature) {
    verifyPluginPackageSignature(archive, {
      schemaVersion: 1,
      publisherId: plugin.signature.publisherId,
      ...publisherKey
    }, plugin.signature);
  } else if (loaded.registry.signaturePolicy === "required") {
    throw new Error("Marketplace requires signed plugin packages.");
  }
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-plugin-"));
  try {
    const extracted = await extractPluginPackage(archive, temporary);
    if (String(extracted.manifest.id || "").toLowerCase() !== plugin.id
        || String(extracted.manifest.version || "") !== plugin.version) {
      throw new Error("Marketplace package does not match its registry entry.");
    }
    if (!sameStringSet(extracted.manifest.permissions, plugin.permissions)
        || Number(extracted.manifest.dataVersion || 1) !== plugin.dataVersion) {
      throw new Error("Marketplace package permissions or data version do not match its registry entry.");
    }
    const result = await installPlugin(workspaceRoot, temporary, {
      packageSha256: digest,
      acceptedPermissions: [...new Set([...acceptedBefore, ...plugin.permissions])],
      source: {
        type: "marketplace",
        registry: loaded.publicSource,
        pluginId: plugin.id,
        version: plugin.version,
        publisherId: plugin.signature?.publisherId || pinnedPublisherId,
        publisherKeyId: plugin.signature?.keyId || null
      }
    });
    return { ...result, marketplace: plugin };
  } finally {
    await fs.rm(temporary, { recursive: true, force: true });
  }
}

export async function loadMarketplaceRegistry(options = {}) {
  const configured = options.registrySource || process.env.CODMES_MARKETPLACE_REGISTRY || DEFAULT_REGISTRY_PATH;
  if (/^https?:\/\//i.test(configured)) {
    const url = normalizeRemoteUrl(configured, "Marketplace registry");
    const response = await fetch(url, {
      headers: { accept: "application/json" },
      redirect: "follow",
      signal: AbortSignal.timeout(15_000)
    });
    if (!response.ok) throw Object.assign(new Error(`Marketplace registry returned ${response.status}.`), { status: 502 });
    normalizeRemoteUrl(response.url, "Marketplace registry redirect");
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.byteLength > MAX_REGISTRY_BYTES) {
      throw new Error("Marketplace registry is too large.");
    }
    const trusted = await trustedRegistryForUrl(url, options);
    let registrySignature = null;
    if (trusted) {
      const signatureUrl = normalizeRemoteUrl(
        trusted.signatureUrl || new URL("index.sig.json", url).toString(),
        "Marketplace registry signature"
      );
      const signatureResponse = await fetch(signatureUrl, {
        headers: { accept: "application/json" },
        redirect: "follow",
        signal: AbortSignal.timeout(15_000)
      });
      if (!signatureResponse.ok) {
        throw new Error(`Marketplace Registry signature returned ${signatureResponse.status}.`);
      }
      normalizeRemoteUrl(
        signatureResponse.url,
        "Marketplace registry signature redirect"
      );
      const signatureText = await signatureResponse.text();
      if (Buffer.byteLength(signatureText, "utf8") > 64 * 1024) {
        throw new Error("Marketplace Registry signature is too large.");
      }
      registrySignature = verifyMarketplaceRegistrySignature(
        bytes,
        JSON.parse(signatureText),
        trusted.root
      );
    }
    return {
      registry: normalizeMarketplaceRegistry(JSON.parse(bytes.toString("utf8"))),
      sourceType: "remote",
      source: url.toString(),
      publicSource: url.toString(),
      base: new URL(".", url),
      registrySignature
    };
  }
  const source = path.resolve(String(configured));
  const text = await fs.readFile(source, "utf8");
  if (Buffer.byteLength(text, "utf8") > MAX_REGISTRY_BYTES) {
    throw new Error("Marketplace registry is too large.");
  }
  return {
    registry: normalizeMarketplaceRegistry(JSON.parse(text)),
    sourceType: "file",
    source,
    publicSource: path.relative(REPO_ROOT, source) || path.basename(source),
    base: path.dirname(source)
  };
}

async function trustedRegistryForUrl(url, options) {
  const provided = options.trustedRegistries;
  let document = provided || null;
  if (!document) {
    try {
      document = JSON.parse(await fs.readFile(TRUSTED_REGISTRIES_PATH, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      return null;
    }
  }
  if (!document || Number(document.schemaVersion) !== 1
      || !Array.isArray(document.registries)) {
    throw new Error("Trusted Marketplace Registry roots document is invalid.");
  }
  const exact = document.registries.find(
    (entry) => String(entry?.url || "") === url.toString()
  );
  if (!exact) return null;
  return {
    url: url.toString(),
    signatureUrl: String(exact.signatureUrl || "").trim() || null,
    root: normalizeRegistryRootIdentity(exact.root)
  };
}

export function normalizeMarketplaceRegistry(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Number(value.schemaVersion) !== 1 || !Array.isArray(value.plugins)) {
    throw new Error("Marketplace registry schema is invalid.");
  }
  const signaturePolicy = String(value.signaturePolicy || "optional").trim();
  if (!["optional", "required"].includes(signaturePolicy)) {
    throw new Error("Marketplace signaturePolicy must be optional or required.");
  }
  const governancePolicy = String(value.governancePolicy || "open").trim();
  if (!["open", "reviewed"].includes(governancePolicy)) {
    throw new Error("Marketplace governancePolicy must be open or reviewed.");
  }
  const publishers = normalizeMarketplacePublishers(value.publishers);
  const plugins = value.plugins.map(normalizeMarketplaceEntry);
  const blockedVersions = normalizeBlockedVersions(value.blockedVersions);
  if (new Set(plugins.map((plugin) => plugin.id)).size !== plugins.length) {
    throw new Error("Marketplace plugin ids must be unique.");
  }
  return {
    schemaVersion: 1,
    updatedAt: String(value.updatedAt || "").trim() || null,
    signaturePolicy,
    governancePolicy,
    publishers,
    blockedVersions,
    plugins: plugins.sort((a, b) => a.name.localeCompare(b.name))
  };
}

export function compareSemver(left, right) {
  const parse = (value) => String(value).split(/[+-]/, 1)[0].split(".").map(Number);
  const a = parse(left);
  const b = parse(right);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
  }
  return 0;
}

function normalizeMarketplaceEntry(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Marketplace plugin entry must be an object.");
  }
  const id = normalizePluginId(value.id);
  const version = String(value.version || "").trim();
  const name = String(value.name || "").trim();
  if (!SEMVER_PATTERN.test(version)) throw new Error(`Marketplace plugin '${id}' has an invalid version.`);
  if (!name) throw new Error(`Marketplace plugin '${id}' requires a name.`);
  const packagePath = String(value.packagePath || "").trim() || null;
  const packageUrl = String(value.packageUrl || "").trim() || null;
  if (Boolean(packagePath) === Boolean(packageUrl)) {
    throw new Error(`Marketplace plugin '${id}' must declare exactly one package source.`);
  }
  if (packagePath) normalizeRelativePackagePath(packagePath);
  if (packageUrl) normalizeRemoteUrl(packageUrl, "Marketplace package");
  const checksum = String(value.sha256 || "").trim().toLowerCase();
  if (checksum && !/^[a-f0-9]{64}$/.test(checksum)) {
    throw new Error(`Marketplace plugin '${id}' has an invalid checksum.`);
  }
  const signature = normalizeMarketplaceSignature(value.signature);
  const dataVersion = value.dataVersion == null ? 1 : Number(value.dataVersion);
  if (!Number.isInteger(dataVersion) || dataVersion < 1) {
    throw new Error(`Marketplace plugin '${id}' has an invalid dataVersion.`);
  }
  const releaseNotes = String(value.releaseNotes || "").trim();
  if (Buffer.byteLength(releaseNotes, "utf8") > 32 * 1024) {
    throw new Error(`Marketplace plugin '${id}' release notes are too large.`);
  }
  return {
    id,
    name,
    version,
    description: String(value.description || "").trim(),
    publisher: String(value.publisher || "").trim(),
    category: String(value.category || "Other").trim(),
    icon: String(value.icon || "shippingbox").trim(),
    verified: value.verified === true,
    featured: value.featured === true,
    packagePath,
    packageUrl,
    sha256: checksum || null,
    signature,
    dataVersion,
    releaseNotes,
    platforms: Array.isArray(value.platforms) ? value.platforms.map(String) : [],
    permissions: Array.isArray(value.permissions) ? value.permissions.map(String) : [],
    repositoryUrl: String(value.repositoryUrl || "").trim() || null,
    privacyUrl: String(value.privacyUrl || "").trim() || null
  };
}

function normalizeBlockedVersions(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("Marketplace blockedVersions must be an array.");
  const entries = value.map((entry) => {
    const pluginId = normalizePluginId(entry?.pluginId);
    const version = String(entry?.version || "").trim();
    const reason = String(entry?.reason || "").trim();
    const severity = String(entry?.severity || "high").trim().toLowerCase();
    if (!SEMVER_PATTERN.test(version) || !reason
        || !["low", "medium", "high", "critical"].includes(severity)) {
      throw new Error("Marketplace blocked version entry is invalid.");
    }
    return { pluginId, version, reason, severity };
  });
  if (new Set(entries.map((entry) => `${entry.pluginId}\0${entry.version}`)).size !== entries.length) {
    throw new Error("Marketplace blocked versions must be unique.");
  }
  return entries;
}

function findBlockedVersion(registry, pluginId, version) {
  return registry.blockedVersions.find(
    (entry) => entry.pluginId === pluginId && entry.version === version
  ) || null;
}

function sameStringSet(left, right) {
  const a = [...new Set((left || []).map(String))].sort();
  const b = [...new Set((right || []).map(String))].sort();
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

function normalizeMarketplacePublishers(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("Marketplace publishers must be an array.");
  const publishers = value.map((publisher) => {
    const id = normalizePluginId(publisher?.id);
    const name = String(publisher?.name || "").trim();
    const status = String(publisher?.status || "approved").trim().toLowerCase();
    if (!name || !Array.isArray(publisher.keys) || !publisher.keys.length) {
      throw new Error(`Marketplace publisher '${id}' requires a name and public keys.`);
    }
    if (!["approved", "suspended"].includes(status)) {
      throw new Error(`Marketplace publisher '${id}' has an invalid status.`);
    }
    const keys = publisher.keys.map((key) => {
      const keyId = String(key?.keyId || "").trim();
      const publicKey = String(key?.publicKey || "").trim();
      const keyStatus = String(key?.status || "active").trim().toLowerCase();
      if (key?.algorithm !== "ed25519"
          || !/^ed25519:[a-f0-9]{32}$/.test(keyId)
          || !/^[A-Za-z0-9+/]+={0,2}$/.test(publicKey)
          || !["active", "retired", "revoked"].includes(keyStatus)) {
        throw new Error(`Marketplace publisher '${id}' has an invalid key.`);
      }
      return {
        algorithm: "ed25519",
        keyId,
        publicKey,
        status: keyStatus,
        addedAt: String(key?.addedAt || "").trim() || null,
        retiredAt: String(key?.retiredAt || "").trim() || null,
        revokedAt: String(key?.revokedAt || "").trim() || null,
        revocationReason: String(key?.revocationReason || "").trim() || null
      };
    });
    if (new Set(keys.map((key) => key.keyId)).size !== keys.length) {
      throw new Error(`Marketplace publisher '${id}' has duplicate keys.`);
    }
    return {
      id,
      name,
      status,
      repositoryUrl: String(publisher?.repositoryUrl || "").trim() || null,
      approvedAt: String(publisher?.approvedAt || "").trim() || null,
      suspendedAt: String(publisher?.suspendedAt || "").trim() || null,
      suspensionReason: String(publisher?.suspensionReason || "").trim() || null,
      keys
    };
  });
  if (new Set(publishers.map((publisher) => publisher.id)).size !== publishers.length) {
    throw new Error("Marketplace publisher ids must be unique.");
  }
  return publishers;
}

function normalizeMarketplaceSignature(value) {
  if (value == null) return null;
  const publisherId = normalizePluginId(value.publisherId);
  const keyId = String(value.keyId || "").trim();
  if (value.algorithm !== "ed25519" || !/^ed25519:[a-f0-9]{32}$/.test(keyId)) {
    throw new Error("Marketplace plugin signature reference is invalid.");
  }
  return { algorithm: "ed25519", publisherId, keyId };
}

async function readMarketplacePackage(plugin, loaded) {
  if (loaded.sourceType === "file") {
    if (!plugin.packagePath) {
      throw new Error("A local Marketplace registry must use packagePath entries.");
    }
    const target = path.resolve(loaded.base, plugin.packagePath);
    const relative = path.relative(loaded.base, target);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error("Marketplace package path must stay inside the registry directory.");
    }
    const value = await fs.readFile(target);
    if (value.byteLength > MAX_PACKAGE_BYTES) throw new Error("Marketplace package is too large.");
    return value;
  }
  const url = plugin.packageUrl
    ? normalizeRemoteUrl(plugin.packageUrl, "Marketplace package")
    : new URL(normalizeRelativePackagePath(plugin.packagePath), loaded.base);
  const response = await fetch(url, {
    headers: { accept: "application/zip, application/octet-stream" },
    redirect: "follow",
    signal: AbortSignal.timeout(30_000)
  });
  if (!response.ok) throw Object.assign(new Error(`Marketplace package returned ${response.status}.`), { status: 502 });
  normalizeRemoteUrl(response.url, "Marketplace package redirect");
  const value = Buffer.from(await response.arrayBuffer());
  if (value.byteLength > MAX_PACKAGE_BYTES) throw new Error("Marketplace package is too large.");
  return value;
}

function normalizePluginId(value) {
  const id = String(value || "").trim().toLowerCase();
  if (!PLUGIN_ID_PATTERN.test(id)) throw new Error("Marketplace plugin id is invalid.");
  return id;
}

function normalizeRelativePackagePath(value) {
  const name = String(value || "").replaceAll("\\", "/").replace(/^\.\/+/, "");
  if (!name || name.startsWith("/") || name.split("/").some((segment) => !segment || segment === "." || segment === "..")) {
    throw new Error("Marketplace packagePath is invalid.");
  }
  return name;
}

function normalizeRemoteUrl(value, label) {
  const url = new URL(String(value || ""));
  const loopback = ["localhost", "127.0.0.1", "::1"].includes(url.hostname.replace(/^\[|\]$/g, ""));
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new Error(`${label} must use HTTPS except for loopback development.`);
  }
  if (url.username || url.password || url.hash) throw new Error(`${label} URL is invalid.`);
  return url;
}
