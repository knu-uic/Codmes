import crypto, { randomUUID } from "node:crypto";
import { hashAccountPassword, verifyAccountPassword, normalizeAccountId } from "./account-password.mjs";

const SESSION_BYTES = 32;
const DEFAULT_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export function maskAccountIdentifier(value, email = false) {
  const text = String(value || "").trim();
  if (!text) return "";
  const at = email ? text.lastIndexOf("@") : -1;
  const local = at > 0 ? text.slice(0, at) : text;
  const letters = [...local];
  // Never expose a full short ID, nor the length of a password-like identifier.
  const masked = `${letters[0]}***${letters.length > 4 ? letters.slice(-2).join("") : ""}`;
  return at > 0 ? `${masked}${text.slice(at)}` : masked;
}

export function hashSessionToken(token) {
  return crypto.createHash("sha256").update(String(token || "")).digest("hex");
}

export class LocalAccountStore {
  constructor(database, options = {}) {
    this.database = database;
    this.sessionTtlMs = Number(options.sessionTtlMs || DEFAULT_SESSION_TTL_MS);
    this.now = options.now || (() => new Date());
    this.attempts = new Map();
  }

  async hasAdministrator() {
    return Boolean((await this.database.query("SELECT EXISTS(SELECT 1 FROM codmes_users WHERE role = 'admin' AND status = 'active') AS exists")).rows[0]?.exists);
  }

  async managerSetupSummary() {
    const existing = await this.hasUsers();
    const row = (await this.database.query(`SELECT u.username_normalized, g.email
      FROM codmes_users u LEFT JOIN codmes_google_identities g ON g.user_id = u.id
      WHERE u.role = 'admin' ORDER BY u.created_at LIMIT 1`)).rows[0];
    return {
      existingServer: existing,
      maskedAccount: row ? {
        id: maskAccountIdentifier(row.username_normalized),
        email: maskAccountIdentifier(row.email, true),
      } : null,
    };
  }

  registrationBudget(origin) {
    const key = `signup:${origin}`;
    const now = Date.now();
    const entry = this.attempts.get(key);
    if (entry && entry.until > now && entry.count >= 20) throw Object.assign(new Error("등록 요청이 많습니다. 15분 후 다시 시도하세요."), { status: 429 });
    if (this.attempts.size > 10000) throw Object.assign(new Error("잠시 후 다시 시도하세요."), { status: 429 });
    this.attempts.set(key, entry && entry.until > now ? { ...entry, count: entry.count + 1 } : { count: 1, until: now + 900000 });
  }

  async createAccount({ username, password, displayName }, role = "user", queryable = this.database) {
    const id = normalizeAccountId(username);
    const hash = await hashAccountPassword(password);
    try {
      return (await queryable.query(`INSERT INTO codmes_users(id, username_normalized, display_name, password_hash, role, credentials_configured)
        VALUES ($1,$2,$3,$4,$5,true) RETURNING *`, [randomUUID(), id, String(displayName || id).trim().slice(0,100), hash, role])).rows[0];
    } catch (error) {
      if (error.code === "23505") throw Object.assign(new Error("이미 사용 중인 ID입니다. 기존 계정으로 로그인한 후 Google을 연결하세요."), { status: 409 });
      throw error;
    }
  }

  async authenticate(username, password, origin = "") {
    let id;
    try { id = normalizeAccountId(username); } catch { id = "invalid-id"; }
    const now = Date.now();
    // Rate-limit both per ID and per origin, including unknown IDs; never store passwords.
    for (const [key, entry] of this.attempts) if (entry.until <= now) this.attempts.delete(key);
    const keys = [`id:${id}`, `origin:${origin}`];
    if (keys.some(key => (this.attempts.get(key)?.count || 0) >= (key.startsWith("id:") ? 10 : 40))) throw Object.assign(new Error("로그인 시도가 많습니다. 15분 후 다시 시도하세요."), { status: 429 });
    if (this.attempts.size > 10000) throw Object.assign(new Error("잠시 후 다시 시도하세요."), { status: 429 });
    for (const key of keys) { const entry = this.attempts.get(key) || { count: 0, until: now + 900000 }; entry.count++; this.attempts.set(key, entry); }
    const user = (await this.database.query("SELECT * FROM codmes_users WHERE username_normalized = $1", [id])).rows[0];
    const valid = await verifyAccountPassword(password, user?.password_hash);
    if (!valid || !user?.credentials_configured || user.status !== "active") throw Object.assign(new Error("ID 또는 비밀번호를 확인하세요."), { status: 401 });
    this.attempts.delete(`id:${id}`);
    return user;
  }

  async accountInfo(userId, queryable = this.database) {
    const row = (await queryable.query(`SELECT u.*, g.email FROM codmes_users u LEFT JOIN codmes_google_identities g ON g.user_id = u.id WHERE u.id = $1`, [userId])).rows[0];
    if (!row) throw Object.assign(new Error("Account not found."), { status: 401 });
    return publicUser(row);
  }

  async configureCredentials(userId, { username, password }, session = null) {
    const id = normalizeAccountId(username);
    const hash = await hashAccountPassword(password);
    try {
      await this.database.transaction(async client => {
        await client.query("SELECT id FROM codmes_users WHERE id=$1 FOR UPDATE", [userId]);
        if (session && !(await client.query("SELECT id FROM codmes_auth_sessions WHERE id=$1 AND user_id=$2 AND expires_at>now()",[session.sessionId,userId])).rowCount) throw Object.assign(new Error("다시 로그인하세요."),{status:401});
        const result = await client.query(`UPDATE codmes_users SET username_normalized=$2, password_hash=$3, credentials_configured=true, updated_at=now()
          WHERE id=$1 AND NOT credentials_configured AND status='active' RETURNING id`, [userId, id, hash]);
        if (!result.rowCount) throw Object.assign(new Error("이미 Codmes 계정이 설정되어 있습니다."), { status: 409 });
      });
    } catch (error) {
      if (error.code === "23505") throw Object.assign(new Error("이미 사용 중인 ID입니다."), { status: 409 });
      throw error;
    }
    return { user: await this.accountInfo(userId) };
  }

  async requirePassword(userId, password, origin = "") {
    const row = (await this.database.query("SELECT username_normalized FROM codmes_users WHERE id=$1", [userId])).rows[0];
    const verified = await this.authenticate(row?.username_normalized, password, origin);
    if (verified.id !== userId) throw Object.assign(new Error("비밀번호를 확인하세요."), { status: 401 });
    return verified.password_hash;
  }

  async guardAccountMutation(session, passwordHash, client) {
    const row = (await client.query("SELECT * FROM codmes_users WHERE id=$1 FOR UPDATE", [session.user.id])).rows[0];
    const activeSession = (await client.query("SELECT id FROM codmes_auth_sessions WHERE id=$1 AND user_id=$2 AND expires_at>now()", [session.sessionId,session.user.id])).rows[0];
    if (!activeSession || row?.status !== "active" || row.password_hash !== passwordHash) throw Object.assign(new Error("계정이 변경되었습니다. 다시 로그인하세요."), { status: 401 });
  }

  async issuePasswordSession(verified, options) {
    return await this.database.transaction(async client => {
      const row = (await client.query("SELECT * FROM codmes_users WHERE id=$1 FOR UPDATE",[verified.id])).rows[0];
      if (row?.status !== "active" || row.password_hash !== verified.password_hash || !row.credentials_configured) throw Object.assign(new Error("다시 로그인하세요."),{status:401});
      return { ...await this.issueSession(row.id, options, client), user: await this.accountInfo(row.id,client) };
    });
  }

  async changePassword(session, { currentPassword, password }, origin) {
    const previousHash = await this.requirePassword(session.user.id, currentPassword, origin);
    const hash = await hashAccountPassword(password);
    await this.database.transaction(async client => {
      await this.guardAccountMutation(session, previousHash, client);
      await client.query("UPDATE codmes_users SET password_hash=$2, updated_at=now() WHERE id=$1", [session.user.id, hash]);
      await client.query("DELETE FROM codmes_auth_sessions WHERE user_id=$1 AND id<>$2", [session.user.id, session.sessionId]);
    });
    return { user: await this.accountInfo(session.user.id) };
  }

  async hasUsers() {
    const result = await this.database.query("SELECT EXISTS(SELECT 1 FROM codmes_users) AS exists");
    return Boolean(result.rows[0]?.exists);
  }

  async issueSession(userId, { deviceName = "", authContext = "client", registrationId = null } = {}, queryable = this.database) {
    if (!["manager", "client"].includes(authContext)) {
      throw Object.assign(new Error("Invalid session type."), { status: 400 });
    }
    const result = await queryable.query(
      "SELECT id, username_normalized, display_name, role, status, credentials_configured FROM codmes_users WHERE id = $1 AND status = 'active'",
      [userId]
    );
    if (!result.rows[0]) throw Object.assign(new Error("Account is not active."), { status: 403 });
    const token = crypto.randomBytes(SESSION_BYTES).toString("base64url");
    const expiresAt = new Date(this.now().getTime() + this.sessionTtlMs);
    await queryable.query(
      `INSERT INTO codmes_auth_sessions(id, user_id, token_hash, device_name, expires_at, auth_context, registration_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [randomUUID(), userId, hashSessionToken(token), String(deviceName || "").slice(0, 200), expiresAt, authContext, registrationId]
    );
    const user = publicUser(result.rows[0]);
    if (authContext === "client") user.role = "user";
    return { token, expiresAt: expiresAt.toISOString(), user };
  }

  async resolveToken(token) {
    const session = await this.resolveSession(token);
    return session?.user || null;
  }

  async resolveSession(token) {
    if (!token) return null;
    const result = await this.database.query(
      `SELECT u.id, u.username_normalized, u.display_name, u.role, u.status, u.credentials_configured,
              s.id AS session_id, s.expires_at, s.auth_context
         FROM codmes_auth_sessions s
         JOIN codmes_users u ON u.id = s.user_id
         LEFT JOIN codmes_client_registrations r ON r.id = s.registration_id
        WHERE s.token_hash = $1 AND s.expires_at > now() AND u.status = 'active'
          AND (s.auth_context <> 'client' OR (r.id IS NOT NULL AND r.status = 'approved' AND r.user_id = s.user_id))`,
      [hashSessionToken(token)]
    );
    const user = result.rows[0];
    if (!user) return null;
    await this.database.query(
      "UPDATE codmes_auth_sessions SET last_used_at = now() WHERE id = $1",
      [user.session_id]
    );
    const publicAccount = publicUser(user);
    if (user.auth_context === "client") publicAccount.role = "user";
    return { user: publicAccount, sessionId: user.session_id, expiresAt: user.expires_at, authContext: user.auth_context };
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

function publicUser(user) {
  return {
    id: user.id,
    username: user.username_normalized,
    displayName: user.display_name,
    role: user.role,
    status: user.status,
    credentialsConfigured: Boolean(user.credentials_configured),
    email: user.email || "",
    googleLinked: Boolean(user.email)
  };
}
