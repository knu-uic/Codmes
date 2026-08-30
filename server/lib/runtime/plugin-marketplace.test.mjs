import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { once } from "node:events";

import {
  installMarketplacePlugin,
  listMarketplacePlugins,
  loadMarketplaceRegistry,
  normalizeMarketplaceRegistry
} from "./plugin-marketplace.mjs";
import { createPublisherKeyPair, packPluginPackage } from "./plugin-package.mjs";
import {
  createRegistryRootKeyPair,
  signMarketplaceRegistry
} from "./plugin-registry-signature.mjs";
import {
  getInstalledPlugin,
  getPluginInstallState,
  installPlugin,
  rollbackPlugin
} from "./plugin-registry.mjs";

test("Marketplace registry accepts only supported Apple platforms", () => {
  const entry = {
    id: "com.example.demo",
    name: "Demo",
    version: "1.0.0",
    packagePath: "demo.codmes-plugin",
    platforms: ["MACOS", "ios", "ios"]
  };
  const registry = normalizeMarketplaceRegistry({ schemaVersion: 1, plugins: [entry] });
  assert.deepEqual(registry.plugins[0].platforms, ["macos", "ios"]);
  assert.throws(
    () => normalizeMarketplaceRegistry({
      schemaVersion: 1,
      plugins: [{ ...entry, platforms: ["android"] }]
    }),
    /unsupported platforms: android/
  );
});

test("Marketplace installs an update atomically and restores the previous plugin version", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-workspace-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-registry-"));
  const v1 = await createPluginSource("1.0.0");
  const v2 = await createPluginSource("1.1.0");
  await installPlugin(workspace, v1);
  const packagePath = path.join(registryDirectory, "packages", "demo-1.1.0.codmes-plugin");
  const publisher = createPublisherKeyPair("com.example.publisher");
  const packed = await packPluginPackage(v2, packagePath, {
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId
  });
  const registryPath = path.join(registryDirectory, "index.json");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    signaturePolicy: "required",
    publishers: [{
      id: publisher.identity.publisherId,
      name: "Example Publisher",
      keys: [{
        algorithm: publisher.identity.algorithm,
        keyId: publisher.identity.keyId,
        publicKey: publisher.identity.publicKey
      }]
    }],
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.1.0",
      publisher: "Example",
      category: "Productivity",
      icon: "calendar",
      verified: true,
      packagePath: "packages/demo-1.1.0.codmes-plugin",
      sha256: packed.sha256,
      signature: packed.signature,
      platforms: ["macos", "ios"],
      permissions: []
    }]
  }));

  const before = await listMarketplacePlugins(workspace, { registrySource: registryPath });
  assert.equal(before.plugins[0].installedVersion, "1.0.0");
  assert.equal(before.plugins[0].updateAvailable, true);

  const installed = await installMarketplacePlugin(workspace, "com.example.demo", {
    registrySource: registryPath
  });
  assert.equal(installed.updated, true);
  assert.equal((await getInstalledPlugin(workspace, "com.example.demo")).version, "1.1.0");
  assert.equal((await getPluginInstallState(workspace, "com.example.demo")).previousVersion, "1.0.0");

  const rolledBack = await rollbackPlugin(workspace, "com.example.demo");
  assert.equal(rolledBack.plugin.version, "1.0.0");
  assert.equal((await getPluginInstallState(workspace, "com.example.demo")).previousVersion, "1.1.0");
});

test("Marketplace required signature policy rejects unsigned packages", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-unsigned-workspace-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-unsigned-registry-"));
  const source = await createPluginSource("1.0.0");
  const packagePath = path.join(registryDirectory, "demo.codmes-plugin");
  const packed = await packPluginPackage(source, packagePath);
  const registryPath = path.join(registryDirectory, "index.json");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    signaturePolicy: "required",
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.0.0",
      packagePath: "demo.codmes-plugin",
      sha256: packed.sha256
    }]
  }));

  await assert.rejects(
    () => installMarketplacePlugin(workspace, "com.example.demo", { registrySource: registryPath }),
    /requires signed plugin packages/
  );
});

test("Marketplace rejects a package signed by a revoked publisher key", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-revoked-workspace-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-revoked-registry-"));
  const source = await createPluginSource("1.0.0");
  const publisher = createPublisherKeyPair("com.example.publisher");
  const packagePath = path.join(registryDirectory, "demo.codmes-plugin");
  const packed = await packPluginPackage(source, packagePath, {
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId
  });
  const registryPath = path.join(registryDirectory, "index.json");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    signaturePolicy: "required",
    governancePolicy: "reviewed",
    publishers: [{
      id: publisher.identity.publisherId,
      name: "Example",
      status: "approved",
      keys: [{
        algorithm: "ed25519",
        keyId: publisher.identity.keyId,
        publicKey: publisher.identity.publicKey,
        status: "revoked",
        revocationReason: "Key exposure."
      }]
    }],
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.0.0",
      packagePath: "demo.codmes-plugin",
      sha256: packed.sha256,
      signature: packed.signature
    }]
  }));
  await assert.rejects(
    () => installMarketplacePlugin(workspace, "com.example.demo", {
      registrySource: registryPath
    }),
    /untrusted publisher key/
  );
});

test("Marketplace refuses a package whose checksum differs from the registry", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-checksum-workspace-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-checksum-registry-"));
  const source = await createPluginSource("1.0.0");
  const packagePath = path.join(registryDirectory, "demo.codmes-plugin");
  await packPluginPackage(source, packagePath);
  const registryPath = path.join(registryDirectory, "index.json");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.0.0",
      packagePath: "demo.codmes-plugin",
      sha256: "0".repeat(64)
    }]
  }));
  await assert.rejects(
    () => installMarketplacePlugin(workspace, "com.example.demo", { registrySource: registryPath }),
    /checksum/
  );
});

test("Marketplace update requires explicit consent when permissions increase", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-permission-workspace-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-permission-registry-"));
  await installPlugin(workspace, await createPluginSource("1.0.0", { permissions: [] }));
  const source = await createPluginSource("1.1.0", {
    permissions: ["network:https://api.example.com"]
  });
  const packagePath = path.join(registryDirectory, "demo.codmes-plugin");
  const packed = await packPluginPackage(source, packagePath);
  const registryPath = path.join(registryDirectory, "index.json");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.1.0",
      packagePath: "demo.codmes-plugin",
      sha256: packed.sha256,
      permissions: ["network:https://api.example.com"],
      releaseNotes: "Adds remote sync."
    }]
  }));

  const listing = await listMarketplacePlugins(workspace, { registrySource: registryPath });
  assert.deepEqual(listing.plugins[0].addedPermissions, ["network:https://api.example.com"]);
  assert.equal(listing.plugins[0].permissionChangeRequired, true);
  await assert.rejects(
    () => installMarketplacePlugin(workspace, "com.example.demo", {
      registrySource: registryPath
    }),
    /requires consent/
  );
  const updated = await installMarketplacePlugin(workspace, "com.example.demo", {
    registrySource: registryPath,
    acceptedPermissions: ["network:https://api.example.com"]
  });
  assert.equal(updated.plugin.version, "1.1.0");
});

test("Marketplace blocks a vulnerable target version before downloading it", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-block-workspace-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-block-registry-"));
  const source = await createPluginSource("1.0.0");
  const packagePath = path.join(registryDirectory, "demo.codmes-plugin");
  const packed = await packPluginPackage(source, packagePath);
  const registryPath = path.join(registryDirectory, "index.json");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    blockedVersions: [{
      pluginId: "com.example.demo",
      version: "1.0.0",
      severity: "critical",
      reason: "Remote code execution vulnerability."
    }],
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.0.0",
      packagePath: "demo.codmes-plugin",
      sha256: packed.sha256
    }]
  }));
  const listing = await listMarketplacePlugins(workspace, { registrySource: registryPath });
  assert.equal(listing.plugins[0].blocked, true);
  assert.match(listing.plugins[0].blockReason, /Remote code execution/);
  await assert.rejects(
    () => installMarketplacePlugin(workspace, "com.example.demo", {
      registrySource: registryPath
    }),
    /version is blocked/
  );
});

test("Marketplace installs a signed plugin from a Registry-relative package path", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-remote-workspace-"));
  const releaseDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-remote-release-"));
  const source = await createPluginSource("2.0.0");
  const publisher = createPublisherKeyPair("com.example.publisher");
  const filename = "com.example.demo-2.0.0.codmes-plugin";
  const packagePath = path.join(releaseDirectory, filename);
  const packed = await packPluginPackage(source, packagePath, {
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId
  });
  let registry;
  const server = http.createServer(async (request, response) => {
    if (request.url === "/index.json") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(registry));
      return;
    }
    if (request.url === `/packages/${filename}`) {
      response.setHeader("content-type", "application/octet-stream");
      response.end(await fs.readFile(packagePath));
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const port = server.address().port;
    registry = {
      schemaVersion: 1,
      signaturePolicy: "required",
      publishers: [{
        id: publisher.identity.publisherId,
        name: "Example",
        keys: [{
          algorithm: publisher.identity.algorithm,
          keyId: publisher.identity.keyId,
          publicKey: publisher.identity.publicKey
        }]
      }],
      plugins: [{
        id: "com.example.demo",
        name: "Demo",
        version: "2.0.0",
        packagePath: `packages/${filename}`,
        sha256: packed.sha256,
        signature: packed.signature
      }]
    };
    const installed = await installMarketplacePlugin(workspace, "com.example.demo", {
      registrySource: `http://127.0.0.1:${port}/index.json`
    });
    assert.equal(installed.plugin.version, "2.0.0");
    assert.equal(installed.marketplace.signature.keyId, publisher.identity.keyId);
  } finally {
    server.close();
    await once(server, "close");
  }
});

test("Trusted remote Registry requires a valid detached root signature", async () => {
  const root = createRegistryRootKeyPair("com.codmes.marketplace");
  let registryBytes = Buffer.from(JSON.stringify({
    schemaVersion: 1,
    plugins: []
  }));
  let signature = signMarketplaceRegistry(registryBytes, {
    signingKey: root.privateKey,
    rootId: root.identity.rootId
  });
  const server = http.createServer((request, response) => {
    if (request.url === "/index.json") {
      response.setHeader("content-type", "application/json");
      response.end(registryBytes);
      return;
    }
    if (request.url === "/index.sig.json") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(signature));
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const registrySource = `http://127.0.0.1:${server.address().port}/index.json`;
    const trustedRegistries = {
      schemaVersion: 1,
      registries: [{
        url: registrySource,
        root: root.identity
      }]
    };
    const loaded = await loadMarketplaceRegistry({
      registrySource,
      trustedRegistries
    });
    assert.equal(loaded.registrySignature.rootId, root.identity.rootId);

    registryBytes = Buffer.from(JSON.stringify({
      schemaVersion: 1,
      plugins: [],
      updatedAt: "tampered"
    }));
    await assert.rejects(
      () => loadMarketplaceRegistry({ registrySource, trustedRegistries }),
      /checksum/
    );
  } finally {
    server.close();
    await once(server, "close");
  }
});

test("Marketplace refuses an update signed by a different publisher", async () => {
  const workspace = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-publisher-pin-"));
  const registryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-marketplace-publisher-registry-"));
  const publisherA = createPublisherKeyPair("com.example.publisher-a");
  const publisherB = createPublisherKeyPair("com.example.publisher-b");
  const registryPath = path.join(registryDirectory, "index.json");

  const writeRelease = async (version, publisher) => {
    const source = await createPluginSource(version);
    const packagePath = path.join(registryDirectory, `demo-${version}.codmes-plugin`);
    const packed = await packPluginPackage(source, packagePath, {
      signingKey: publisher.privateKey,
      publisherId: publisher.identity.publisherId
    });
    await fs.writeFile(registryPath, JSON.stringify({
      schemaVersion: 1,
      signaturePolicy: "required",
      publishers: [publisherA, publisherB].map((candidate) => ({
        id: candidate.identity.publisherId,
        name: candidate.identity.publisherId,
        status: "approved",
        keys: [{
          algorithm: candidate.identity.algorithm,
          keyId: candidate.identity.keyId,
          publicKey: candidate.identity.publicKey,
          status: "active"
        }]
      })),
      plugins: [{
        id: "com.example.demo",
        name: "Demo",
        version,
        packagePath: path.basename(packagePath),
        sha256: packed.sha256,
        signature: packed.signature
      }]
    }));
  };

  await writeRelease("1.0.0", publisherA);
  await installMarketplacePlugin(workspace, "com.example.demo", {
    registrySource: registryPath
  });
  assert.equal(
    (await getPluginInstallState(workspace, "com.example.demo")).source.publisherId,
    publisherA.identity.publisherId
  );

  await writeRelease("1.1.0", publisherB);
  await assert.rejects(
    () => installMarketplacePlugin(workspace, "com.example.demo", {
      registrySource: registryPath
    }),
    /publisher does not match/
  );
});

async function createPluginSource(version, options = {}) {
  const source = await fs.mkdtemp(path.join(os.tmpdir(), `codmes-marketplace-plugin-${version}-`));
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.demo",
    version,
    name: "Demo",
    platforms: ["macos", "ios"],
    permissions: options.permissions || [],
    surface: {
      id: "demo",
      type: "declarative",
      title: "Demo",
      upstreamUrl: "http://127.0.0.1:8000",
      entryPath: "/api/demo",
      navigation: [{ id: "home", title: "Home", path: "/api/demo" }]
    },
    mcp: {
      name: "demo",
      transport: "streamable_http",
      url: "http://127.0.0.1:8000/api/mcp",
      surfaces: ["demo"],
      allowUnauthenticated: true
    }
  }));
  return source;
}
