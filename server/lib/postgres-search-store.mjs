import crypto, { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { createCodmesDatabase } from "./database.mjs";

const DEFAULT_PROFILE = Object.freeze({
  provider: "openai",
  model: "bge-m3",
  dimensions: 1024,
  modelRevision: "",
  chunkingVersion: 1,
  documentEngineVersion: "1"
});

export class PostgresSearchStore {
  constructor(options = {}) {
    this.database = options.database || createCodmesDatabase({ connectionString: options.connectionString });
    this.ownsDatabase = !options.database;
    this.fetch = options.fetch || globalThis.fetch;
    this.embeddingBatchSize = Number(options.embeddingBatchSize || 32);
  }

  async initialize() {
    return await this.database.migrate();
  }

  async ensureLegacyWorkspace(workspaceRoot) {
    const installId = stableUuid(`codmes-install:${workspaceRoot}`);
    const workspaceId = stableUuid(`codmes-workspace:${workspaceRoot}`);
    const storageKey = stableUuid(`codmes-storage:${workspaceRoot}`);
    await this.database.transaction(async (client) => {
      await client.query(
        `INSERT INTO codmes_users(id, username_normalized, display_name, password_hash, role)
         VALUES ($1, $2, 'Legacy owner', 'disabled', 'admin')
         ON CONFLICT (id) DO NOTHING`,
        [installId, `legacy-${installId.slice(0, 8)}`]
      );
      await client.query(
        `INSERT INTO codmes_workspaces(id, owner_user_id, name, storage_key)
         VALUES ($1, $2, 'Default Workspace', $3)
         ON CONFLICT (id) DO NOTHING`,
        [workspaceId, installId, storageKey]
      );
      await client.query(
        `INSERT INTO codmes_workspace_members(workspace_id, user_id, role)
         VALUES ($1, $2, 'owner')
         ON CONFLICT (workspace_id, user_id) DO NOTHING`,
        [workspaceId, installId]
      );
    });
    return { userId: installId, workspaceId };
  }

  async replaceWorkspaceIndex({ workspaceRoot, workspaceId, index, embedding = {} }) {
    await this.initialize();
    const tenant = workspaceId
      ? { workspaceId }
      : await this.ensureLegacyWorkspace(workspaceRoot);
    const profile = normalizeProfile(embedding);
    const profileId = await this.ensureProfile(profile);
    const existingResult = await this.database.query(
      "SELECT id, content_hash, profile_id FROM codmes_document_chunks WHERE workspace_id = $1",
      [tenant.workspaceId]
    );
    const existing = new Map(existingResult.rows.map((row) => [row.id, row]));
    const prepared = [];
    for (const chunk of index.chunks || []) {
      const hash = sha256(String(chunk.text || ""));
      const stored = existing.get(chunk.id);
      prepared.push({
        chunk,
        vector: null,
        hash,
        needsEmbedding: !stored || stored.content_hash !== hash || stored.profile_id !== profileId
      });
    }
    const pendingEmbeddings = prepared.filter((item) => item.needsEmbedding);
    for (let offset = 0; offset < pendingEmbeddings.length; offset += this.embeddingBatchSize) {
      const batch = pendingEmbeddings.slice(offset, offset + this.embeddingBatchSize);
      const vectors = await requestEmbeddings(this.fetch, profile, batch.map((item) => item.chunk.text));
      vectors.forEach((vector, index) => {
        validateVector(vector, profile.dimensions);
        batch[index].vector = vector;
      });
    }

    // Stable database-backed asset URLs are enabled for authenticated workspaces.
    // Legacy single-user mode keeps its existing path URL, so it remains usable
    // without opening a second database pool in the HTTP asset handler.
    const preparedAssets = workspaceId ? await collectDocumentAssets(workspaceRoot, index) : [];
    await this.database.transaction(async (client) => {
      const livePaths = [];
      const documentIds = new Map();
      for (const item of index.items || []) {
        const documentId = randomUUID();
        const contentHash = sha256(
          (index.chunks || []).filter((chunk) => chunk.path === item.path).map((chunk) => chunk.text).join("\n")
        );
        const result = await client.query(
          `INSERT INTO codmes_documents(
             id, workspace_id, relative_path, content_hash, mime_type, size_bytes,
             document_kind, ingest_status, extraction_version, indexed_at, pdf_type
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'completed', $8, now(), $9)
           ON CONFLICT (workspace_id, relative_path) DO UPDATE SET
             content_hash = EXCLUDED.content_hash,
             size_bytes = EXCLUDED.size_bytes,
             document_kind = EXCLUDED.document_kind,
             pdf_type = EXCLUDED.pdf_type,
             ingest_status = 'completed',
             extraction_version = EXCLUDED.extraction_version,
             indexed_at = now(),
             updated_at = now()
           RETURNING id`,
          [
            documentId,
            tenant.workspaceId,
            item.path,
            contentHash,
            mimeTypeForKind(item.kind),
            Number(item.size || 0),
            item.kind || "file",
            profile.documentEngineVersion,
            item.metadata?.pdfType || null
          ]
        );
        livePaths.push(item.path);
        documentIds.set(item.path, result.rows[0].id);
      }
      if (livePaths.length) {
        await client.query(
          "DELETE FROM codmes_documents WHERE workspace_id = $1 AND NOT (relative_path = ANY($2::text[]))",
          [tenant.workspaceId, livePaths]
        );
      } else {
        await client.query("DELETE FROM codmes_documents WHERE workspace_id = $1", [tenant.workspaceId]);
      }
      const assetIds = new Map();
      for (const asset of preparedAssets) {
        const documentId = documentIds.get(asset.documentPath);
        if (!documentId) continue;
        const result = await client.query(
          `INSERT INTO codmes_document_assets(
             id, document_id, page_number, kind, bbox, sha256, storage_path,
             description, ocr_text, requires_review, metadata
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
           ON CONFLICT (document_id, sha256, storage_path) DO UPDATE SET
             page_number = EXCLUDED.page_number,
             kind = EXCLUDED.kind,
             bbox = EXCLUDED.bbox,
             description = EXCLUDED.description,
             ocr_text = EXCLUDED.ocr_text,
             requires_review = EXCLUDED.requires_review,
             metadata = EXCLUDED.metadata
           RETURNING id`,
          [
            randomUUID(), documentId, asset.pageNumber, asset.kind, asset.bbox,
            asset.sha256, asset.storagePath, asset.description, asset.ocrText,
            asset.requiresReview, JSON.stringify(asset.metadata)
          ]
        );
        assetIds.set(asset.key, result.rows[0].id);
      }
      for (const item of prepared) {
        const chunk = item.chunk;
        const documentId = documentIds.get(chunk.path);
        if (!documentId) continue;
        const relatedImages = (chunk.related_images || []).map((image) => {
          const assetId = assetIds.get(assetKey(chunk.path, image));
          return assetId
            ? {
                ...image,
                asset_id: assetId,
                reference: `[그림:${assetId}]`,
                // Keep the workspace-relative content URL for session
                // localization; the UUID still provides the stable DB link.
                url: image.url
              }
            : image;
        });
        const relatedAssetIds = relatedImages
          .map((image) => image.asset_id)
          .filter((id) => /^[a-f0-9-]{36}$/i.test(String(id || "")));
        await client.query(
          `INSERT INTO codmes_document_chunks(
             id, document_id, workspace_id, profile_id, page_number, chunk_index,
             text, search_text, bbox, metadata, related_asset_ids, related_images, content_hash, embedding
           ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::uuid[], $12, $13, $14::vector)
           ON CONFLICT (id) DO UPDATE SET
             document_id = EXCLUDED.document_id,
             workspace_id = EXCLUDED.workspace_id,
             profile_id = EXCLUDED.profile_id,
             page_number = EXCLUDED.page_number,
             chunk_index = EXCLUDED.chunk_index,
             text = EXCLUDED.text,
             search_text = EXCLUDED.search_text,
             bbox = EXCLUDED.bbox,
             metadata = EXCLUDED.metadata,
             related_asset_ids = EXCLUDED.related_asset_ids,
             related_images = EXCLUDED.related_images,
             content_hash = EXCLUDED.content_hash,
             embedding = COALESCE(EXCLUDED.embedding, codmes_document_chunks.embedding),
             updated_at = now()`,
          [
            chunk.id,
            documentId,
            tenant.workspaceId,
            profileId,
            chunk.page ?? null,
            Number(chunk.chunkIndex || 0),
            chunk.text,
            normalizeSearchText(`${chunk.path}\n${chunk.text}`),
            chunk.bbox || null,
            JSON.stringify(chunk.metadata || {}),
            relatedAssetIds,
            JSON.stringify(relatedImages),
            item.hash,
            item.vector ? vectorLiteral(item.vector) : null
          ]
        );
      }
      const liveChunkIds = prepared.map((item) => item.chunk.id);
      if (liveChunkIds.length) {
        await client.query(
          "DELETE FROM codmes_document_chunks WHERE workspace_id = $1 AND NOT (id = ANY($2::text[]))",
          [tenant.workspaceId, liveChunkIds]
        );
      } else {
        await client.query("DELETE FROM codmes_document_chunks WHERE workspace_id = $1", [tenant.workspaceId]);
      }
    });
    return {
      workspaceId: tenant.workspaceId,
      itemCount: index.items?.length || 0,
      chunkCount: prepared.length,
      embeddedChunkCount: pendingEmbeddings.length,
      reusedChunkCount: prepared.length - pendingEmbeddings.length
    };
  }

  async search({ workspaceRoot, workspaceId, query, maxResults = 20, scopePath = "", embedding = {} }) {
    await this.initialize();
    const tenant = workspaceId
      ? { workspaceId }
      : await this.ensureLegacyWorkspace(workspaceRoot);
    const profile = normalizeProfile(embedding);
    const [vector] = await requestEmbeddings(this.fetch, profile, [query]);
    validateVector(vector, profile.dimensions);
    const limit = Math.max(1, Math.min(100, Number(maxResults || 20)));
    const candidateLimit = Math.max(40, limit * 4);
    const prefix = String(scopePath || "").replace(/^\/+|\/+$/g, "");
    const result = await this.database.query(
      `WITH semantic AS (
         SELECT c.id, row_number() OVER (ORDER BY c.embedding <=> $3::vector) AS rank
           FROM codmes_document_chunks c
           JOIN codmes_documents d ON d.id = c.document_id
          WHERE c.workspace_id = $1
            AND c.embedding IS NOT NULL
            AND ($4 = '' OR d.relative_path = $4 OR d.relative_path LIKE $4 || '/%')
          ORDER BY c.embedding <=> $3::vector
          LIMIT $5
       ), lexical AS (
         SELECT c.id,
                row_number() OVER (
                  ORDER BY (
                    similarity(c.search_text, $2)
                    + CASE WHEN c.search_text ILIKE '%' || $2 || '%' THEN 1 ELSE 0 END
                  ) DESC
                ) AS rank
           FROM codmes_document_chunks c
           JOIN codmes_documents d ON d.id = c.document_id
          WHERE c.workspace_id = $1
            AND ($4 = '' OR d.relative_path = $4 OR d.relative_path LIKE $4 || '/%')
            AND (c.search_text % $2 OR c.search_text ILIKE '%' || $2 || '%')
          ORDER BY (
            similarity(c.search_text, $2)
            + CASE WHEN c.search_text ILIKE '%' || $2 || '%' THEN 1 ELSE 0 END
          ) DESC
          LIMIT $5
       ), fused AS (
         SELECT COALESCE(s.id, l.id) AS id,
                COALESCE(1.0 / (60 + s.rank), 0) + COALESCE(1.0 / (60 + l.rank), 0) AS score
           FROM semantic s
           FULL OUTER JOIN lexical l ON l.id = s.id
       )
       SELECT c.id, c.chunk_index, c.page_number, c.text, c.bbox, c.metadata, c.related_images,
              d.relative_path, d.document_kind, fused.score
         FROM fused
         JOIN codmes_document_chunks c ON c.id = fused.id
         JOIN codmes_documents d ON d.id = c.document_id
        ORDER BY fused.score DESC, d.relative_path, c.chunk_index
        LIMIT $6`,
      [tenant.workspaceId, normalizeSearchText(query), vectorLiteral(vector), prefix, candidateLimit, limit]
    );
    return {
      provider: "codmes-postgres-hybrid",
      indexed: true,
      query,
      scopePath: prefix,
      resultCount: result.rows.length,
      results: result.rows.map((row) => ({
        path: row.relative_path,
        kind: row.document_kind,
        score: Number(row.score),
        snippet: row.text,
        chunkId: row.id,
        chunkIndex: row.chunk_index,
        page: row.page_number,
        bbox: row.bbox,
        metadata: row.metadata || {},
        related_images: row.related_images || []
      }))
    };
  }

  async ensureProfile(profile) {
    const id = randomUUID();
    const result = await this.database.query(
      `INSERT INTO codmes_embedding_profiles(
         id, provider, model, dimensions, model_revision, chunking_version, document_engine_version
       ) VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (provider, model, dimensions, model_revision, chunking_version, document_engine_version)
       DO UPDATE SET model = EXCLUDED.model
       RETURNING id`,
      [
        id, profile.provider, profile.model, profile.dimensions, profile.modelRevision,
        profile.chunkingVersion, profile.documentEngineVersion
      ]
    );
    return result.rows[0].id;
  }

  async close() {
    if (this.ownsDatabase) await this.database.close();
  }
}

async function collectDocumentAssets(workspaceRoot, index) {
  const unique = new Map();
  for (const chunk of index.chunks || []) {
    for (const image of chunk.related_images || []) {
      const key = assetKey(chunk.path, image);
      if (unique.has(key)) continue;
      const storagePath = documentAssetStoragePath(image.url);
      if (!storagePath) continue;
      const absolutePath = path.resolve(workspaceRoot, storagePath);
      if (!isInside(path.resolve(workspaceRoot), absolutePath)) continue;
      let digest = "";
      try {
        digest = crypto.createHash("sha256").update(await fs.readFile(absolutePath)).digest("hex");
      } catch {
        digest = sha256(JSON.stringify({ path: storagePath, image }));
      }
      unique.set(key, {
        key,
        documentPath: chunk.path,
        pageNumber: Number(image.page || chunk.page) || null,
        kind: String(image.kind || image.type || "figure"),
        bbox: image.bbox || null,
        sha256: digest,
        storagePath,
        description: String(image.description || image.caption || ""),
        ocrText: String(image.ocr_text || image.ocrText || ""),
        requiresReview: Boolean(image.requires_review || image.requiresReview),
        metadata: { ...image, url: undefined }
      });
    }
  }
  return [...unique.values()];
}

function assetKey(documentPath, image) {
  return `${documentPath}\0${image.asset_id || image.url || JSON.stringify(image)}`;
}

function documentAssetStoragePath(url) {
  const match = String(url || "").match(/^\/api\/document-assets\/([^/]+)\/([a-zA-Z0-9._-]+)$/i);
  if (!match) return "";
  return path.posix.join(".codmes", "documents", decodeURIComponent(match[1]), "index", "images", match[2]);
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export async function requestEmbeddings(fetchImpl, profile, texts) {
  if (!texts.length) return [];
  const baseUrl = String(profile.baseUrl || "").replace(/\/$/, "");
  if (!baseUrl) throw new Error("Embedding base URL is required.");
  const response = await fetchImpl(`${baseUrl}/embeddings`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(profile.apiKey ? { authorization: `Bearer ${profile.apiKey}` } : {})
    },
    body: JSON.stringify({ model: profile.model, input: texts })
  });
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Embedding request failed (${response.status}): ${detail.slice(0, 300)}`);
  }
  const payload = await response.json();
  const rows = Array.isArray(payload.data) ? payload.data.slice().sort((a, b) => a.index - b.index) : [];
  if (rows.length !== texts.length) throw new Error("Embedding provider returned an unexpected vector count.");
  return rows.map((row) => row.embedding);
}

export function normalizeEmbeddingProfile(config = {}) {
  return normalizeProfile(config);
}

function normalizeProfile(config) {
  const dimensions = Number(config.dimensions || config.openaiEmbedDim || DEFAULT_PROFILE.dimensions);
  if (dimensions !== 1024) {
    throw new Error(`Codmes PostgreSQL index currently requires 1024 dimensions, received ${dimensions}.`);
  }
  return {
    provider: String(config.provider || config.embeddingsProvider || DEFAULT_PROFILE.provider),
    model: String(config.model || config.openaiEmbedModel || DEFAULT_PROFILE.model),
    dimensions,
    modelRevision: String(config.modelRevision || ""),
    chunkingVersion: Number(config.chunkingVersion || DEFAULT_PROFILE.chunkingVersion),
    documentEngineVersion: String(config.documentEngineVersion || DEFAULT_PROFILE.documentEngineVersion),
    baseUrl: String(config.baseUrl || config.openaiBaseUrl || "http://127.0.0.1:11434/v1"),
    apiKey: String(config.apiKey || config.openaiApiKey || "")
  };
}

function validateVector(vector, dimensions) {
  if (!Array.isArray(vector) || vector.length !== dimensions || vector.some((value) => !Number.isFinite(value))) {
    throw new Error(`Embedding provider must return ${dimensions} finite numbers.`);
  }
}

function vectorLiteral(vector) {
  return `[${vector.map((value) => Number(value)).join(",")}]`;
}

function normalizeSearchText(value) {
  return String(value || "").normalize("NFC").toLocaleLowerCase("ko-KR");
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value || "")).digest("hex");
}

function stableUuid(value) {
  const hex = sha256(value).slice(0, 32).split("");
  hex[12] = "5";
  hex[16] = ((Number.parseInt(hex[16], 16) & 0x3) | 0x8).toString(16);
  return `${hex.slice(0, 8).join("")}-${hex.slice(8, 12).join("")}-${hex.slice(12, 16).join("")}-${hex.slice(16, 20).join("")}-${hex.slice(20).join("")}`;
}

function mimeTypeForKind(kind) {
  return ({ pdf: "application/pdf", markdown: "text/markdown", image: "image/*" })[kind] || "text/plain";
}
