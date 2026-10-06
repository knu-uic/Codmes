ALTER TABLE codmes_workspaces
  ADD COLUMN profile_pin_hash text;

CREATE TABLE codmes_profile_sessions (
  id uuid PRIMARY KEY,
  account_session_id uuid NOT NULL REFERENCES codmes_auth_sessions(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES codmes_workspaces(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX codmes_profile_sessions_expiry_idx ON codmes_profile_sessions(expires_at);
