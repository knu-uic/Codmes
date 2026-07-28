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
