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

await run(process.platform === "win32" ? "npm.cmd" : "npm", ["ci", "--omit=dev", "--ignore-scripts"], appRoot);
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
      path.join(repoRoot, "server/workers/document-ingest/requirements.txt"),
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
