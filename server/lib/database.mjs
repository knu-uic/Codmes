import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const { Pool } = pg;
const MIGRATIONS_DIRECTORY = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "db",
  "migrations"
);

export function postgresConfigured(env = process.env) {
  return Boolean(String(env.CODMES_DATABASE_URL || env.DATABASE_URL || "").trim());
}

export function createCodmesDatabase(options = {}) {
  const connectionString = String(
    options.connectionString
      || process.env.CODMES_DATABASE_URL
      || process.env.DATABASE_URL
      || ""
  ).trim();
  if (!connectionString && !options.connection) {
    throw new Error("CODMES_DATABASE_URL is required for the PostgreSQL backend.");
  }
  const pool = options.pool || new Pool({
    ...(connectionString ? { connectionString } : options.connection),
    max: Number(options.maxConnections || process.env.CODMES_DATABASE_POOL_SIZE || 10),
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    application_name: "codmes-server"
  });
  return new CodmesDatabase(pool, options);
}

export class CodmesDatabase {
  constructor(pool, options = {}) {
    this.pool = pool;
    this.migrationsDirectory = options.migrationsDirectory || MIGRATIONS_DIRECTORY;
  }

  async query(text, values = []) {
    return await this.pool.query(text, values);
  }

  async transaction(callback) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await callback(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async migrate() {
    const client = await this.pool.connect();
    try {
      await client.query("SELECT pg_advisory_lock(hashtext('codmes-schema-migrations'))");
      await client.query(`
        CREATE TABLE IF NOT EXISTS codmes_schema_migrations (
          version text PRIMARY KEY,
          checksum text NOT NULL,
          applied_at timestamptz NOT NULL DEFAULT now()
        )
      `);
      const entries = (await fs.readdir(this.migrationsDirectory, { withFileTypes: true }))
        .filter((entry) => entry.isFile() && /^\d+.*\.sql$/i.test(entry.name))
        .sort((left, right) => left.name.localeCompare(right.name));
      const applied = await client.query("SELECT version, checksum FROM codmes_schema_migrations");
      const checksums = new Map(applied.rows.map((row) => [row.version, row.checksum]));
      const completed = [];
      for (const entry of entries) {
        const sql = await fs.readFile(path.join(this.migrationsDirectory, entry.name), "utf8");
        const checksum = crypto.createHash("sha256").update(sql).digest("hex");
        const existing = checksums.get(entry.name);
        if (existing) {
          if (existing !== checksum) {
            throw new Error(`Applied migration was modified: ${entry.name}`);
          }
          continue;
        }
        await client.query("BEGIN");
        try {
          await client.query(sql);
          await client.query(
            "INSERT INTO codmes_schema_migrations(version, checksum) VALUES ($1, $2)",
            [entry.name, checksum]
          );
          await client.query("COMMIT");
          completed.push(entry.name);
        } catch (error) {
          await client.query("ROLLBACK").catch(() => {});
          throw error;
        }
      }
      return { applied: completed };
    } finally {
      await client.query("SELECT pg_advisory_unlock(hashtext('codmes-schema-migrations'))").catch(() => {});
      client.release();
    }
  }

  async health() {
    const result = await this.pool.query(`
      SELECT
        current_database() AS database,
        current_setting('server_version') AS server_version,
        EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'vector') AS pgvector
    `);
    return result.rows[0];
  }

  async close() {
    await this.pool.end();
  }
}
