import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function startManagedPostgres(options = {}) {
  const dataRoot = path.resolve(options.dataRoot || process.env.CODMES_DATA_ROOT || "CodmesData");
  const port = normalizePort(options.port || process.env.CODMES_POSTGRES_PORT || 55432);
  const binDirectory = await findPostgresBin(options.binDirectory);
  const dataDirectory = path.join(dataRoot, "postgres", "data");
  const configDirectory = path.join(dataRoot, "config");
  const passwordPath = path.join(configDirectory, "postgres-password");
  const logPath = path.join(dataRoot, "postgres", "postgres.log");
  await fs.mkdir(configDirectory, { recursive: true });
  await fs.mkdir(path.dirname(dataDirectory), { recursive: true });
  const password = await readOrCreatePassword(passwordPath);
  const initialized = await fileExists(path.join(dataDirectory, "PG_VERSION"));
  if (!initialized) {
    const passwordInputPath = path.join(configDirectory, `postgres-init-${crypto.randomUUID()}.pw`);
    await fs.writeFile(passwordInputPath, `${password}\n`, { mode: 0o600 });
    try {
      await run(path.join(binDirectory, executable("initdb")), [
        "-D", dataDirectory,
        "--username=codmes",
        "--encoding=UTF8",
        "--auth-local=trust",
        "--auth-host=scram-sha-256",
        `--pwfile=${passwordInputPath}`
      ]);
    } finally {
      await fs.unlink(passwordInputPath).catch(() => {});
    }
  }
  const pgCtl = path.join(binDirectory, executable("pg_ctl"));
  const running = await postgresIsRunning(pgCtl, dataDirectory);
  if (!running) {
    await run(pgCtl, [
      "-D", dataDirectory,
      "-l", logPath,
      "-o", `-h 127.0.0.1 -p ${port}`,
      "-w",
      "start"
    ]);
  }
  const clientEnv = { ...process.env, PGPASSWORD: password };
  const exists = await runCapture(path.join(binDirectory, executable("psql")), [
    "-h", "127.0.0.1", "-p", String(port), "-U", "codmes", "-d", "postgres",
    "-tAc", "SELECT 1 FROM pg_database WHERE datname = 'codmes'"
  ], clientEnv);
  if (exists.trim() !== "1") {
    await run(path.join(binDirectory, executable("createdb")), [
      "-h", "127.0.0.1", "-p", String(port), "-U", "codmes", "codmes"
    ], clientEnv);
  }
  return {
    connectionString: `postgresql://codmes:${encodeURIComponent(password)}@127.0.0.1:${port}/codmes`,
    dataDirectory,
    binDirectory,
    port,
    startedByCodmes: !running
  };
}

export async function stopManagedPostgres(instance) {
  if (!instance?.startedByCodmes) return { stopped: false };
  const pgCtl = path.join(instance.binDirectory, executable("pg_ctl"));
  await run(pgCtl, ["-D", instance.dataDirectory, "-m", "fast", "-w", "stop"]);
  return { stopped: true };
}

export async function createManagedBackup(instance, options = {}) {
  if (!instance?.connectionString || !instance?.binDirectory) {
    throw new Error("A running managed PostgreSQL instance is required for backup.");
  }
  const dataRoot = path.resolve(options.dataRoot || process.env.CODMES_DATA_ROOT || "CodmesData");
  const destination = path.resolve(options.destination || path.join(
    dataRoot,
    "backups",
    new Date().toISOString().replace(/[:.]/g, "-")
  ));
  if (await fileExists(destination)) throw new Error(`Backup destination already exists: ${destination}`);
  const staging = `${destination}.partial-${crypto.randomUUID()}`;
  await fs.mkdir(staging, { recursive: true });
  try {
    await run(path.join(instance.binDirectory, executable("pg_dump")), [
      `--dbname=${instance.connectionString}`,
      "--format=custom",
      "--no-owner",
      "--no-privileges",
      `--file=${path.join(staging, "codmes-database.dump")}`
    ]);
    const workspaces = path.join(dataRoot, "workspaces");
    if (await fileExists(workspaces)) {
      await fs.cp(workspaces, path.join(staging, "workspaces"), { recursive: true, preserveTimestamps: true });
    }
    const legacyDirectories = ["Notes", "Documents", "Code", "Attachments", ".codmes"];
    const copiedLegacyDirectories = [];
    for (const directory of legacyDirectories) {
      const source = path.join(dataRoot, directory);
      if (!await fileExists(source)) continue;
      await fs.cp(source, path.join(staging, "legacy-workspace", directory), {
        recursive: true,
        preserveTimestamps: true
      });
      copiedLegacyDirectories.push(directory);
    }
    const manifest = {
      format: "codmes-managed-backup",
      version: 1,
      createdAt: new Date().toISOString(),
      database: "codmes-database.dump",
      workspaceFiles: "workspaces",
      legacyWorkspaceFiles: copiedLegacyDirectories.length ? "legacy-workspace" : null,
      legacyDirectories: copiedLegacyDirectories
    };
    await fs.writeFile(path.join(staging, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    await fs.mkdir(path.dirname(destination), { recursive: true });
    await fs.rename(staging, destination);
    return { destination, manifest };
  } catch (error) {
    await fs.rm(staging, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

export async function findPostgresBin(explicit) {
  const candidates = [
    explicit,
    process.env.CODMES_POSTGRES_BIN,
    path.resolve(process.cwd(), "bundled", "postgres", "bin"),
    path.resolve(process.cwd(), "postgres", "bin")
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (await fileExists(path.join(candidate, executable("postgres")))) return path.resolve(candidate);
  }
  try {
    const output = execFileSync("pg_config", ["--bindir"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const candidate = output.trim();
    if (candidate && await fileExists(path.join(candidate, executable("postgres")))) return candidate;
  } catch {}
  throw new Error("Bundled PostgreSQL runtime was not found. Set CODMES_POSTGRES_BIN for development.");
}

async function postgresIsRunning(pgCtl, dataDirectory) {
  try {
    await execFileAsync(pgCtl, ["-D", dataDirectory, "status"], { timeout: 5_000 });
    return true;
  } catch {
    return false;
  }
}

async function readOrCreatePassword(passwordPath) {
  try {
    return (await fs.readFile(passwordPath, "utf8")).trim();
  } catch {}
  const password = crypto.randomBytes(32).toString("base64url");
  await fs.writeFile(passwordPath, `${password}\n`, { mode: 0o600, flag: "wx" });
  if (process.platform !== "win32") await fs.chmod(passwordPath, 0o600);
  return password;
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function run(command, args, env = process.env) {
  try {
    return await execFileAsync(command, args, { env, timeout: 60_000, maxBuffer: 4 * 1024 * 1024 });
  } catch (error) {
    const detail = String(error?.stderr || error?.stdout || error?.message || error).trim();
    throw new Error(`${path.basename(command)} failed: ${detail}`);
  }
}

async function runCapture(command, args, env) {
  const result = await run(command, args, env);
  return String(result.stdout || "");
}

function normalizePort(value) {
  const port = Number.parseInt(String(value), 10);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new Error("CODMES_POSTGRES_PORT must be between 1024 and 65535.");
  }
  return port;
}

function executable(name) {
  return process.platform === "win32" ? `${name}.exe` : name;
}
