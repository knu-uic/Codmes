-- Preserve account, profile and device IDs while making Google optional.
ALTER TABLE codmes_users ADD COLUMN credentials_configured boolean NOT NULL DEFAULT false;
ALTER TABLE codmes_google_profiles RENAME TO codmes_account_profiles;
ALTER TABLE codmes_account_profiles DROP CONSTRAINT codmes_google_profiles_user_id_fkey;
ALTER TABLE codmes_account_profiles ADD FOREIGN KEY (user_id) REFERENCES codmes_users(id) ON DELETE CASCADE;
ALTER TABLE codmes_client_registrations ADD COLUMN user_id uuid REFERENCES codmes_users(id) ON DELETE CASCADE;
UPDATE codmes_client_registrations r SET user_id = g.user_id FROM codmes_google_identities g WHERE g.subject = r.google_subject;
ALTER TABLE codmes_client_registrations ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE codmes_client_registrations DROP COLUMN google_subject;
ALTER TABLE codmes_client_registrations ADD UNIQUE (user_id, device_id_hash);
