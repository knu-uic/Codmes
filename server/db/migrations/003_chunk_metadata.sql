ALTER TABLE codmes_document_chunks
  ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
