import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  createPublisherKeyPair,
  verifyPluginPackageSignature
} from "./plugin-package.mjs";
import { preparePluginRelease } from "./plugin-publisher.mjs";

test("Publisher release preparation signs an asset and atomically updates a required registry", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-publisher-release-"));
  const source = await createPluginSource(root);
  const output = path.join(root, "dist");
  const registry = path.join(root, "registry", "index.json");
  const publisher = createPublisherKeyPair("com.example.publisher");
  const result = await preparePluginRelease({
    sourcePath: source,
    outputDirectory: output,
    registryPath: registry,
    packageUrl: "https://github.com/example/plugins/releases/download/v1.0.0/com.example.demo-1.0.0.codmes-plugin",
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId,
    category: "Productivity",
    releaseNotes: "Adds safer storage migration."
  });

  const archive = await fs.readFile(result.packagePath);
  assert.equal(verifyPluginPackageSignature(archive, publisher.identity).valid, true);
  const index = JSON.parse(await fs.readFile(registry, "utf8"));
  assert.equal(index.signaturePolicy, "required");
  assert.equal(index.publishers[0].keys[0].keyId, publisher.identity.keyId);
  assert.equal(index.plugins[0].signature.keyId, publisher.identity.keyId);
  assert.equal(index.plugins[0].packageUrl, result.packageUrl);
  assert.equal(index.plugins[0].sha256, result.sha256);
  assert.equal(index.plugins[0].dataVersion, 1);
  assert.deepEqual(index.plugins[0].formFactors, ["desktop", "phone"]);
  assert.equal(index.plugins[0].releaseNotes, "Adds safer storage migration.");
});

test("Publisher release preparation requires the URL to match the versioned asset name", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-publisher-url-"));
  const source = await createPluginSource(root);
  const publisher = createPublisherKeyPair("com.example.publisher");
  await assert.rejects(
    () => preparePluginRelease({
      sourcePath: source,
      outputDirectory: path.join(root, "dist"),
      registryPath: path.join(root, "index.json"),
      packageUrl: "https://example.com/wrong.codmes-plugin",
      signingKey: publisher.privateKey,
      publisherId: publisher.identity.publisherId
    }),
    /must end with/
  );
});

test("Publisher release preparation creates a Registry-local package and entry without manual JSON edits", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-publisher-marketplace-"));
  const source = await createPluginSource(root);
  const registry = path.join(root, "registry", "index.json");
  const publisher = createPublisherKeyPair("com.example.publisher");

  const result = await preparePluginRelease({
    sourcePath: source,
    registryPath: registry,
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId,
    category: "Productivity",
    releaseNotes: "Adds a native card layout."
  });

  assert.equal(result.packageUrl, null);
  assert.equal(result.registryPackagePath, "packages/com.example.demo/1.0.0.codmes-plugin");
  assert.equal(
    result.packagePath,
    path.join(root, "registry", "packages", "com.example.demo", "1.0.0.codmes-plugin")
  );
  const archive = await fs.readFile(result.packagePath);
  assert.equal(verifyPluginPackageSignature(archive, publisher.identity).valid, true);
  const index = JSON.parse(await fs.readFile(registry, "utf8"));
  assert.equal(index.plugins[0].version, "1.0.0");
  assert.equal(index.plugins[0].packagePath, result.registryPackagePath);
  assert.equal(index.plugins[0].packageUrl, null);
  assert.equal(index.plugins[0].sha256, result.sha256);
  assert.equal(index.plugins[0].releaseNotes, "Adds a native card layout.");
  assert.ok(Date.parse(index.updatedAt));
});

test("Publisher release preparation reuses an existing signed Release asset byte-for-byte", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-publisher-existing-"));
  const source = await createPluginSource(root);
  const registry = path.join(root, "registry", "index.json");
  const packageDirectory = path.join(root, "registry", "packages", "demo-plugin");
  const packagePath = path.join(packageDirectory, "1.0.0.codmes-plugin");
  const publisher = createPublisherKeyPair("com.example.publisher");
  await fs.mkdir(packageDirectory, { recursive: true });
  const originallyPacked = await import("./plugin-package.mjs").then(({ packPluginPackage }) =>
    packPluginPackage(source, packagePath, {
      signingKey: publisher.privateKey,
      publisherId: publisher.identity.publisherId
    })
  );
  const originalBytes = await fs.readFile(packagePath);

  const result = await preparePluginRelease({
    sourcePath: source,
    registryPath: registry,
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId,
    packageDirectory: "demo-plugin",
    releaseNotes: "Uses the exact GitHub Release asset."
  });

  assert.deepEqual(await fs.readFile(packagePath), originalBytes);
  assert.equal(result.sha256, originallyPacked.sha256);
  const index = JSON.parse(await fs.readFile(registry, "utf8"));
  assert.equal(index.plugins[0].sha256, originallyPacked.sha256);
  assert.equal(index.plugins[0].packagePath, "packages/demo-plugin/1.0.0.codmes-plugin");
});

test("Publisher release preparation rejects unsafe package directory names", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-publisher-directory-"));
  const source = await createPluginSource(root);
  const publisher = createPublisherKeyPair("com.example.publisher");
  await assert.rejects(
    () => preparePluginRelease({
      sourcePath: source,
      registryPath: path.join(root, "registry", "index.json"),
      signingKey: publisher.privateKey,
      publisherId: publisher.identity.publisherId,
      packageDirectory: "../escape"
    }),
    /lowercase id or slug/
  );
});

async function createPluginSource(root) {
  const source = path.join(root, "source");
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.demo",
    version: "1.0.0",
    name: "Demo",
    description: "Signed demo plugin",
    publisher: "Example",
    platforms: ["macos", "ios"],
    permissions: ["storage:workspace"],
    storage: "storage.json",
    surface: {
      id: "demo",
      type: "declarative",
      title: "Demo",
      icon: "shippingbox",
      upstreamUrl: "http://127.0.0.1",
      entryPath: "/",
      ui: "surface.json"
    }
  }));
  await fs.writeFile(path.join(source, "storage.json"), JSON.stringify({
    schemaVersion: 1,
    collections: [{
      id: "items",
      itemSchema: {
        type: "object",
        properties: { id: { type: "string" }, title: { type: "string" } },
        required: ["title"]
      }
    }]
  }));
  await fs.writeFile(path.join(source, "surface.json"), JSON.stringify({
    schemaVersion: 2,
    routes: [{
      id: "items",
      title: "Items",
      dataSources: [{ id: "items", path: "collection:items" }],
      document: {
        schemaVersion: 2,
        presentation: "collection",
        title: "Items",
        editor: {
          collection: "items",
          fields: [{ id: "title", label: "Title", type: "text", required: true }]
        },
        collection: {
          source: "items.items",
          item: { id: "id", title: "title" }
        }
      }
    }]
  }));
  return source;
}
