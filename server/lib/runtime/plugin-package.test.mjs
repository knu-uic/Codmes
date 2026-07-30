import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { strToU8, zipSync } from "fflate";

import {
  createPublisherKeyPair,
  extractPluginPackage,
  inspectPluginPackage,
  packPluginPackage,
  verifyPluginPackageSignature
} from "./plugin-package.mjs";

test("Codmes plugin package round-trips a manifest and its Surface UI", async () => {
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-package-source-"));
  const output = path.join(await fs.mkdtemp(path.join(os.tmpdir(), "codmes-package-output-")), "demo.codmes-plugin");
  const extracted = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-package-extracted-"));
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.demo",
    version: "1.2.3",
    surface: { ui: "surface.json" },
    tools: "tools.json",
    migrations: "migrations.json"
  }));
  await fs.writeFile(path.join(source, "surface.json"), JSON.stringify({
    schemaVersion: 1,
    routes: []
  }));
  await fs.writeFile(path.join(source, "README.md"), "# Demo\n");
  await fs.writeFile(path.join(source, "tools.json"), JSON.stringify({
    schemaVersion: 1,
    tools: []
  }));
  await fs.writeFile(path.join(source, "migrations.json"), JSON.stringify({
    schemaVersion: 1,
    migrations: []
  }));

  const packed = await packPluginPackage(source, output);
  const archive = await fs.readFile(output);
  const inspected = inspectPluginPackage(archive);
  const result = await extractPluginPackage(archive, extracted);

  assert.equal(packed.pluginId, "com.example.demo");
  assert.equal(packed.version, "1.2.3");
  assert.equal(packed.sha256, inspected.sha256);
  assert.equal(result.sha256, inspected.sha256);
  assert.equal(JSON.parse(await fs.readFile(path.join(extracted, "plugin.json"))).id, "com.example.demo");
  assert.equal(JSON.parse(await fs.readFile(path.join(extracted, "surface.json"))).schemaVersion, 1);
  assert.equal(JSON.parse(await fs.readFile(path.join(extracted, "tools.json"))).schemaVersion, 1);
  assert.equal(JSON.parse(await fs.readFile(path.join(extracted, "migrations.json"))).schemaVersion, 1);
  assert.equal(await fs.readFile(path.join(extracted, "README.md"), "utf8"), "# Demo\n");
});

test("Codmes plugin package rejects traversal paths and metadata mismatches", () => {
  const traversal = Buffer.from(zipSync({
    "../plugin.json": strToU8("{}")
  }));
  assert.throws(() => inspectPluginPackage(traversal), /unsafe file path/);

  const mismatch = Buffer.from(zipSync({
    "plugin.json": strToU8(JSON.stringify({ id: "com.example.demo", version: "1.0.0" })),
    "codmes-package.json": strToU8(JSON.stringify({
      formatVersion: 1,
      pluginId: "com.example.other",
      version: "1.0.0"
    }))
  }));
  assert.throws(() => inspectPluginPackage(mismatch), /metadata id/);
});

test("Codmes plugin package signs every packaged file with an Ed25519 publisher key", async () => {
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-signed-package-source-"));
  const output = path.join(await fs.mkdtemp(path.join(os.tmpdir(), "codmes-signed-package-output-")), "signed.codmes-plugin");
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.signed",
    version: "2.0.0",
    name: "Signed"
  }));
  const publisher = createPublisherKeyPair("com.example.publisher");
  const packed = await packPluginPackage(source, output, {
    signingKey: publisher.privateKey,
    publisherId: publisher.identity.publisherId
  });
  const archive = await fs.readFile(output);
  const verified = verifyPluginPackageSignature(archive, publisher.identity);

  assert.equal(packed.signature.publisherId, "com.example.publisher");
  assert.equal(verified.valid, true);
  assert.equal(verified.pluginId, "com.example.signed");

  const inspected = inspectPluginPackage(archive);
  const tamperedFiles = Object.fromEntries(
    [...inspected.files].map(([name, bytes]) => [name, new Uint8Array(bytes)])
  );
  tamperedFiles["plugin.json"] = strToU8(JSON.stringify({
    ...inspected.manifest,
    name: "Tampered"
  }));
  const tampered = Buffer.from(zipSync(tamperedFiles));
  assert.throws(
    () => verifyPluginPackageSignature(tampered, publisher.identity),
    /signature is invalid/
  );
});
