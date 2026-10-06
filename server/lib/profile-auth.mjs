import crypto, { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import { hashSessionToken } from "./local-accounts.mjs";

const scrypt = promisify(crypto.scrypt);
const PIN_OPTIONS = { N: 16_384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const PROFILE_TOKEN_BYTES = 32;
const failedAttempts = new Map();

export function validateProfilePin(pin) {
  if (typeof pin !== "string" || !/^\d{4}$/.test(pin)) {
    throw Object.assign(new Error("Profile PIN must be exactly 4 digits."), { status: 400 });
  }
}

async function hashPin(pin) {
  validateProfilePin(pin);
  const salt = crypto.randomBytes(16);
  const hash = await scrypt(pin, salt, 32, PIN_OPTIONS);
  return `scrypt$${salt.toString("base64url")}$${Buffer.from(hash).toString("base64url")}`;
}

async function verifyPin(pin, encoded) {
  const [algorithm, saltText, hashText] = String(encoded || "").split("$");
  if (algorithm !== "scrypt" || !saltText || !hashText) return false;
  const expected = Buffer.from(hashText, "base64url");
  const actual = Buffer.from(await scrypt(String(pin || ""), Buffer.from(saltText, "base64url"), expected.length, PIN_OPTIONS));
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

export class ProfileAuthStore {
  constructor(database, accounts, workspaces) {
    this.database = database;
    this.accounts = accounts;
    this.workspaces = workspaces;
  }

  async list(userId, { includeDeleted = false } = {}) {
    const profiles = await this.workspaces.listForUser(userId, { includeDeleted });
    const ids = profiles.map((profile) => profile.id);
    if (!ids.length) return [];
    const result = await this.database.query(
      "SELECT id, profile_pin_hash IS NOT NULL AS locked FROM codmes_workspaces WHERE id = ANY($1::uuid[])",
      [ids]
    );
    const locked = new Map(result.rows.map((row) => [row.id, row.locked]));
    return profiles.map((profile) => ({ ...profile, locked: Boolean(locked.get(profile.id)), deleted: Boolean(profile.deletedAt) }));
  }

  async setInitialPin(user, workspaceId, pin, queryClient = this.database) {
    await this.workspaces.resolveForUser(user.id, workspaceId, "owner", queryClient);
    const hash = await hashPin(pin);
    const result = await queryClient.query(
      "UPDATE codmes_workspaces SET profile_pin_hash = $1, updated_at = now() WHERE id = $2 AND profile_pin_hash IS NULL AND deleted_at IS NULL RETURNING id",
      [hash, workspaceId]
    );
    if (!result.rowCount) throw Object.assign(new Error("Profile PIN is already set."), { status: 409 });
    return { locked: true };
  }

  async changePin(user, workspaceId, { currentPin, pin }) {
    if (user.role !== "admin") throw Object.assign(new Error("Client app locks are configured on the device, not on the server."), { status: 403 });
    await this.workspaces.resolveForUser(user.id, workspaceId, "owner");
    const hash = await hashPin(pin);
    await this.database.transaction(async (client) => {
      const profile = await client.query(
        "SELECT profile_pin_hash FROM codmes_workspaces WHERE id = $1 AND deleted_at IS NULL FOR UPDATE",
        [workspaceId]
      );
      if (!profile.rows[0]) throw Object.assign(new Error("Profile not found."), { status: 404 });
      if (user.role === "admin") await this.verifyManagementCredential(user, workspaceId, profile.rows[0].profile_pin_hash, currentPin);
      await client.query(
        "UPDATE codmes_workspaces SET profile_pin_hash = $1, updated_at = now() WHERE id = $2",
        [hash, workspaceId]
      );
      await client.query(
        "DELETE FROM codmes_profile_sessions WHERE workspace_id = $1",
        [workspaceId]
      );
    });
    return { locked: Boolean(hash) };
  }

  async archive(user, workspaceId, { currentPin }) {
    if (user.role !== "admin") await this.requireOwnClientProfile(user.id, workspaceId);
    await this.workspaces.resolveForUser(user.id, workspaceId, "owner");
    await this.database.transaction(async (client) => {
      const profile = await client.query(
        "SELECT profile_pin_hash FROM codmes_workspaces WHERE id = $1 AND deleted_at IS NULL FOR UPDATE",
        [workspaceId]
      );
      if (!profile.rows[0]) throw Object.assign(new Error("Profile not found."), { status: 404 });
      if (user.role === "admin") await this.verifyManagementCredential(user, workspaceId, profile.rows[0].profile_pin_hash, currentPin);
      await client.query("UPDATE codmes_workspaces SET deleted_at = now(), updated_at = now() WHERE id = $1", [workspaceId]);
      await client.query("DELETE FROM codmes_profile_sessions WHERE workspace_id = $1", [workspaceId]);
    });
    failedAttempts.delete(`${user.id}:${workspaceId}`);
    return { deleted: true };
  }

  async verifyManagementCredential(user, workspaceId, pinHash, currentPin) {
    if (!pinHash) {
      throw Object.assign(new Error("This older profile has no PIN. Set one in Server Manager first."), { status: 409 });
    }
    const attemptKey = `${user.id}:${workspaceId}`;
    const attempts = failedAttempts.get(attemptKey);
    if (attempts?.blockedUntil > Date.now()) {
      throw Object.assign(new Error("Too many attempts. Try again in one minute."), { status: 429 });
    }
    const valid = await verifyPin(currentPin, pinHash);
    if (!valid) {
      recordFailedAttempt(attemptKey, attempts);
      throw Object.assign(new Error("Incorrect current profile PIN."), { status: 403 });
    }
    failedAttempts.delete(attemptKey);
  }

  async listAllForAdmin(user) {
    requireAdministrator(user);
    const result = await this.database.query(
      `SELECT w.id, w.name, w.profile_pin_hash IS NOT NULL AS locked,
              w.deleted_at IS NOT NULL AS deleted, u.display_name AS owner_name
         FROM codmes_workspaces w
         JOIN codmes_users u ON u.id = w.owner_user_id
        WHERE u.password_hash <> 'disabled'
        ORDER BY w.created_at, w.id`
    );
    return result.rows.map((row) => ({
      id: row.id,
      name: row.name,
      locked: row.locked,
      deleted: row.deleted,
      ownerName: row.owner_name
    }));
  }

  async adminRename(user, workspaceId, name) {
    requireAdministrator(user);
    const profileName = String(name || "").normalize("NFKC").trim().slice(0, 120);
    if (!profileName) throw Object.assign(new Error("Profile name is required."), { status: 400 });
    const result = await this.database.query(
      "UPDATE codmes_workspaces SET name = $1, updated_at = now() WHERE id = $2 AND deleted_at IS NULL RETURNING id",
      [profileName, workspaceId]
    );
    if (!result.rowCount) throw Object.assign(new Error("Profile not found."), { status: 404 });
    return { name: profileName };
  }

  async adminSetPin(user, workspaceId, pin) {
    requireAdministrator(user);
    const hash = await hashPin(pin);
    await this.database.transaction(async (client) => {
      const result = await client.query(
        "UPDATE codmes_workspaces SET profile_pin_hash = $1, updated_at = now() WHERE id = $2 AND deleted_at IS NULL RETURNING id",
        [hash, workspaceId]
      );
      if (!result.rowCount) throw Object.assign(new Error("Profile not found."), { status: 404 });
      await client.query("DELETE FROM codmes_profile_sessions WHERE workspace_id = $1", [workspaceId]);
    });
    clearProfileAttempts(workspaceId);
    return { locked: true };
  }

  async adminArchive(user, workspaceId) {
    requireAdministrator(user);
    await this.database.transaction(async (client) => {
      const result = await client.query(
        "UPDATE codmes_workspaces SET deleted_at = now(), updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING id",
        [workspaceId]
      );
      if (!result.rowCount) throw Object.assign(new Error("Profile not found."), { status: 404 });
      await client.query("DELETE FROM codmes_profile_sessions WHERE workspace_id = $1", [workspaceId]);
    });
    clearProfileAttempts(workspaceId);
    return { deleted: true };
  }

  async adminRestore(user, workspaceId) {
    requireAdministrator(user);
    const result = await this.database.query(
      "UPDATE codmes_workspaces SET deleted_at = NULL, updated_at = now() WHERE id = $1 AND deleted_at IS NOT NULL RETURNING id",
      [workspaceId]
    );
    if (!result.rowCount) throw Object.assign(new Error("Archived profile not found."), { status: 404 });
    clearProfileAttempts(workspaceId);
    return { restored: true };
  }

  async open(accountToken, workspaceId, pin = "") {
    const session = await this.accounts.resolveSession(accountToken);
    if (!session) throw Object.assign(new Error("Sign in to the server first."), { status: 401 });
    if (session.authContext === "client") await this.requireOwnClientProfile(session.user.id, workspaceId);
    const profile = await this.workspaces.resolveForUser(session.user.id, workspaceId, "viewer");
    const result = await this.database.query(
      "SELECT profile_pin_hash FROM codmes_workspaces WHERE id = $1",
      [workspaceId]
    );
    const pinHash = session.authContext === "client" ? null : result.rows[0]?.profile_pin_hash;
    const attemptKey = `${session.user.id}:${workspaceId}`;
    const attempts = failedAttempts.get(attemptKey);
    if (attempts?.blockedUntil > Date.now()) {
      throw Object.assign(new Error("Too many PIN attempts. Try again in one minute."), { status: 429 });
    }
    if (pinHash && !await verifyPin(pin, pinHash)) {
      recordFailedAttempt(attemptKey, attempts);
      throw Object.assign(new Error("Incorrect profile PIN."), { status: 403 });
    }
    failedAttempts.delete(attemptKey);
    const token = crypto.randomBytes(PROFILE_TOKEN_BYTES).toString("base64url");
    await this.database.query(
      `INSERT INTO codmes_profile_sessions(id, account_session_id, workspace_id, token_hash, expires_at)
       VALUES ($1, $2, $3, $4, $5)`,
      [randomUUID(), session.sessionId, workspaceId, hashSessionToken(token), session.expiresAt]
    );
    return { token, expiresAt: session.expiresAt, profile: { id: profile.id, name: profile.name, role: profile.role, locked: Boolean(pinHash) } };
  }

  async requireOwnClientProfile(userId, workspaceId) {
    const result = await this.database.query(
      `SELECT p.workspace_id FROM codmes_account_profiles p
       JOIN codmes_workspaces w ON w.id = p.workspace_id
       WHERE p.user_id = $1 AND p.workspace_id = $2 AND w.deleted_at IS NULL`, [userId, workspaceId]
    );
    if (!result.rowCount) throw Object.assign(new Error("Register your own Google account profile first."), { status: 403 });
  }

  async resolve(token) {
    if (!token) return null;
    const result = await this.database.query(
      `SELECT p.workspace_id, u.id AS user_id, u.username_normalized, u.display_name,
              CASE WHEN s.auth_context = 'client' THEN 'user' ELSE u.role END AS role, u.status,
              r.id AS registration_id
         FROM codmes_profile_sessions p
         JOIN codmes_auth_sessions s ON s.id = p.account_session_id
         LEFT JOIN codmes_client_registrations r ON r.id = s.registration_id
         JOIN codmes_workspaces w ON w.id = p.workspace_id AND w.deleted_at IS NULL
         JOIN codmes_users u ON u.id = s.user_id
        WHERE p.token_hash = $1 AND p.expires_at > now() AND s.expires_at > now()
          AND u.status = 'active'
          AND (s.auth_context <> 'client' OR (r.id IS NOT NULL AND r.status = 'approved' AND r.user_id = s.user_id
            AND EXISTS (SELECT 1 FROM codmes_account_profiles gp
                        WHERE gp.user_id = u.id AND gp.workspace_id = w.id)))`,
      [hashSessionToken(token)]
    );
    const row = result.rows[0];
    if (!row) return null;
    return {
      workspaceId: row.workspace_id,
      deviceId: row.registration_id || null,
      user: {
        id: row.user_id,
        username: row.username_normalized,
        displayName: row.display_name,
        role: row.role,
        status: row.status
      }
    };
  }
}

function recordFailedAttempt(key, attempts) {
  const count = (attempts?.count || 0) + 1;
  failedAttempts.set(key, {
    count: count >= 5 ? 0 : count,
    blockedUntil: count >= 5 ? Date.now() + 60_000 : 0
  });
}

function clearProfileAttempts(workspaceId) {
  for (const key of failedAttempts.keys()) {
    if (key.endsWith(`:${workspaceId}`)) failedAttempts.delete(key);
  }
}

function requireAdministrator(user) {
  if (user?.role !== "admin") {
    throw Object.assign(new Error("Administrator access is required."), { status: 403 });
  }
}
