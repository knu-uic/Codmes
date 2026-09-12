#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtimeRoot = path.join(repoRoot, ".codmes-runtime");
const vendorRoot = path.join(repoRoot, "vendor", "hermes-agent");
const documentRequirements = path.join(repoRoot, "server", "workers", "document-ingest", "requirements.lock.txt");
const isWindows = process.platform === "win32";
const runtimePython = path.join(runtimeRoot, isWindows ? "Scripts/python.exe" : "bin/python");

if (!fs.existsSync(path.join(vendorRoot, "pyproject.toml"))) {
  throw new Error("Vendored runtime metadata is missing.");
}

const bootstrapPython = findPython();
if (!fs.existsSync(runtimePython)) {
  run(bootstrapPython, ["-m", "venv", runtimeRoot]);
}

run(runtimePython, ["-m", "pip", "install", "--disable-pip-version-check", "-e", vendorRoot]);
if (process.env.CODMES_SKIP_DOCUMENT_DEPS !== "1" && fs.existsSync(documentRequirements)) {
  run(runtimePython, ["-m", "pip", "install", "--disable-pip-version-check", "-r", documentRequirements]);
}
console.log(`Codmes runtime ready: ${runtimePython}`);

function findPython() {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  for (const command of [
    process.env.CODMES_BOOTSTRAP_PYTHON,
    home && path.join(home, ".hermes", "hermes-agent", "venv", isWindows ? "Scripts/python.exe" : "bin/python"),
    "python3",
    "python"
  ].filter(Boolean)) {
    const result = spawnSync(command, ["-c", "import sys; assert (3, 11) <= sys.version_info[:2] < (3, 14)"], {
      stdio: "ignore"
    });
    if (!result.error && result.status === 0) return command;
  }
  throw new Error("Python 3.11-3.13 is required to install the Codmes runtime.");
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
