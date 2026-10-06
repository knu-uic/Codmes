ALTER TABLE codmes_workspaces
  ADD COLUMN deleted_at timestamptz;

CREATE INDEX codmes_workspaces_deleted_at_idx ON codmes_workspaces(deleted_at)
  WHERE deleted_at IS NOT NULL;
