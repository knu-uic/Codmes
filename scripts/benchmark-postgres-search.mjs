#!/usr/bin/env node
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { createCodmesDatabase } from "../server/lib/database.mjs";
import { startManagedPostgres, stopManagedPostgres } from "../server/lib/managed-postgres.mjs";
import { PostgresSearchStore } from "../server/lib/postgres-search-store.mjs";

const chunkCount = Math.max(100, Math.min(100_000, Number(process.env.CODMES_BENCHMARK_CHUNKS || 20_000)));
const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-scale-"));
let postgres;
let database;
try {
  postgres = await startManagedPostgres({
    dataRoot: root,
    port: Number(process.env.CODMES_BENCHMARK_POSTGRES_PORT || 55841)
  });
  database = createCodmesDatabase({ connectionString: postgres.connectionString });
  await database.migrate();
  const userId = randomUUID();
  const workspaceId = randomUUID();
  const documentId = randomUUID();
  const profileId = randomUUID();
  await database.query(
    "INSERT INTO codmes_users(id, username_normalized, display_name, password_hash) VALUES ($1, $2, $2, $3)",
    [userId, "scale-user", "disabled"]
  );
  await database.query(
    "INSERT INTO codmes_workspaces(id, owner_user_id, name, storage_key) VALUES ($1, $2, $3, $4)",
    [workspaceId, userId, "Scale", randomUUID()]
  );
  await database.query(
    "INSERT INTO codmes_workspace_members(workspace_id, user_id, role) VALUES ($1, $2, 'owner')",
    [workspaceId, userId]
  );
  await database.query(
    "INSERT INTO codmes_documents(id, workspace_id, relative_path, content_hash) VALUES ($1, $2, $3, $4)",
    [documentId, workspaceId, "Documents/library.pdf", "scale"]
  );
  await database.query(
    `INSERT INTO codmes_embedding_profiles(
       id, provider, model, dimensions, chunking_version, document_engine_version
     ) VALUES ($1, $2, $3, 1024, 1, '1')`,
    [profileId, "test", "bge-m3"]
  );
  const vector = `[1,${new Array(1023).fill(0).join(",")}]`;
  const insertStarted = performance.now();
  await database.query(
    `INSERT INTO codmes_document_chunks(
       id, document_id, workspace_id, profile_id, chunk_index,
       text, search_text, content_hash, embedding
     )
     SELECT 'scale-' || n, $1, $2, $3, n,
            'database library chunk ' || n,
            'database library chunk ' || n,
            md5(n::text), $4::vector
       FROM generate_series(1, $5) n`,
    [documentId, workspaceId, profileId, vector, chunkCount]
  );
  const insertMs = performance.now() - insertStarted;
  const search = new PostgresSearchStore({ database, fetch: fakeEmbeddingFetch });
  const queryStarted = performance.now();
  const result = await search.search({
    workspaceId,
    query: "database library",
    maxResults: 10,
    embedding: { baseUrl: "http://fake/v1" }
  });
  const queryMs = performance.now() - queryStarted;
  const size = await database.query("SELECT pg_database_size(current_database()) AS bytes");
  console.log(JSON.stringify({
    chunks: chunkCount,
    insertMs: Math.round(insertMs),
    queryMs: Math.round(queryMs),
    results: result.resultCount,
    databaseBytes: Number(size.rows[0].bytes)
  }, null, 2));
} finally {
  await database?.close().catch(() => {});
  await stopManagedPostgres(postgres).catch(() => {});
  await fs.rename(root, path.join(os.homedir(), ".Trash", `${path.basename(root)}-${Date.now()}`)).catch(() => {});
}

async function fakeEmbeddingFetch(_url, options) {
  const input = JSON.parse(options.body).input;
  return new Response(JSON.stringify({
    data: input.map((_text, index) => ({ index, embedding: [1, ...new Array(1023).fill(0)] }))
  }), { status: 200, headers: { "content-type": "application/json" } });
}
