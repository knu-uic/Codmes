import { randomUUID } from "node:crypto";

export class PostgresIngestQueue {
  constructor(database, options = {}) {
    this.database = database;
    this.maxAttempts = Math.max(1, Number(options.maxAttempts || 3));
  }

  async enqueue({ workspaceId, documentId = null, jobType, payload = {} }) {
    const result = await this.database.query(
      `INSERT INTO codmes_ingest_jobs(id, workspace_id, document_id, job_type, payload)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [randomUUID(), workspaceId, documentId, String(jobType || "document-index"), JSON.stringify(payload)]
    );
    return publicJob(result.rows[0]);
  }

  async claim(workerId, jobTypes = []) {
    const types = jobTypes.map(String).filter(Boolean);
    return await this.database.transaction(async (client) => {
      const result = await client.query(
        `SELECT id
           FROM codmes_ingest_jobs
          WHERE status = 'pending'
            AND ($1::text[] = '{}'::text[] OR job_type = ANY($1::text[]))
          ORDER BY created_at, id
          FOR UPDATE SKIP LOCKED
          LIMIT 1`,
        [types]
      );
      if (!result.rows[0]) return null;
      const claimed = await client.query(
        `UPDATE codmes_ingest_jobs
            SET status = 'running', attempts = attempts + 1, locked_by = $2,
                locked_at = now(), updated_at = now(), error = NULL
          WHERE id = $1
          RETURNING *`,
        [result.rows[0].id, String(workerId || "codmes-worker")]
      );
      return publicJob(claimed.rows[0]);
    });
  }

  async claimById(jobId, workerId) {
    const result = await this.database.query(
      `UPDATE codmes_ingest_jobs
          SET status = 'running', attempts = attempts + 1, locked_by = $2,
              locked_at = now(), updated_at = now(), error = NULL
        WHERE id = $1 AND status = 'pending'
        RETURNING *`,
      [jobId, String(workerId || "codmes-worker")]
    );
    return result.rows[0] ? publicJob(result.rows[0]) : null;
  }

  async progress(jobId, workerId, progress) {
    const result = await this.database.query(
      `UPDATE codmes_ingest_jobs
          SET progress = $3, updated_at = now()
        WHERE id = $1 AND locked_by = $2 AND status = 'running'
        RETURNING *`,
      [jobId, workerId, clampProgress(progress)]
    );
    return result.rows[0] ? publicJob(result.rows[0]) : null;
  }

  async complete(jobId, workerId) {
    const result = await this.database.query(
      `UPDATE codmes_ingest_jobs
          SET status = 'completed', progress = 1, locked_by = NULL,
              locked_at = NULL, updated_at = now()
        WHERE id = $1 AND locked_by = $2 AND status = 'running'
        RETURNING *`,
      [jobId, workerId]
    );
    return result.rows[0] ? publicJob(result.rows[0]) : null;
  }

  async fail(jobId, workerId, error) {
    const result = await this.database.query(
      `UPDATE codmes_ingest_jobs
          SET status = CASE WHEN attempts >= $4 THEN 'failed' ELSE 'pending' END,
              error = $3, locked_by = NULL, locked_at = NULL, updated_at = now()
        WHERE id = $1 AND locked_by = $2 AND status = 'running'
        RETURNING *`,
      [jobId, workerId, String(error?.message || error || "Unknown ingest error").slice(0, 4000), this.maxAttempts]
    );
    return result.rows[0] ? publicJob(result.rows[0]) : null;
  }

  async recoverStale(maxAgeMs = 15 * 60_000) {
    const seconds = Math.max(1, Math.floor(Number(maxAgeMs) / 1000));
    const result = await this.database.query(
      `UPDATE codmes_ingest_jobs
          SET status = CASE WHEN attempts >= $2 THEN 'failed' ELSE 'pending' END,
              error = COALESCE(error, 'Worker lease expired.'),
              locked_by = NULL, locked_at = NULL, updated_at = now()
        WHERE status = 'running'
          AND locked_at < now() - make_interval(secs => $1)
        RETURNING *`,
      [seconds, this.maxAttempts]
    );
    return result.rows.map(publicJob);
  }

  async list(workspaceId, limit = 100) {
    const result = await this.database.query(
      `SELECT * FROM codmes_ingest_jobs
        WHERE workspace_id = $1
        ORDER BY created_at DESC, id DESC
        LIMIT $2`,
      [workspaceId, Math.max(1, Math.min(500, Number(limit || 100)))]
    );
    return result.rows.map(publicJob);
  }
}

function publicJob(row) {
  return {
    id: row.id,
    workspaceId: row.workspace_id,
    documentId: row.document_id,
    jobType: row.job_type,
    status: row.status,
    progress: Number(row.progress),
    attempts: row.attempts,
    lockedBy: row.locked_by,
    error: row.error,
    payload: row.payload || {},
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

function clampProgress(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(0, Math.min(1, number)) : 0;
}
