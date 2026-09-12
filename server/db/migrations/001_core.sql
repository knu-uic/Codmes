CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE codmes_users (
  id uuid PRIMARY KEY,
  username_normalized text NOT NULL UNIQUE,
  display_name text NOT NULL,
  password_hash text NOT NULL,
  role text NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE codmes_auth_sessions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES codmes_users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  device_name text NOT NULL DEFAULT '',
  expires_at timestamptz NOT NULL,
  last_used_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX codmes_auth_sessions_user_idx ON codmes_auth_sessions(user_id);
CREATE INDEX codmes_auth_sessions_expiry_idx ON codmes_auth_sessions(expires_at);

CREATE TABLE codmes_workspaces (
  id uuid PRIMARY KEY,
  owner_user_id uuid NOT NULL REFERENCES codmes_users(id),
  name text NOT NULL,
  storage_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE codmes_workspace_members (
  workspace_id uuid NOT NULL REFERENCES codmes_workspaces(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES codmes_users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'editor', 'viewer')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);
CREATE INDEX codmes_workspace_members_user_idx ON codmes_workspace_members(user_id);

CREATE TABLE codmes_documents (
  id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL REFERENCES codmes_workspaces(id) ON DELETE CASCADE,
  relative_path text NOT NULL,
  content_hash text NOT NULL,
  mime_type text NOT NULL DEFAULT 'application/octet-stream',
  size_bytes bigint NOT NULL DEFAULT 0,
  document_kind text NOT NULL DEFAULT 'file',
  pdf_type text CHECK (pdf_type IS NULL OR pdf_type IN ('digital', 'scanned', 'mixed')),
  ingest_status text NOT NULL DEFAULT 'pending' CHECK (ingest_status IN ('pending', 'running', 'completed', 'failed')),
  extraction_version text,
  indexed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, relative_path)
);
CREATE INDEX codmes_documents_workspace_idx ON codmes_documents(workspace_id);
CREATE INDEX codmes_documents_hash_idx ON codmes_documents(workspace_id, content_hash);

CREATE TABLE codmes_document_assets (
  id uuid PRIMARY KEY,
  document_id uuid NOT NULL REFERENCES codmes_documents(id) ON DELETE CASCADE,
  page_number integer,
  kind text NOT NULL,
  bbox jsonb,
  sha256 text NOT NULL,
  storage_path text NOT NULL,
  description text NOT NULL DEFAULT '',
  ocr_text text NOT NULL DEFAULT '',
  requires_review boolean NOT NULL DEFAULT false,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, sha256, storage_path)
);
CREATE INDEX codmes_document_assets_document_idx ON codmes_document_assets(document_id);

CREATE TABLE codmes_embedding_profiles (
  id uuid PRIMARY KEY,
  provider text NOT NULL,
  model text NOT NULL,
  dimensions integer NOT NULL CHECK (dimensions = 1024),
  model_revision text NOT NULL DEFAULT '',
  chunking_version integer NOT NULL,
  document_engine_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, model, dimensions, model_revision, chunking_version, document_engine_version)
);

CREATE TABLE codmes_document_chunks (
  id text PRIMARY KEY,
  document_id uuid NOT NULL REFERENCES codmes_documents(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES codmes_workspaces(id) ON DELETE CASCADE,
  profile_id uuid REFERENCES codmes_embedding_profiles(id),
  page_number integer,
  chunk_index integer NOT NULL,
  text text NOT NULL,
  search_text text NOT NULL,
  bbox jsonb,
  related_asset_ids uuid[] NOT NULL DEFAULT '{}',
  related_images jsonb NOT NULL DEFAULT '[]'::jsonb,
  content_hash text NOT NULL,
  embedding vector(1024),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, chunk_index)
);
CREATE INDEX codmes_document_chunks_workspace_idx ON codmes_document_chunks(workspace_id);
CREATE INDEX codmes_document_chunks_document_idx ON codmes_document_chunks(document_id);
CREATE INDEX codmes_document_chunks_search_trgm_idx
  ON codmes_document_chunks USING gin (search_text gin_trgm_ops);
CREATE INDEX codmes_document_chunks_embedding_hnsw_idx
  ON codmes_document_chunks USING hnsw (embedding vector_cosine_ops)
  WHERE embedding IS NOT NULL;

CREATE TABLE codmes_ingest_jobs (
  id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL REFERENCES codmes_workspaces(id) ON DELETE CASCADE,
  document_id uuid REFERENCES codmes_documents(id) ON DELETE CASCADE,
  job_type text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  progress real NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 1),
  attempts integer NOT NULL DEFAULT 0,
  locked_by text,
  locked_at timestamptz,
  error text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX codmes_ingest_jobs_claim_idx ON codmes_ingest_jobs(status, created_at);
