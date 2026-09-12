import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const managerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(managerRoot, "../..");
const stageRoot = path.join(managerRoot, "runtime");
const appRoot = path.join(stageRoot, "codmes");
const binRoot = path.join(stageRoot, "bin");
const pythonBuildRoot = path.join(stageRoot, ".python-build");
const nodeName = process.platform === "win32" ? "node.exe" : "node";
const uvCommand = process.env.CODMES_MANAGER_UV || (process.platform === "win32" ? "uv.exe" : "uv");

await fs.rm(appRoot, { recursive: true, force: true });
await fs.rm(binRoot, { recursive: true, force: true });
await fs.rm(pythonBuildRoot, { recursive: true, force: true });
await fs.mkdir(appRoot, { recursive: true });
await fs.mkdir(binRoot, { recursive: true });

for (const entry of ["server", "bin", "bundled", "vendor", "package.json", "package-lock.json"]) {
  await fs.cp(path.join(repoRoot, entry), path.join(appRoot, entry), { recursive: true });
}

await stagePortablePython();
await stagePortablePostgres();

if (process.platform === "win32") {
  // Node's spawn does not reliably execute .cmd shims directly on Windows.
  // Invoke npm through the system command interpreter without enabling a shell
  // for any of the other runtime-packaging commands.
  await run(process.env.ComSpec || "cmd.exe", [
    "/d",
    "/s",
    "/c",
    "npm",
    "ci",
    "--omit=dev",
    "--ignore-scripts",
  ], appRoot);
} else {
  await run("npm", ["ci", "--omit=dev", "--ignore-scripts"], appRoot);
}
await fs.copyFile(process.execPath, path.join(binRoot, nodeName));
if (process.platform !== "win32") await fs.chmod(path.join(binRoot, nodeName), 0o755);

console.log(`[server-manager] staged Codmes runtime at ${stageRoot}`);

async function stagePortablePython() {
  const uvEnvironment = { ...process.env, UV_PYTHON_INSTALL_DIR: pythonBuildRoot };
  await run(uvCommand, ["python", "install", "3.11", "--install-dir", pythonBuildRoot, "--force"], repoRoot, uvEnvironment);
  const pythonExecutable = (await runCapture(
    uvCommand,
    ["python", "find", "3.11", "--managed-python"],
    repoRoot,
    uvEnvironment,
  )).trim();
  if (!path.isAbsolute(pythonExecutable)) {
    throw new Error(`uv returned an invalid Python path: ${pythonExecutable}`);
  }
  await run(
    uvCommand,
    [
      "pip",
      "install",
      "--python",
      pythonExecutable,
      "--system",
      "--break-system-packages",
      "--requirements",
      path.join(repoRoot, "server/workers/document-ingest/requirements.lock.txt"),
    ],
    repoRoot,
    uvEnvironment,
  );

  const distributionRoot = process.platform === "win32"
    ? path.dirname(pythonExecutable)
    : path.dirname(path.dirname(pythonExecutable));
  const portableRoot = path.join(appRoot, ".codmes-runtime");
  await fs.cp(distributionRoot, portableRoot, { recursive: true, dereference: true });
  if (process.platform !== "win32") {
    const portablePython = path.join(portableRoot, "bin", "python");
    await fs.copyFile(pythonExecutable, portablePython);
    await fs.chmod(portablePython, 0o755);
  }
  const packagedPython = process.platform === "win32"
    ? path.join(portableRoot, "python.exe")
    : path.join(portableRoot, "bin", "python");
  await run(packagedPython, [
    "-c",
    "import fitz, pymupdf4llm, PIL, openpyxl, docx, pptx; print('portable document runtime ready')",
  ], appRoot);
  await fs.rm(pythonBuildRoot, { recursive: true, force: true });
}

async function stagePortablePostgres() {
  const sourceRoot = String(process.env.CODMES_MANAGER_POSTGRES_ROOT || "").trim();
  if (!sourceRoot) {
    if (process.argv.includes("--require-postgres")) {
      throw new Error("Standalone release requires CODMES_MANAGER_POSTGRES_ROOT with a portable PostgreSQL + pgvector + pg_trgm runtime.");
    }
    console.warn("[server-manager] PostgreSQL runtime not staged; set CODMES_MANAGER_POSTGRES_ROOT for a standalone multi-user release.");
    return;
  }
  const resolvedSource = path.resolve(sourceRoot);
  const requiredExecutables = ["postgres", "initdb", "pg_ctl", "psql", "createdb", "pg_dump", "pg_restore"]
    .map((name) => process.platform === "win32" ? `${name}.exe` : name);
  for (const executable of requiredExecutables) {
    await requireFile(path.join(resolvedSource, "bin", executable), `PostgreSQL executable ${executable}`);
  }
  await requireFile(path.join(resolvedSource, "share", "extension", "vector.control"), "pgvector extension metadata");
  await requireFile(path.join(resolvedSource, "share", "extension", "pg_trgm.control"), "pg_trgm extension metadata");
  const extensionSql = (await fs.readdir(path.join(resolvedSource, "share", "extension")))
    .some((name) => /^vector--.*\.sql$/i.test(name));
  if (!extensionSql) throw new Error("Portable PostgreSQL runtime does not contain pgvector SQL files.");
  const libraryNames = (await Promise.all([
    path.join(resolvedSource, "lib"),
    path.join(resolvedSource, "lib", "postgresql"),
    path.join(resolvedSource, "bin")
  ].map((directory) => fs.readdir(directory).catch(() => [])))).flat();
  if (!libraryNames.some((name) => /^vector(?:\.dylib|\.dll|\.so(?:\.\d+)*)$/i.test(name))) {
    throw new Error("Portable PostgreSQL runtime does not contain the pgvector shared library.");
  }
  if (!libraryNames.some((name) => /^pg_trgm(?:\.dylib|\.dll|\.so(?:\.\d+)*)$/i.test(name))) {
    throw new Error("Portable PostgreSQL runtime does not contain the pg_trgm shared library.");
  }
  const destination = path.join(appRoot, "bundled", "postgres");
  await fs.rm(destination, { recursive: true, force: true });
  await fs.cp(resolvedSource, destination, { recursive: true, dereference: true });
  console.log(`[server-manager] staged PostgreSQL + pgvector + pg_trgm from ${resolvedSource}`);
}

async function requireFile(filePath, label) {
  const stat = await fs.stat(filePath).catch(() => null);
  if (!stat?.isFile()) throw new Error(`${label} is missing: ${filePath}`);
}

function run(command, args, cwd, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)));
  });
}

function runCapture(command, args, cwd, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "inherit"] });
    let output = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve(output) : reject(new Error(`${command} exited with ${code}`)));
  });
}
