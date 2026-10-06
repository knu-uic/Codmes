import crypto, { randomUUID } from "node:crypto";
import { hashSessionToken } from "./local-accounts.mjs";



function httpError(message, status) {
  return Object.assign(new Error(message), { status });
}

function publicUser(row, role = row.role) {
  return {
    id: row.id,
    username: row.username_normalized,
    displayName: row.display_name,
    role,
    status: row.status
  };
}

function deviceHash(deviceId) {
  const value = String(deviceId || "");
  if (!/^[A-Za-z0-9_-]{43,128}$/.test(value)) {
    throw httpError("A persistent random device ID is required.", 400);
  }
  return crypto.createHash("sha256").update(value).digest("hex");
}

function deviceLabel(deviceName) {
  return String(deviceName || "Codmes client").normalize("NFKC").trim().slice(0, 200);
}

function requestToken() {
  return crypto.randomBytes(32).toString("base64url");
}

function assertUuid(value) {
  const id = String(value || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    throw httpError("Registration not found.", 404);
  }
  return id;
}

function publicRegistration(row) {
  return {
    id: row.id,
    email: row.email || "",
    displayName: row.display_name || row.username_normalized || "Codmes user",
    username: row.username_normalized || "",
    deviceName: row.device_name,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    approvedAt: row.approved_at
  };
}

export class GoogleAuthStore {
  constructor(database, accounts) {
    this.database = database;
    this.accounts = accounts;
  }

  async hasAdminLink() {
    const result = await this.database.query(
      `SELECT EXISTS(
         SELECT 1 FROM codmes_google_identities g
         JOIN codmes_users u ON u.id = g.user_id
         WHERE u.role = 'admin' AND u.status = 'active'
       ) AS exists`
    );
    return Boolean(result.rows[0]?.exists);
  }

  async approvalMode() {
    const result = await this.database.query("SELECT client_approval_mode FROM codmes_auth_settings WHERE id = 1");
    return result.rows[0]?.client_approval_mode || "ask";
  }

  async bootstrapAdmin(identity, options = {}, workspaces) {
    const { user, workspace } = await this.database.transaction(async client => {
      await client.query("SELECT pg_advisory_xact_lock(hashtext('codmes-bootstrap-admin'))");
      if ((await client.query("SELECT count(*)::int AS count FROM codmes_users")).rows[0].count > 0) throw httpError("이미 초기화된 서버입니다. 관리자 계정으로 로그인하세요.", 409);
      const row = await this.accounts.createAccount({ ...options, displayName: options.displayName || identity?.displayName }, "admin", client);
      if (identity) await this.insertIdentity(client, row.id, identity);
      const user = publicUser(row);
      const workspace = await workspaces.createWorkspace(user, { name: options.workspaceName || "My Profile" }, client);
      await client.query("INSERT INTO codmes_account_profiles(user_id, workspace_id) VALUES ($1,$2)", [user.id, workspace.id]);
      return { user, workspace };
    });
    return { ...await this.accounts.issueSession(user.id, { deviceName: "Server Manager", authContext: "manager" }),
      user: await this.accounts.accountInfo(user.id), workspace };
  }

  async insertIdentity(client, userId, identity) {
    try {
      await client.query("INSERT INTO codmes_google_identities(subject,user_id,email,display_name) VALUES ($1,$2,$3,$4)", [identity.subject,userId,identity.email,identity.displayName]);
    } catch (error) {
      if (error.code === "23505") throw httpError("이 Google 계정은 다른 Codmes 계정에 연결되어 있습니다.", 409);
      throw error;
    }
  }

  async linkGoogle(session, identity, currentPassword, origin) {
    const previousHash = await this.accounts.requirePassword(session.user.id, currentPassword, origin);
    await this.database.transaction(async client => {
      await this.accounts.guardAccountMutation(session, previousHash, client);
      const owner = (await client.query("SELECT user_id FROM codmes_google_identities WHERE subject=$1", [identity.subject])).rows[0];
      if (owner && owner.user_id !== session.user.id) throw httpError("이 Google 계정은 다른 Codmes 계정에 연결되어 있습니다. 계정은 자동 합쳐지지 않습니다.", 409);
      await client.query("DELETE FROM codmes_google_identities WHERE user_id=$1", [session.user.id]);
      await this.insertIdentity(client, session.user.id, identity);
      await client.query("DELETE FROM codmes_auth_sessions WHERE user_id=$1 AND id<>$2", [session.user.id,session.sessionId]);
    });
    return { user: await this.accounts.accountInfo(session.user.id) };
  }

  async unlinkGoogle(session, currentPassword, origin) {
    const previousHash = await this.accounts.requirePassword(session.user.id, currentPassword, origin);
    await this.database.transaction(async client => {
      await this.accounts.guardAccountMutation(session, previousHash, client);
      await client.query("DELETE FROM codmes_google_identities WHERE user_id=$1", [session.user.id]);
      await client.query("DELETE FROM codmes_auth_sessions WHERE user_id=$1 AND id<>$2", [session.user.id,session.sessionId]);
    });
    return { user: await this.accounts.accountInfo(session.user.id) };
  }

  async loginAdmin(identity, deviceName = "Server Manager") {
    return await this.database.transaction(async client => {
    const result = await client.query(
      `SELECT u.id FROM codmes_google_identities g
       JOIN codmes_users u ON u.id = g.user_id
       WHERE g.subject = $1 AND u.role = 'admin' AND u.status = 'active' FOR UPDATE OF u`,
      [identity.subject]
    );
    if (!result.rows[0]) throw httpError("This Google account is not an administrator of this server.", 403);
    if (!(await client.query("SELECT user_id FROM codmes_google_identities WHERE subject=$1 AND user_id=$2",[identity.subject,result.rows[0].id])).rowCount) throw httpError("Google 연결이 변경되었습니다. 다시 로그인하세요.",401);
    await client.query("UPDATE codmes_google_identities SET email=$2,display_name=$3,updated_at=now() WHERE subject=$1",[identity.subject,identity.email,identity.displayName]);
    const session = await this.accounts.issueSession(result.rows[0].id, { deviceName, authContext: "manager" },client);
    return { ...session, user: await this.accounts.accountInfo(result.rows[0].id,client) };
    });
  }

  async updateIdentity(identity) {
    await this.database.query(
      `UPDATE codmes_google_identities
       SET email = $2, display_name = $3, updated_at = now()
       WHERE subject = $1`,
      [identity.subject, identity.email, identity.displayName]
    );
  }

  async loginClient(identity, options) {
    deviceHash(options.deviceId);
    if (!await this.accounts.hasAdministrator()) throw httpError("먼저 Server Manager에서 관리자 계정을 만드세요.", 409);
    const userId = await this.database.transaction(async client => {
      await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [`codmes-google-${identity.subject}`]);
      let user = (await client.query("SELECT u.* FROM codmes_users u JOIN codmes_google_identities g ON g.user_id=u.id WHERE g.subject=$1 FOR UPDATE OF u", [identity.subject])).rows[0];
      if (user?.status && user.status !== "active") throw httpError("This account is disabled.", 403);
      if (!user?.credentials_configured) {
        if (user?.role === "admin") throw httpError("먼저 Server Manager에서 관리자 Codmes ID·비밀번호를 설정하세요. 기존 자료는 유지됩니다.", 403);
        if (!options.username || !options.password) return null;
        if (user) {
          // A freshly verified Google identity authorizes configuring its existing
          // account only. Keep the same UUID, profile and approved device records.
          const { hashAccountPassword, normalizeAccountId } = await import("./account-password.mjs");
          const hash = await hashAccountPassword(options.password);
          try {
            user = (await client.query("UPDATE codmes_users SET username_normalized=$2,password_hash=$3,credentials_configured=true,updated_at=now() WHERE id=$1 RETURNING *",
              [user.id,normalizeAccountId(options.username),hash])).rows[0];
          } catch (error) {
            if (error.code === "23505") throw httpError("이미 사용 중인 ID입니다. 기존 계정으로 로그인한 후 Google을 연결하세요.",409);
            throw error;
          }
        } else {
          user = await this.accounts.createAccount({ ...options, displayName: identity.displayName }, "user", client);
          await this.insertIdentity(client,user.id,identity);
        }
      }
      await client.query("UPDATE codmes_google_identities SET email=$2,display_name=$3,updated_at=now() WHERE subject=$1", [identity.subject,identity.email,identity.displayName]);
      return user.id;
    });
    if (!userId) return { status: "account_setup_required", user: { id: "", email: identity.email, displayName: identity.displayName, credentialsConfigured: false, googleLinked: true } };
    return await this.registerClient(userId, options, { googleSubject: identity.subject });
  }

  async passwordClient(options, register = false, origin = "") {
    if (!await this.accounts.hasAdministrator()) throw httpError("먼저 Server Manager에서 관리자 계정을 만드세요.", 409);
    deviceHash(options.deviceId);
    const user = register
      ? await this.accounts.createAccount(options)
      : await this.accounts.authenticate(options.username, options.password, origin);
    return await this.registerClient(user.id, options, { passwordHash: user.password_hash });
  }

  async registerClient(userId, { deviceId, deviceName }, proof = {}) {
    const hashedDevice = deviceHash(deviceId);
    return await this.database.transaction(async client => {
      await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [`codmes-device-${userId}-${hashedDevice}`]);
      const user = (await client.query("SELECT * FROM codmes_users WHERE id=$1 AND status='active' FOR UPDATE", [userId])).rows[0];
      if (!user) throw httpError("This account is disabled.",403);
      if (proof.passwordHash && user.password_hash !== proof.passwordHash) throw httpError("비밀번호가 변경되었습니다. 다시 로그인하세요.",401);
      if (proof.googleSubject && !(await client.query("SELECT user_id FROM codmes_google_identities WHERE subject=$1 AND user_id=$2",[proof.googleSubject,userId])).rowCount) throw httpError("Google 연결이 변경되었습니다. 다시 로그인하세요.",401);
      const account = await this.accounts.accountInfo(userId,client);
      let registration = (await client.query(
        `SELECT * FROM codmes_client_registrations
         WHERE user_id = $1 AND device_id_hash = $2 FOR UPDATE`,
        [userId, hashedDevice]
      )).rows[0];
      if (registration?.status === "approved") {
        await client.query(
          `UPDATE codmes_client_registrations
           SET request_token_hash = NULL, request_token_expires_at = NULL WHERE id = $1`,
          [registration.id]
        );
        const session = await this.accounts.issueSession(user.id, {
          deviceName: deviceLabel(deviceName), authContext: "client", registrationId: registration.id
        }, client);
        return { status: "approved", ...session, user: { ...session.user, ...account, role: 'user' } };
      }
      if (!registration) {
        const mode = (await client.query("SELECT client_approval_mode FROM codmes_auth_settings WHERE id = 1")).rows[0]?.client_approval_mode;
        const autoApproved = mode === "allow";
        registration = (await client.query(
          `INSERT INTO codmes_client_registrations
             (id, user_id, device_id_hash, device_name, status, approved_at)
           VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
          [randomUUID(), userId, hashedDevice, deviceLabel(deviceName),
            autoApproved ? "approved" : "pending", autoApproved ? new Date() : null]
        )).rows[0];
        if (autoApproved) {
          const session = await this.accounts.issueSession(user.id, {
            deviceName: deviceLabel(deviceName), authContext: "client", registrationId: registration.id
          }, client);
          return { status: "approved", ...session, user: { ...session.user, ...account, role: 'user' } };
        }
      }
      if (registration.status === "rejected") return { status: "rejected", requestId: registration.id };
      const secret = requestToken();
      await client.query(
        `UPDATE codmes_client_registrations
         SET request_token_hash = $2, request_token_expires_at = now() + interval '10 minutes',
             device_name = $3, updated_at = now() WHERE id = $1`,
        [registration.id, hashSessionToken(secret), deviceLabel(deviceName)]
      );
      return { status: "pending", requestId: registration.id, requestToken: secret,
        user: { ...account, role: "user" } };
    });
  }

  async clientStatus({ requestId, requestToken: secret }) {
    const id = assertUuid(requestId);
    if (!/^[A-Za-z0-9_-]{43}$/.test(String(secret || ""))) throw httpError("Registration request is invalid.", 401);
    return await this.database.transaction(async (client) => {
      const registration = (await client.query(
        `SELECT r.*, u.username_normalized, u.display_name, u.credentials_configured, g.email FROM codmes_client_registrations r
         JOIN codmes_users u ON u.id = r.user_id
         LEFT JOIN codmes_google_identities g ON g.user_id = r.user_id
         WHERE r.id = $1 AND r.request_token_hash = $2
           AND r.request_token_expires_at > now() AND u.status = 'active' FOR UPDATE OF r`,
        [id, hashSessionToken(secret)]
      )).rows[0];
      if (!registration) throw httpError("Registration request is invalid or expired.", 401);
      if (registration.status === "rejected") return { status: "rejected", requestId: id };
      if (registration.status === "pending") return { status: "pending", requestId: id,
        user: await this.accounts.accountInfo(registration.user_id,client) };
      await client.query(
        `UPDATE codmes_client_registrations
         SET request_token_hash = NULL, request_token_expires_at = NULL, updated_at = now()
         WHERE id = $1`,
        [id]
      );
      const session = await this.accounts.issueSession(registration.user_id, {
        deviceName: registration.device_name, authContext: "client", registrationId: id
      }, client);
      return { status: "approved", ...session, user: { ...await this.accounts.accountInfo(registration.user_id,client), role: "user" } };
    });
  }

  async clientProfile(userId, queryable = this.database) {
    const result = await queryable.query(
      `SELECT u.id AS user_id, u.username_normalized, u.credentials_configured, u.display_name, g.email, w.id AS profile_id, w.name
         FROM codmes_users u
         LEFT JOIN codmes_google_identities g ON g.user_id = u.id
         LEFT JOIN codmes_account_profiles p ON p.user_id = u.id
         LEFT JOIN codmes_workspaces w ON w.id = p.workspace_id AND w.deleted_at IS NULL
        WHERE u.id = $1 AND u.status='active'`, [userId]
    );
    const row = result.rows[0];
    if (!row) throw httpError("Sign in to Codmes first.", 401);
    return {
      user: { ...await this.accounts.accountInfo(userId,queryable), role: "user" },
      setupRequired: !row.profile_id,
      // Google client sessions authenticate the owner. Legacy server PINs are
      // preserved for manager access, but are not client identity credentials.
      profile: row.profile_id ? { id: row.profile_id, name: row.name, locked: false } : null
    };
  }

  async ensureClientProfile(user, workspaces) {
    await this.database.transaction(async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [`codmes-profile-${user.id}`]);
      const current = await this.clientProfile(user.id, client);
      if (!current.setupRequired) return;
      let profile = current.profile;
      if (!profile) {
        profile = await workspaces.createWorkspace(user, {
          name: current.user.displayName || "내 프로필"
        }, client);
        await client.query(
          `INSERT INTO codmes_account_profiles(user_id, workspace_id) VALUES ($1, $2)
           ON CONFLICT (user_id) DO UPDATE SET workspace_id = EXCLUDED.workspace_id`,
          [user.id, profile.id]
        );
      }
    });
    return await this.clientProfile(user.id);
  }

  async listRegistrations() {
    const [mode, result] = await Promise.all([
      this.approvalMode(),
      this.database.query(
        `SELECT r.*, u.username_normalized, u.display_name, g.email FROM codmes_client_registrations r
         JOIN codmes_users u ON u.id = r.user_id
         LEFT JOIN codmes_google_identities g ON g.user_id = r.user_id
         ORDER BY r.created_at DESC, r.id`
      )
    ]);
    return { mode, registrations: result.rows.map(publicRegistration) };
  }

  async setApprovalMode(mode) {
    if (!["ask", "allow"].includes(mode)) throw httpError("Approval mode must be ask or allow.", 400);
    await this.database.query(
      "UPDATE codmes_auth_settings SET client_approval_mode = $1, updated_at = now() WHERE id = 1",
      [mode]
    );
    return { mode };
  }

  async respondToRegistration(id, action) {
    const registrationId = assertUuid(id);
    if (!["approve", "reject", "remove"].includes(action)) throw httpError("Invalid registration action.", 400);
    return await this.database.transaction(async (client) => {
      const registration = (await client.query(
        `SELECT r.* FROM codmes_client_registrations r
         WHERE r.id = $1 FOR UPDATE`,
        [registrationId]
      )).rows[0];
      if (!registration) throw httpError("Registration not found.", 404);
      if (action === "remove") {
        await client.query("DELETE FROM codmes_auth_sessions WHERE registration_id = $1", [registrationId]);
        await client.query("DELETE FROM codmes_client_registrations WHERE id = $1", [registrationId]);
        return { removed: true };
      }
      if (action === "reject") {
        await client.query("DELETE FROM codmes_auth_sessions WHERE registration_id = $1", [registrationId]);
        await client.query(
          "UPDATE codmes_client_registrations SET status = 'rejected', updated_at = now() WHERE id = $1",
          [registrationId]
        );
        return { status: "rejected" };
      }
      await client.query(
        `UPDATE codmes_client_registrations
         SET status = 'approved', approved_at = now(), updated_at = now() WHERE id = $1`,
        [registrationId]
      );
      return { status: "approved" };
    });
  }
}
