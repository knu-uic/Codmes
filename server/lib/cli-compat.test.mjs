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

test("codmes CLI configures the local KNU MCP in one server-side command", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-cli-local-knu-"));
  const configured = spawnSync(process.execPath, [path.join(repoRoot, "bin", "codmes.mjs"), "mcp", "setup-local-knu", "--from-env", "MCP_AUTH_TOKEN", "--root", root], {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, MCP_AUTH_TOKEN: "local-knu-secret" }
  });
  assert.equal(configured.status, 0, configured.stderr);
  assert.doesNotMatch(configured.stdout, /local-knu-secret/);
  const config = JSON.parse(await fs.readFile(path.join(root, ".codmes", "config", "auth.json"), "utf8"));
  assert.equal(config.mcp_credentials["knu-rag"].token, "local-knu-secret");
  const yaml = await fs.readFile(path.join(root, ".codmes", "config", "config.yaml"), "utf8");
  assert.match(yaml, /url: http:\/\/127\.0\.0\.1:8000\/api\/mcp\//);
  assert.match(yaml, /surfaces:\n\s+- chat/);
});
