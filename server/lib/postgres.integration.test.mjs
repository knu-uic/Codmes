import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createCodmesDatabase } from "./database.mjs";
import { LocalAccountStore } from "./local-accounts.mjs";
import { PostgresSearchStore } from "./postgres-search-store.mjs";
import { PostgresIngestQueue } from "./postgres-ingest-queue.mjs";
import { WorkspaceTenancyStore } from "./workspace-tenancy.mjs";

const connectionString = process.env.CODMES_TEST_DATABASE_URL || "";

test("PostgreSQL migrations, local accounts, and workspace isolation", {
  skip: !connectionString
}, async () => {
  const dataRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-tenancy-"));
  const database = createCodmesDatabase({ connectionString, maxConnections: 3 });
  try {
    const migration = await database.migrate();
    assert.ok(Array.isArray(migration.applied));
    const health = await database.health();
    assert.equal(health.pgvector, true);

    const accounts = new LocalAccountStore(database, { sessionTtlMs: 60_000 });
    const admin = await accounts.bootstrapAdmin({
      username: "admin",
      displayName: "Administrator",
      password: "test-password-123"
    });
    const family = await accounts.createUser(admin, {
      username: "family",
      displayName: "Family",
      password: "family-password-123"
    });
    const loggedIn = await accounts.login({
      username: "family",
      password: "family-password-123",
      deviceName: "test client"
    });
    assert.equal(loggedIn.user.id, family.id);
    assert.equal((await accounts.resolveToken(loggedIn.token)).id, family.id);

    const tenancy = new WorkspaceTenancyStore(database, dataRoot);
    const adminWorkspace = await tenancy.createWorkspace(admin, { name: "Admin Library" });
    const familyWorkspace = await tenancy.createWorkspace(family, { name: "Family Library" });
    assert.notEqual(adminWorkspace.root, familyWorkspace.root);
    assert.equal((await tenancy.listForUser(family.id)).length, 1);
    await assert.rejects(
      tenancy.resolveForUser(family.id, adminWorkspace.id),
      (error) => error.status === 404
    );
    await tenancy.addMember(admin, adminWorkspace.id, family.id, "viewer");
    assert.equal((await tenancy.resolveForUser(family.id, adminWorkspace.id)).role, "viewer");

    let embeddedTexts = 0;
    const search = new PostgresSearchStore({
      database,
      fetch: async (...args) => {
        embeddedTexts += JSON.parse(args[1].body).input.length;
        return await fakeEmbeddingFetch(...args);
      }
    });
    const figurePath = path.join(adminWorkspace.root, ".codmes", "documents", "example", "index", "images", "figure.png");
    await fs.mkdir(path.dirname(figurePath), { recursive: true });
    await fs.writeFile(figurePath, Buffer.from("test-png"));
    const sourceIndex = {
      items: [
        { path: "Documents/database.pdf", kind: "pdf", size: 1200 },
        { path: "Notes/garden.md", kind: "markdown", size: 200 }
      ],
      chunks: [
        {
          id: "database-chunk",
          path: "Documents/database.pdf",
          kind: "pdf",
          chunkIndex: 0,
          page: 12,
          text: "Database transactions use commit and rollback.",
          related_images: [{ asset_id: "figure-1", url: "/api/document-assets/example/figure.png" }]
        },
        {
          id: "garden-chunk",
          path: "Notes/garden.md",
          kind: "markdown",
          chunkIndex: 0,
          text: "Tomatoes need sunlight and water."
        }
      ]
    };
    const firstSync = await search.replaceWorkspaceIndex({
      workspaceRoot: adminWorkspace.root,
      workspaceId: adminWorkspace.id,
      index: sourceIndex,
      embedding: { baseUrl: "http://embedding.test/v1" }
    });
    assert.equal(firstSync.embeddedChunkCount, 2);
    const secondSync = await search.replaceWorkspaceIndex({
      workspaceRoot: adminWorkspace.root,
      workspaceId: adminWorkspace.id,
      index: sourceIndex,
      embedding: { baseUrl: "http://embedding.test/v1" }
    });
    assert.equal(secondSync.embeddedChunkCount, 0);
    assert.equal(secondSync.reusedChunkCount, 2);
    assert.equal(embeddedTexts, 2);
    const databaseSearch = await search.search({
      workspaceId: adminWorkspace.id,
      query: "database commit",
      embedding: { baseUrl: "http://embedding.test/v1" }
    });
    assert.equal(databaseSearch.provider, "codmes-postgres-hybrid");
    assert.equal(databaseSearch.results[0].path, "Documents/database.pdf");
    assert.match(databaseSearch.results[0].related_images[0].asset_id, /^[a-f0-9-]{36}$/i);
    assert.equal(
      databaseSearch.results[0].related_images[0].reference,
      `[그림:${databaseSearch.results[0].related_images[0].asset_id}]`
    );
    assert.equal(databaseSearch.results[0].related_images[0].url, "/api/document-assets/example/figure.png");
    const asset = await database.query(
      "SELECT storage_path FROM codmes_document_assets WHERE id = $1",
      [databaseSearch.results[0].related_images[0].asset_id]
    );
    assert.equal(asset.rows[0].storage_path, ".codmes/documents/example/index/images/figure.png");

    const queue = new PostgresIngestQueue(database, { maxAttempts: 2 });
    const queued = await queue.enqueue({
      workspaceId: adminWorkspace.id,
      jobType: "document-index",
      payload: { path: "Documents/database.pdf" }
    });
    const claimed = await queue.claim("worker-a", ["document-index"]);
    assert.equal(claimed.id, queued.id);
    assert.equal(claimed.attempts, 1);
    assert.equal((await queue.progress(claimed.id, "worker-a", 0.5)).progress, 0.5);
    assert.equal((await queue.fail(claimed.id, "worker-a", new Error("retry"))).status, "pending");
    const retried = await queue.claim("worker-b", ["document-index"]);
    assert.equal(retried.attempts, 2);
    assert.equal((await queue.complete(retried.id, "worker-b")).status, "completed");
  } finally {
    await database.close();
    await fs.rm(dataRoot, { recursive: true, force: true });
  }
});

async function fakeEmbeddingFetch(_url, options) {
  const input = JSON.parse(options.body).input;
  return new Response(JSON.stringify({
    data: input.map((text, index) => ({ index, embedding: fakeVector(text) }))
  }), { status: 200, headers: { "content-type": "application/json" } });
}

function fakeVector(text) {
  const vector = new Array(1024).fill(0);
  const normalized = String(text).toLowerCase();
  if (normalized.includes("database") || normalized.includes("commit")) vector[0] = 1;
  else vector[1] = 1;
  return vector;
}
