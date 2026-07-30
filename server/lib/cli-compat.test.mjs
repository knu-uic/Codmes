import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

test("codmes CLI exposes help", () => {
  const codmes = spawnSync(process.execPath, [path.join(repoRoot, "bin", "codmes.mjs"), "--help"], {
    cwd: repoRoot,
    encoding: "utf8"
  });
  assert.equal(codmes.status, 0);
  assert.match(codmes.stdout, /Codmes CLI/);
  assert.match(codmes.stdout, /codmes serve/);
});

test("codmes CLI provisions MCP credentials from stdin without echoing the token", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-cli-mcp-"));
  const run = (args, input = "") => spawnSync(process.execPath, [path.join(repoRoot, "bin", "codmes.mjs"), ...args], { cwd: repoRoot, encoding: "utf8", input });
  const set = run(["mcp", "credential", "set", "knu-rag", "--root", root], "cli-remote-secret\n");
  assert.equal(set.status, 0, set.stderr);
  assert.doesNotMatch(set.stdout, /cli-remote-secret/);
  const status = run(["mcp", "credential", "status", "knu-rag", "--root", root]);
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /"configured": true/);
  const remove = run(["mcp", "credential", "remove", "knu-rag", "--root", root]);
  assert.equal(remove.status, 0, remove.stderr);
  assert.doesNotMatch(remove.stdout, /cli-remote-secret/);
});

test("codmes publisher CLI creates keys, signs a plugin, and verifies the package", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-cli-publisher-"));
  const keys = path.join(root, "keys");
  const source = path.join(root, "plugin");
  const output = path.join(root, "demo.codmes-plugin");
  await fs.mkdir(source);
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "com.example.demo",
    version: "1.0.0",
    name: "Demo"
  }));
  const run = (args) => spawnSync(
    process.execPath,
    [path.join(repoRoot, "bin", "codmes.mjs"), ...args],
    { cwd: repoRoot, encoding: "utf8" }
  );
  const initialized = run([
    "plugin", "publisher", "init", "com.example.publisher", "--output", keys
  ]);
  assert.equal(initialized.status, 0, initialized.stderr);
  const packed = run([
    "plugin", "pack", source,
    "--output", output,
    "--sign-key", path.join(keys, "private-key.pem"),
    "--publisher-id", "com.example.publisher"
  ]);
  assert.equal(packed.status, 0, packed.stderr);
  const verified = run([
    "plugin", "verify", output,
    "--public-key", path.join(keys, "publisher.json")
  ]);
  assert.equal(verified.status, 0, verified.stderr);
  assert.equal(JSON.parse(verified.stdout).valid, true);
});

test("codmes Registry CLI approves a publisher application and builds production output", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-cli-registry-"));
  const keys = path.join(root, "keys");
  const application = path.join(root, "application.json");
  const registry = path.join(root, "registry", "index.json");
  const output = path.join(root, "public");
  await fs.mkdir(path.dirname(registry), { recursive: true });
  await fs.writeFile(registry, JSON.stringify({
    schemaVersion: 1,
    updatedAt: new Date().toISOString(),
    signaturePolicy: "required",
    governancePolicy: "reviewed",
    publishers: [],
    blockedVersions: [],
    plugins: []
  }));
  const run = (args) => spawnSync(
    process.execPath,
    [path.join(repoRoot, "bin", "codmes.mjs"), ...args],
    { cwd: repoRoot, encoding: "utf8" }
  );
  assert.equal(run([
    "plugin", "publisher", "init", "com.example.publisher", "--output", keys
  ]).status, 0);
  const applied = run([
    "plugin", "publisher", "apply", "com.example.publisher",
    "--sign-key", path.join(keys, "private-key.pem"),
    "--name", "Example",
    "--repository-url", "https://github.com/example/plugins",
    "--output", application
  ]);
  assert.equal(applied.status, 0, applied.stderr);
  const approved = run([
    "plugin", "registry", "approve", application, "--registry", registry
  ]);
  assert.equal(approved.status, 0, approved.stderr);
  const validated = run([
    "plugin", "registry", "validate", "--registry", registry, "--production"
  ]);
  assert.equal(validated.status, 0, validated.stderr);
  assert.equal(JSON.parse(validated.stdout).valid, true);
  const built = run([
    "plugin", "registry", "build", "--registry", registry,
    "--output-dir", output, "--production"
  ]);
  assert.equal(built.status, 0, built.stderr);
  assert.equal(JSON.parse(built.stdout).built, true);
  assert.equal(JSON.parse(await fs.readFile(path.join(output, "health.json"), "utf8")).publisherCount, 1);
});
