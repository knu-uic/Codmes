ALTER TABLE codmes_workspaces
  ADD COLUMN root_path text;

CREATE UNIQUE INDEX codmes_workspaces_root_path_unique
  ON codmes_workspaces(root_path)
  WHERE root_path IS NOT NULL;
