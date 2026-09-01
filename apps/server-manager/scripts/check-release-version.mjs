import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const managerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(managerRoot, "../..");
const rootPackage = readJson(path.join(repoRoot, "package.json"));
const managerPackage = readJson(path.join(managerRoot, "package.json"));
const tauriConfig = readJson(path.join(managerRoot, "src-tauri/tauri.conf.json"));
const cargoToml = fs.readFileSync(path.join(managerRoot, "src-tauri/Cargo.toml"), "utf8");
const cargoVersion = cargoToml.match(/^version\s*=\s*"([^"]+)"/m)?.[1];

const versions = {
  "Codmes product": rootPackage.version,
  "Server Manager package": managerPackage.version,
  "Server Manager Tauri bundle": tauriConfig.version,
  "Server Manager native binary": cargoVersion,
};
const expected = rootPackage.version;
for (const [component, version] of Object.entries(versions)) {
  if (version !== expected) {
    throw new Error(`${component} version ${version || "<missing>"} must match ${expected}.`);
  }
}

const releasePrefix = "codmes-server-v";
const tag = process.env.GITHUB_REF_NAME || "";
if (tag.startsWith(releasePrefix) && tag.slice(releasePrefix.length) !== expected) {
  throw new Error(`Release tag ${tag} must match Codmes Server ${expected}.`);
}

console.log(`Codmes Server release version ${expected} is consistent.`);

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}
