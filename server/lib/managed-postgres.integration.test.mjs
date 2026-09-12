import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createCodmesDatabase } from "./database.mjs";
import { createManagedBackup, startManagedPostgres, stopManagedPostgres } from "./managed-postgres.mjs";

test("managed PostgreSQL initializes, migrates, restarts, and preserves data", {
  skip: process.env.CODMES_TEST_MANAGED_POSTGRES !== "true"
}, async () => {
  const dataRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-managed-postgres-"));
  let instance;
  try {
    instance = await startManagedPostgres({ dataRoot, port: 55442 });
    const database = createCodmesDatabase({ connectionString: instance.connectionString });
    await database.migrate();
    assert.equal((await database.health()).pgvector, true);
    await database.query("CREATE TABLE codmes_restart_probe(value text PRIMARY KEY)");
    await database.query("INSERT INTO codmes_restart_probe(value) VALUES ('preserved')");
    await database.close();
    await fs.mkdir(path.join(dataRoot, "Notes"), { recursive: true });
    await fs.writeFile(path.join(dataRoot, "Notes", "legacy.md"), "preserved workspace");
    const backup = await createManagedBackup(instance, {
      dataRoot,
      destination: path.join(dataRoot, "test-backup")
    });
    assert.equal(JSON.parse(await fs.readFile(path.join(backup.destination, "manifest.json"), "utf8")).version, 1);
    assert.ok((await fs.stat(path.join(backup.destination, "codmes-database.dump"))).size > 0);
    assert.equal(
      await fs.readFile(path.join(backup.destination, "legacy-workspace", "Notes", "legacy.md"), "utf8"),
      "preserved workspace"
    );
    await stopManagedPostgres(instance);

    instance = await startManagedPostgres({ dataRoot, port: 55442 });
    const reopened = createCodmesDatabase({ connectionString: instance.connectionString });
    const probe = await reopened.query("SELECT value FROM codmes_restart_probe");
    assert.equal(probe.rows[0].value, "preserved");
    await reopened.close();
  } finally {
    await stopManagedPostgres(instance).catch(() => {});
    const trash = path.join(os.homedir(), ".Trash", `codmes-managed-postgres-${Date.now()}`);
    await fs.rename(dataRoot, trash).catch(() => {});
  }
});
