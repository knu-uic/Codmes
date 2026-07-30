import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  createPublisherKeyPair,
  packPluginPackage
} from "./plugin-package.mjs";
import {
  approvePublisherApplication,
  buildStaticMarketplaceRegistry,
  createPublisherApplication,
  revokePublisherKey,
  rotatePublisherKey,
  validateRegistryForPublication,
  verifyPublisherApplication
} from "./plugin-registry-operations.mjs";

test("reviewed Registry approves a signed publisher application and builds static hosting output", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-registry-operations-"));
  const registryPath = path.join(root, "marketplace", "index.json");
  const applicationPath = path.join(root, "publisher-application.json");
  const source = path.join(root, "source");
  const packagePath = path.join(root, "marketplace", "packages", "demo.codmes-plugin");
  const output = path.join(root, "public");
  const publisher = createPublisherKeyPair("com.example.publisher");
  const application = createPublisherApplication({
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId,
    name: "Example Publisher",
    repositoryUrl: "https://github.com/example/plugins",
    contact: "security@example.com"
  });
  assert.equal(verifyPublisherApplication(application).valid, true);
  await fs.mkdir(path.dirname(registryPath), { recursive: true });
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    updatedAt: new Date().toISOString(),
    signaturePolicy: "required",
    governancePolicy: "reviewed",
    publishers: [],
    blockedVersions: [],
    plugins: []
  }));
  await fs.writeFile(applicationPath, JSON.stringify(application));
  const approved = await approvePublisherApplication(registryPath, applicationPath);
  assert.equal(approved.publisherId, "com.example.publisher");

  await createPluginSource(source);
  const packed = await packPluginPackage(source, packagePath, {
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId
  });
  const registry = JSON.parse(await fs.readFile(registryPath, "utf8"));
  registry.plugins = [{
    id: "com.example.demo",
    name: "Demo",
    version: "1.0.0",
    description: "Registry fixture",
    publisher: "Example Publisher",
    category: "Productivity",
    icon: "shippingbox",
    packagePath: "packages/demo.codmes-plugin",
    sha256: packed.sha256,
    signature: packed.signature,
    dataVersion: 1,
    releaseNotes: "Initial reviewed release.",
    platforms: ["macos", "ios"],
    permissions: ["storage:workspace"]
  }];
  await fs.writeFile(registryPath, JSON.stringify(registry));

  const validation = await validateRegistryForPublication(registryPath, {
    production: true,
    verifyAssets: true
  });
  assert.equal(validation.valid, true);
  const built = await buildStaticMarketplaceRegistry({
    registryPath,
    outputDirectory: output,
    production: true
  });
  assert.equal(built.built, true);
  assert.deepEqual(
    await fs.readFile(path.join(output, "packages", "demo.codmes-plugin")),
    await fs.readFile(packagePath)
  );
  assert.match(await fs.readFile(path.join(output, "_headers"), "utf8"), /max-age=300/);
  const health = JSON.parse(await fs.readFile(path.join(output, "health.json"), "utf8"));
  assert.equal(health.pluginCount, 1);
  assert.match(health.registrySha256, /^[a-f0-9]{64}$/);
});

test("publisher key rotation retires the old key and revocation blocks affected releases", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-registry-key-rotation-"));
  const registryPath = path.join(root, "index.json");
  const oldKey = createPublisherKeyPair("com.example.publisher");
  const nextKey = createPublisherKeyPair("com.example.publisher");
  await fs.writeFile(registryPath, JSON.stringify({
    schemaVersion: 1,
    updatedAt: new Date().toISOString(),
    signaturePolicy: "required",
    governancePolicy: "reviewed",
    publishers: [{
      id: "com.example.publisher",
      name: "Example",
      status: "approved",
      keys: [{
        algorithm: "ed25519",
        keyId: oldKey.identity.keyId,
        publicKey: oldKey.identity.publicKey,
        status: "active"
      }]
    }],
    blockedVersions: [],
    plugins: [{
      id: "com.example.demo",
      name: "Demo",
      version: "1.0.0",
      packageUrl: "https://plugins.example.com/demo.codmes-plugin",
      sha256: "0".repeat(64),
      signature: {
        algorithm: "ed25519",
        publisherId: "com.example.publisher",
        keyId: oldKey.identity.keyId
      },
      releaseNotes: "Initial release."
    }]
  }));

  await rotatePublisherKey(registryPath, nextKey.identity);
  let registry = JSON.parse(await fs.readFile(registryPath, "utf8"));
  assert.equal(
    registry.publishers[0].keys.find((key) => key.keyId === oldKey.identity.keyId).status,
    "retired"
  );
  assert.equal(
    registry.publishers[0].keys.find((key) => key.keyId === nextKey.identity.keyId).status,
    "active"
  );

  const revoked = await revokePublisherKey(
    registryPath,
    "com.example.publisher",
    oldKey.identity.keyId,
    "Private key was exposed."
  );
  assert.deepEqual(revoked.affectedVersions, [{
    pluginId: "com.example.demo",
    version: "1.0.0"
  }]);
  registry = JSON.parse(await fs.readFile(registryPath, "utf8"));
  assert.equal(registry.blockedVersions[0].severity, "critical");
  assert.match(registry.blockedVersions[0].reason, /Private key was exposed/);
});

test("publisher application proof rejects modified review metadata", () => {
  const publisher = createPublisherKeyPair("com.example.publisher");
  const application = createPublisherApplication({
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId,
    name: "Example",
    repositoryUrl: "https://github.com/example/plugins"
  });
  application.publisher.name = "Impostor";
  assert.throws(() => verifyPublisherApplication(application), /proof is invalid/);
});

async function createPluginSource(source) {
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.demo",
    version: "1.0.0",
    name: "Demo",
    platforms: ["macos", "ios"],
    permissions: ["storage:workspace"]
  }));
}
