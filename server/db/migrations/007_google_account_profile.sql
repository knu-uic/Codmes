CREATE TABLE codmes_google_profiles (
  user_id uuid PRIMARY KEY REFERENCES codmes_google_identities(user_id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL UNIQUE REFERENCES codmes_workspaces(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Preserve an existing unambiguous owned profile. Shared membership is NOT
-- ownership and must never attach another account's profile to this identity.
INSERT INTO codmes_google_profiles(user_id, workspace_id)
SELECT g.user_id, w.id
FROM codmes_google_identities g
JOIN codmes_workspaces w ON w.owner_user_id = g.user_id AND w.deleted_at IS NULL
WHERE (SELECT count(*) FROM codmes_workspaces owned
       WHERE owned.owner_user_id = g.user_id AND owned.deleted_at IS NULL) = 1;
