import crypto, { randomUUID } from "node:crypto";
import { promisify } from "node:util";

const scrypt = promisify(crypto.scrypt);
const SESSION_BYTES = 32;
const DEFAULT_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const SCRYPT_OPTIONS = Object.freeze({ N: 16_384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });

export function normalizeLocalUsername(value) {
  const username = String(value || "").normalize("NFKC").trim().toLocaleLowerCase("en-US");
  if (!/^[\p{L}\p{N}][\p{L}\p{N}._-]{2,63}$/u.test(username)) {
    throw Object.assign(
      new Error("Username must be 3-64 letters, numbers, dots, underscores, or hyphens."),
      { status: 400 }
    );
  }
  return username;
}

export async function hashLocalPassword(password) {
  validatePassword(password);
  const salt = crypto.randomBytes(16);
  const derived = await scrypt(String(password), salt, 32, SCRYPT_OPTIONS);
  return [
    "scrypt",
    SCRYPT_OPTIONS.N,
    SCRYPT_OPTIONS.r,
    SCRYPT_OPTIONS.p,
    salt.toString("base64url"),
    Buffer.from(derived).toString("base64url")
  ].join("$");
}

export async function verifyLocalPassword(password, encoded) {
  const [algorithm, n, r, p, saltText, hashText] = String(encoded || "").split("$");
  if (algorithm !== "scrypt" || !saltText || !hashText) return false;
  const expected = Buffer.from(hashText, "base64url");
  const actual = Buffer.from(await scrypt(
    String(password || ""),
    Buffer.from(saltText, "base64url"),
    expected.length,
    {
      N: Number(n),
      r: Number(r),
      p: Number(p),
      maxmem: 64 * 1024 * 1024
    }
  ));
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

export function hashSessionToken(token) {
  return crypto.createHash("sha256").update(String(token || "")).digest("hex");
}

export class LocalAccountStore {
  constructor(database, options = {}) {
    this.database = database;
    this.sessionTtlMs = Number(options.sessionTtlMs || DEFAULT_SESSION_TTL_MS);
    this.now = options.now || (() => new Date());
  }

  async hasUsers() {
    const result = await this.database.query("SELECT EXISTS(SELECT 1 FROM codmes_users) AS exists");
    return Boolean(result.rows[0]?.exists);
  }

  async listUsers(actor) {
    if (actor?.role !== "admin") {
      throw Object.assign(new Error("Administrator access is required."), { status: 403 });
    }
    const result = await this.database.query(
      "SELECT id, username_normalized, display_name, role, status FROM codmes_users ORDER BY created_at, id"
    );
    return result.rows.map(publicUser);
  }

  async bootstrapAdmin({ username, displayName, password }) {
    const normalized = normalizeLocalUsername(username);
    const passwordHash = await hashLocalPassword(password);
    return await this.database.transaction(async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtext('codmes-bootstrap-admin'))");
      const count = await client.query("SELECT count(*)::int AS count FROM codmes_users");
      if (count.rows[0].count > 0) {
        throw Object.assign(new Error("Codmes already has a local administrator."), { status: 409 });
      }
      const user = await insertUser(client, {
        username: normalized,
        displayName,
        passwordHash,
        role: "admin"
      });
      return publicUser(user);
    });
  }

  async createUser(actor, { username, displayName, password, role = "user" }) {
    if (actor?.role !== "admin") {
      throw Object.assign(new Error("Administrator access is required."), { status: 403 });
    }
    if (!new Set(["admin", "user"]).has(role)) {
      throw Object.assign(new Error("Invalid local account role."), { status: 400 });
    }
    const passwordHash = await hashLocalPassword(password);
    try {
      const user = await insertUser(this.database, {
        username: normalizeLocalUsername(username),
        displayName,
        passwordHash,
        role
      });
      return publicUser(user);
    } catch (error) {
      if (error?.code === "23505") {
        throw Object.assign(new Error("That username is already in use."), { status: 409 });
      }
      throw error;
    }
  }

  async login({ username, password, deviceName = "" }) {
    const normalized = normalizeLocalUsername(username);
    const result = await this.database.query(
      "SELECT * FROM codmes_users WHERE username_normalized = $1",
      [normalized]
    );
    const user = result.rows[0];
    const valid = user && user.status === "active"
      ? await verifyLocalPassword(password, user.password_hash)
      : false;
    if (!valid) {
      throw Object.assign(new Error("Invalid username or password."), { status: 401 });
    }
    const token = crypto.randomBytes(SESSION_BYTES).toString("base64url");
    const expiresAt = new Date(this.now().getTime() + this.sessionTtlMs);
    await this.database.query(
      `INSERT INTO codmes_auth_sessions(id, user_id, token_hash, device_name, expires_at)
       VALUES ($1, $2, $3, $4, $5)`,
      [randomUUID(), user.id, hashSessionToken(token), String(deviceName || "").slice(0, 200), expiresAt]
    );
    return { token, expiresAt: expiresAt.toISOString(), user: publicUser(user) };
  }

  async resolveToken(token) {
    if (!token) return null;
    const result = await this.database.query(
      `SELECT u.id, u.username_normalized, u.display_name, u.role, u.status, s.id AS session_id
         FROM codmes_auth_sessions s
         JOIN codmes_users u ON u.id = s.user_id
        WHERE s.token_hash = $1 AND s.expires_at > now() AND u.status = 'active'`,
      [hashSessionToken(token)]
    );
    const user = result.rows[0];
    if (!user) return null;
    await this.database.query(
      "UPDATE codmes_auth_sessions SET last_used_at = now() WHERE id = $1",
      [user.session_id]
    );
    return publicUser(user);
  }

  async logout(token) {
    if (!token) return { revoked: false };
    const result = await this.database.query(
      "DELETE FROM codmes_auth_sessions WHERE token_hash = $1",
      [hashSessionToken(token)]
    );
    return { revoked: result.rowCount > 0 };
  }

  async pruneExpiredSessions() {
    const result = await this.database.query("DELETE FROM codmes_auth_sessions WHERE expires_at <= now()");
    return { removed: result.rowCount };
  }
}

async function insertUser(queryable, { username, displayName, passwordHash, role }) {
  const name = String(displayName || username).normalize("NFKC").trim().slice(0, 100);
  if (!name) throw Object.assign(new Error("Display name is required."), { status: 400 });
  const result = await queryable.query(
    `INSERT INTO codmes_users(id, username_normalized, display_name, password_hash, role)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING *`,
    [randomUUID(), username, name, passwordHash, role]
  );
  return result.rows[0];
}

function validatePassword(password) {
  const value = String(password || "");
  if (value.length < 10 || value.length > 1024) {
    throw Object.assign(new Error("Password must contain 10-1024 characters."), { status: 400 });
  }
}

function publicUser(user) {
  return {
    id: user.id,
    username: user.username_normalized,
    displayName: user.display_name,
    role: user.role,
    status: user.status
  };
}
