CREATE TABLE codmes_google_identities (
  subject text PRIMARY KEY,
  user_id uuid NOT NULL UNIQUE REFERENCES codmes_users(id) ON DELETE CASCADE,
  email text NOT NULL DEFAULT '',
  display_name text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE codmes_client_registrations (
  id uuid PRIMARY KEY,
  google_subject text NOT NULL REFERENCES codmes_google_identities(subject) ON DELETE CASCADE,
  device_id_hash text NOT NULL,
  device_name text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  request_token_hash text,
  request_token_expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  UNIQUE(google_subject, device_id_hash)
);
CREATE INDEX codmes_client_registrations_status_idx
  ON codmes_client_registrations(status, created_at);

ALTER TABLE codmes_auth_sessions
  ADD COLUMN auth_context text NOT NULL DEFAULT 'legacy'
    CHECK (auth_context IN ('legacy', 'manager', 'client')),
  ADD COLUMN registration_id uuid REFERENCES codmes_client_registrations(id) ON DELETE SET NULL;
CREATE INDEX codmes_auth_sessions_registration_idx ON codmes_auth_sessions(registration_id);

CREATE TABLE codmes_auth_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  client_approval_mode text NOT NULL DEFAULT 'ask' CHECK (client_approval_mode IN ('ask', 'allow')),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO codmes_auth_settings(id) VALUES (1);
