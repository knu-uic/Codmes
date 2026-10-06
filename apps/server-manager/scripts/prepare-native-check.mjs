import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Tauri validates configured resource paths even when compiling unit tests.
// A clean checkout has no generated runtime yet. Only create its empty root;
// standalone packaging must still run stage:runtime --require-postgres.
export function prepareNativeCheck(managerRoot) {
  mkdirSync(path.join(managerRoot, "builds", "runtime"), { recursive: true });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  prepareNativeCheck(path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."));
}
