import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createCodmesDatabase } from "./database.mjs";
import { startManagedPostgres, stopManagedPostgres } from "./managed-postgres.mjs";
import { LocalAccountStore } from "./local-accounts.mjs";
import { GoogleAuthStore } from "./google-auth.mjs";
import { WorkspaceTenancyStore } from "./workspace-tenancy.mjs";
import { ProfileAuthStore } from "./profile-auth.mjs";

function identity(subject) {
  return { subject, email: `${subject}@example.com`, displayName: subject };
}

const testPassword = "test correct horse battery staple";
function credentials(subject) { return { username: subject, password: testPassword }; }

function deviceId() {
  return crypto.randomBytes(32).toString("base64url");
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

test("Google client registration requires approval, preserves linked users, and revokes sessions", {
  skip: process.env.CODMES_TEST_MANAGED_POSTGRES !== "true"
}, async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-google-auth-"));
  let postgres;
  let database;
  let apiProcess;
  try {
    postgres = await startManagedPostgres({ dataRoot: root, port: await freePort() });
    database = createCodmesDatabase({ connectionString: postgres.connectionString });
    await database.migrate();
    const accounts = new LocalAccountStore(database);
    const google = new GoogleAuthStore(database, accounts);
    const workspaces = new WorkspaceTenancyStore(database, root, { legacyWorkspaceRoot: path.join(root, "legacy") });
    const profiles = new ProfileAuthStore(database, accounts, workspaces);

    const admin = await google.bootstrapAdmin(identity("admin-sub"), { ...credentials("admin-sub"), workspaceName: "Home" }, workspaces, profiles);
    assert.equal(admin.user.role, "admin");
    assert.equal(await google.hasAdminLink(), true);
    assert.equal((await accounts.resolveToken(admin.token)).id, admin.user.id);

    const firstDevice = deviceId();
    const pending = await google.loginClient(identity("client-sub"), { ...credentials("client-sub"), deviceId: firstDevice, deviceName: "Laptop" });
    assert.equal(pending.status, "pending");
    assert.equal(Boolean(pending.token), false);
    assert.equal((await google.clientStatus(pending)).status, "pending");
    assert.equal((await google.listRegistrations()).registrations[0].status, "pending");
    await database.query(
      "UPDATE codmes_client_registrations SET request_token_expires_at = now() - interval '1 second' WHERE id = $1",
      [pending.requestId]
    );
    await assert.rejects(google.clientStatus(pending), { status: 401 });
    const refreshed = await google.loginClient(identity("client-sub"), { ...credentials("client-sub"), deviceId: firstDevice, deviceName: "Laptop" });
    assert.equal(refreshed.status, "pending");
    await google.respondToRegistration(refreshed.requestId, "approve");
    const approved = await google.clientStatus(refreshed);
    assert.equal(approved.status, "approved");
    assert.equal(approved.user.role, "user");
    assert.deepEqual(await workspaces.listForUser(approved.user.id), [], "approval never shares other owners' profiles");
    assert.equal(approved.user.email, identity("client-sub").email);
    const own = await google.ensureClientProfile(approved.user, workspaces);
    assert.equal(own.setupRequired, false);
    assert.equal(own.profile.locked, false, "Google profile registration needs no PIN");
    assert.notEqual(own.profile.id, admin.workspace.id);
    const simultaneous = await Promise.all(Array.from({ length: 4 }, () => google.ensureClientProfile(approved.user, workspaces)));
    assert.ok(simultaneous.every(state => state.profile.id === own.profile.id));
    assert.equal((await workspaces.listForUser(approved.user.id)).length, 1);
    await assert.rejects(google.clientStatus(refreshed), { status: 401 });
    assert.equal((await accounts.resolveToken(approved.token)).id, approved.user.id);

    // Existing broad membership must not bypass the new ownership binding.
    await database.query("INSERT INTO codmes_workspace_members(workspace_id, user_id, role) VALUES ($1, $2, 'owner')", [admin.workspace.id, approved.user.id]);
    await assert.rejects(profiles.open(approved.token, admin.workspace.id), { status: 403 });
    await assert.rejects(profiles.archive(approved.user, admin.workspace.id, {}), { status: 403 });
    const profile = await profiles.open(approved.token, own.profile.id);
    assert.equal((await profiles.resolve(profile.token)).workspaceId, own.profile.id);
    const apiPort = await freePort();
    const managerSecret = crypto.randomBytes(32).toString("hex");
    apiProcess = spawn(process.execPath, ["server/index.mjs"], {
      cwd: path.resolve("."), stdio: "ignore",
      env: { ...process.env, CODMES_HOST: "127.0.0.1", CODMES_PORT: String(apiPort),
        CODMES_WORKSPACE_ROOT: path.join(root, "legacy"), CODMES_DATA_ROOT: root,
        CODMES_DATABASE_URL: postgres.connectionString, CODMES_MANAGED_POSTGRES: "false",
        CODMES_MULTIUSER_ENABLED: "true", CODMES_MANAGER_BOOTSTRAP_SECRET: managerSecret,
        CODMES_TLS_CERT: "", CODMES_TLS_KEY: "" }
    });
    const base = `http://127.0.0.1:${apiPort}`;
    const deadline = Date.now() + 10_000;
    let ready = false;
    while (Date.now() < deadline) {
      try { if ((await fetch(`${base}/api/health`)).ok) { ready = true; break; } } catch { }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.ok(ready, "disposable API server starts");
    const request = (route, token, body, headers = {}) => fetch(base + route, {
      method: body === undefined ? "GET" : "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...headers },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    });
    const listed = await request("/api/profiles", approved.token);
    assert.equal((await request("/api/auth/admin/setup", "")).status, 403);
    assert.equal((await request("/api/auth/admin/setup", admin.token)).status, 403, "even an admin token cannot bypass native Manager authorization");
    assert.equal((await request("/api/auth/admin/setup", "", undefined, {"X-Codmes-Manager-Secret":"wrong"})).status, 403);
    const setup = await request("/api/auth/admin/setup", "", undefined, {"X-Codmes-Manager-Secret":managerSecret});
    assert.equal(setup.status, 200);
    assert.deepEqual(await setup.json(), {existingServer:true,maskedAccount:{id:"a***ub",email:"a***ub@example.com"}});
    assert.equal(listed.status, 200);
    assert.deepEqual((await listed.json()).profiles.map(p => p.id), [own.profile.id]);
    assert.equal((await request("/api/client/profile/register", approved.token, {})).status, 200);
    assert.equal((await request("/api/workspace", approved.token)).status, 403, "account token cannot bypass profile scope");
    assert.equal((await request("/api/workspace", profile.token)).status, 200);
    assert.equal((await fetch(base + "/api/sync/manifest")).status, 401, "sync never bypasses authentication");
    assert.equal((await request("/api/sync/manifest", approved.token)).status, 403, "account sessions cannot bypass profile authorization for sync");
    const syncPut = (content, revision = "missing", conflictPolicy) => fetch(base + "/api/sync/blob?path=Notes%2Fsync-book.md&resource=file", {
      method: "PUT", headers: { Authorization: `Bearer ${profile.token}`, "X-Codmes-Base-Revision": revision, "Content-Type": "application/octet-stream", ...(conflictPolicy ? { "X-Codmes-Conflict-Policy": conflictPolicy } : {}) }, body: content
    });
    const syncCreated = await syncPut("phone notes");
    assert.equal(syncCreated.status, 200);
    const syncInitial = await syncCreated.json();
    assert.equal(syncInitial.status, "applied");
    const syncUpdated = await syncPut("tablet edits", syncInitial.entry.revision);
    assert.equal((await syncUpdated.json()).status, "applied");
    assert.equal((await (await syncPut("stale offline edits", syncInitial.entry.revision)).json()).status, "conflict");
    const syncList = await request("/api/sync/manifest", profile.token);
    assert.equal(syncList.status, 200);
    const syncedBook = (await syncList.json()).entries.find((entry) => entry.path === "Notes/sync-book.md");
    assert.ok(syncedBook);
    const downloadedBook = await request(`/api/sync/blob?path=${encodeURIComponent(syncedBook.path)}&resource=file&revision=${syncedBook.revision}`, profile.token);
    assert.equal(downloadedBook.status, 200);
    assert.equal(await downloadedBook.text(), "tablet edits", "authenticated downloads stream the exact manifest revision");
    const mergeBase = await (await syncPut("a\nb\nc\n", syncedBook.revision, "merge-latest")).json();
    await syncPut("phone\nb\nc\n", mergeBase.entry.revision, "merge-latest");
    const mergeResult = await (await syncPut("a\nb\ntablet\n", mergeBase.entry.revision, "merge-latest")).json();
    assert.equal(mergeResult.status, "applied");
    const mergeDownload = await request(`/api/sync/blob?path=Notes%2Fsync-book.md&resource=file&revision=${mergeResult.entry.revision}`, profile.token);
    assert.equal(await mergeDownload.text(), "phone\nb\ntablet\n", "authenticated HTTP transport merges independent lines");
    // New policy through the production router/auth/streaming path, not a fake transport.
    const versionedPath = "Notes/local-time-book.md";
    const versionedChange = (entry, second, device = "test-phone", action = "put") => ({ path: versionedPath, resource: "file", action,
      conflictPolicy: "merge-modified-v2", operationId: crypto.randomUUID(), deviceId: device,
      modifiedAt: new Date(Date.UTC(2026, 0, 1, 0, 0, second)).toISOString(), baseRevision: entry?.revision ?? null, baseVersion: entry?.versionId ?? null });
    const versionedPut = (change, content) => fetch(base + `/api/sync/blob?path=${encodeURIComponent(change.path)}&resource=file`, {
      method: "PUT", headers: { Authorization: `Bearer ${profile.token}`, "X-Codmes-Base-Revision": change.baseRevision ?? "missing", "X-Codmes-Conflict-Policy": change.conflictPolicy,
        "X-Codmes-Operation-ID": change.operationId, "X-Codmes-Device-ID": change.deviceId, "X-Codmes-Modified-At": change.modifiedAt,
        ...(change.baseVersion ? { "X-Codmes-Base-Version": change.baseVersion } : {}) }, body: content });
    const versionedSeed = await (await versionedPut(versionedChange(null, 0), "red cat\n")).json();
    await versionedPut(versionedChange(versionedSeed.entry, 20, "test-Windows"), "red dog\n");
    const versionedFinal = await (await versionedPut(versionedChange(versionedSeed.entry, 10, "test-Android"), "blue cat\n")).json();
    assert.equal(versionedFinal.status, "applied");
    assert.equal(await (await request(`/api/sync/blob?path=${encodeURIComponent(versionedPath)}&revision=${versionedFinal.entry.revision}`, profile.token)).text(), "blue dog\n");
    const historyRoute = `/api/sync/history?path=${encodeURIComponent(versionedPath)}&resource=file`;
    assert.equal((await request(historyRoute, approved.token)).status, 403);
    assert.equal((await fetch(base + historyRoute)).status, 401);
    assert.equal((await request(historyRoute, profile.token, undefined, { "X-Codmes-Workspace-Id": admin.workspace.id })).status, 401);
    const versionedHistory = await (await request(historyRoute, profile.token)).json();
    assert.ok(versionedHistory.entries.length >= 3);
    assert.equal((await fetch(base + `/api/file?path=${encodeURIComponent(versionedPath)}`, { method: "PUT", headers: { Authorization: `Bearer ${profile.token}`, "Content-Type": "application/json" }, body: JSON.stringify({ content: "bypass" }) })).status, 409);
    assert.equal((await request("/api/sync/change", profile.token, versionedChange(versionedFinal.entry, 30, "test-Windows", "delete"))).status, 200);
    const recovery = await (await request("/api/sync/recovery", profile.token)).json();
    assert.ok(recovery.entries.some(e => e.path === versionedPath));
    assert.equal((await request("/api/file", profile.token, { path: versionedPath, content: "resurrect bypass" })).status, 409);
    const oldVersion = versionedHistory.entries.find(e => e.revision === versionedSeed.entry.revision && !e.deleted);
    const recovered = await request(`/api/sync/history/blob?path=${encodeURIComponent(versionedPath)}&resource=file&version=${oldVersion.versionId}`, profile.token);
    assert.equal(recovered.status, 200); assert.equal(await recovered.text(), "red cat\n");
    assert.equal((await request("/api/sync/manifest", profile.token, undefined, { "X-Codmes-Workspace-Id": admin.workspace.id })).status, 401);
    assert.equal((await request("/api/workspace", profile.token, undefined, { "X-Codmes-Workspace-Id": admin.workspace.id })).status, 401);
    assert.equal((await request(`/api/profiles/${admin.workspace.id}/open`, approved.token, {})).status, 403);
    assert.equal((await request("/api/profiles", approved.token, { name: "Extra", pin: "1234" })).status, 403);
    assert.equal((await request("/api/admin/profiles", approved.token, undefined, { "X-Codmes-Manager-Secret": managerSecret })).status, 403);
    assert.equal((await request("/api/admin/profiles", admin.token)).status, 403);
    assert.equal((await request("/api/admin/profiles", admin.token, undefined, { "X-Codmes-Manager-Secret": managerSecret })).status, 200);
    assert.equal((await request("/api/auth/admin/login", "", { username:"admin-sub",password:testPassword })).status,403);
    const passwordLogin = await request("/api/auth/admin/login", "", { username:"admin-sub",password:testPassword }, { "X-Codmes-Manager-Secret":managerSecret });
    assert.equal(passwordLogin.status,200);
    assert.equal((await passwordLogin.json()).user.id,admin.user.id);
    assert.equal((await request("/api/auth/account",profile.token)).status,401,"profile tokens cannot change account credentials");
    assert.equal((await request("/api/auth/account/google/unlink",approved.token,{currentPassword:"wrong"})).status,401);
    const webClient = await request("/api/auth/client/register","",{username:"http-client",password:testPassword,deviceId:deviceId()});
    assert.equal(webClient.status,200);
    assert.equal((await webClient.json()).status,"pending");
    assert.equal((await request("/api/auth/client/login","",{username:"missing-user",password:"wrong",deviceId:deviceId()})).status,401);
    await google.respondToRegistration(pending.requestId, "remove");
    assert.equal(await accounts.resolveToken(approved.token), null);
    assert.equal(await profiles.resolve(profile.token), null);

    const pendingAgain = await google.loginClient(identity("client-sub"), { ...credentials("client-sub"), deviceId: firstDevice, deviceName: "Laptop" });
    assert.equal(pendingAgain.status, "pending");
    await google.respondToRegistration(pendingAgain.requestId, "approve");
    await google.setApprovalMode("allow");
    const second = await google.loginClient(identity("client-sub"), { ...credentials("client-sub"), deviceId: deviceId(), deviceName: "Phone" });
    assert.equal(second.status, "approved");
    assert.equal((await google.ensureClientProfile(second.user, workspaces)).profile.id, own.profile.id, "same Google account shares one profile across devices");
    const secondProfile = await profiles.open(second.token, own.profile.id);
    const secondSync = await request("/api/sync/manifest", secondProfile.token);
    const secondCatalog = await secondSync.json();
    assert.ok(secondCatalog.entries.some((entry) => entry.path === "Notes/sync-book.md"), "second approved device sees the same account's server copy");
    const syncedId = secondCatalog.entries.find(entry => entry.path === "Notes/sync-book.md").fileId;
    const forgedDevice = "forged-device-identity-0000";
    const modeResponse = await request("/api/sync/devices", secondProfile.token, { deviceId: forgedDevice, policies: [{ fileId: syncedId, mode: "server", locallyAvailable: false }] });
    assert.equal(modeResponse.status, 200);
    const reportedDevice = (await modeResponse.json()).deviceId; assert.notEqual(reportedDevice, forgedDevice);
    const deviceCatalog = await (await request("/api/sync/devices", secondProfile.token)).json();
    assert.equal(deviceCatalog.devices[reportedDevice].policies[syncedId].mode, "server"); assert.equal(deviceCatalog.devices[forgedDevice], undefined);
    const stranger = await google.loginClient(identity("stranger-sub"), { ...credentials("stranger-sub"), deviceId: deviceId(), deviceName: "Unknown" });
    assert.equal(stranger.status, "approved", "allow automatically approves new Google identities too");
    const strangerState = await google.ensureClientProfile(stranger.user, workspaces);
    assert.notEqual(strangerState.profile.id, own.profile.id);
    await assert.rejects(profiles.open(stranger.token, own.profile.id), { status: 403 });
    await assert.rejects(profiles.changePin(stranger.user, strangerState.profile.id, { pin: "1234" }), { status: 403 });
    // Old profile PINs do not make Google-authenticated clients set/enter PINs.
    await profiles.adminSetPin(admin.user, strangerState.profile.id, "4567");
    assert.equal((await google.clientProfile(stranger.user.id)).profile.locked, false);
    const strangerOpened = await profiles.open(stranger.token, strangerState.profile.id);
    assert.ok(await profiles.resolve(strangerOpened.token));
    await profiles.archive(stranger.user, strangerState.profile.id, {});
    assert.equal(await profiles.resolve(strangerOpened.token), null);
    assert.ok((await profiles.listAllForAdmin(admin.user)).find(p => p.id === strangerState.profile.id && p.deleted));
    const replacement = await google.ensureClientProfile(stranger.user, workspaces);
    assert.notEqual(replacement.profile.id, strangerState.profile.id);
    assert.equal((await database.query("SELECT count(*)::int AS count FROM codmes_account_profiles WHERE user_id = $1", [stranger.user.id])).rows[0].count, 1);
    await google.setApprovalMode("ask");
    const denied = await google.loginClient(identity("denied-sub"), { ...credentials("denied-sub"), deviceId: deviceId(), deviceName: "Denied" });
    assert.equal(denied.status, "pending");
    await google.respondToRegistration(denied.requestId, "reject");
    assert.equal((await google.clientStatus(denied)).status, "rejected");

    const pendingAdminClient = await google.loginClient(identity("admin-sub"), { ...credentials("admin-sub"),
      deviceId: deviceId(), deviceName: "Admin's Codmes"
    });
    assert.equal(pendingAdminClient.status, "pending");
    await google.respondToRegistration(pendingAdminClient.requestId, "approve");
    const adminClient = await google.clientStatus(pendingAdminClient);
    assert.equal(adminClient.user.role, "user", "client sessions never expose administrator privileges");
    assert.equal((await google.loginAdmin(identity("admin-sub"))).user.role, "admin");

    await assert.rejects(google.linkGoogle(await accounts.resolveSession(admin.token), identity("client-sub"), testPassword), { status: 409 });
    assert.ok(await accounts.resolveToken(admin.token), "failed account change retains the administrator session");
    assert.ok(await accounts.resolveToken(adminClient.token), "failed account change rolls back client session revocation too");
    assert.equal((await google.loginAdmin(identity("admin-sub"))).user.id, admin.user.id);
    await google.linkGoogle(await accounts.resolveSession(admin.token), identity("new-admin-sub"), testPassword);
    assert.ok(await accounts.resolveToken(admin.token), "changing login method retains the current account session");
    assert.equal(await accounts.resolveToken(adminClient.token), null);
    await assert.rejects(google.loginAdmin(identity("admin-sub")), { status: 403 });
    assert.equal((await google.loginAdmin(identity("new-admin-sub"))).user.id, admin.user.id);
    assert.equal((await workspaces.listForUser(admin.user.id))[0].id, admin.workspace.id, "account change preserves existing profiles and workspace ownership");
    // Removing Google is not removing the Codmes account or device approval.
    const administratorSession = await accounts.resolveSession(admin.token);
    await google.unlinkGoogle(administratorSession, testPassword);
    assert.equal(await google.hasAdminLink(), false);
    assert.equal((await accounts.authenticate("admin-sub", testPassword)).id, admin.user.id);
    const sameDevice = (await database.query("SELECT device_id_hash FROM codmes_client_registrations WHERE user_id=$1", [admin.user.id])).rows[0];
    assert.ok(sameDevice, "Google changes preserve approved registrations");
    assert.equal((await google.clientProfile(admin.user.id)).profile.id, admin.workspace.id);
    await assert.rejects(google.loginAdmin(identity("new-admin-sub")), { status: 403 });
    const local = await google.passwordClient({ username: "local-client", password: testPassword, deviceId: deviceId() }, true);
    assert.equal(local.status, "pending", "password registrations also require approval without any Google administrator");
    await google.respondToRegistration(local.requestId, "approve");
    const localApproved = await google.clientStatus(local);
    const localProfile = await google.ensureClientProfile(localApproved.user, workspaces);
    const localSession = await accounts.resolveSession(localApproved.token);
    await assert.rejects(google.linkGoogle(localSession, identity("local-google"), "incorrect"), { status: 401 });
    await google.linkGoogle(localSession, identity("local-google"), testPassword);
    assert.equal((await google.clientProfile(localApproved.user.id)).profile.id, localProfile.profile.id);
    await google.unlinkGoogle(localSession, testPassword);
    assert.equal((await google.clientProfile(localApproved.user.id)).profile.id, localProfile.profile.id);
    const newPassword = "different correct horse battery staple";
    const staleProof = await accounts.authenticate("local-client",testPassword);
    await accounts.changePassword(localSession, { currentPassword: testPassword, password: newPassword });
    await assert.rejects(accounts.authenticate("local-client", testPassword), { status: 401 });
    assert.equal((await accounts.authenticate("local-client", newPassword)).id, localApproved.user.id);
    await assert.rejects(accounts.issuePasswordSession(staleProof,{authContext:"client"}),{status:401});
    await assert.rejects(google.registerClient(localApproved.user.id,{deviceId:deviceId()},{passwordHash:staleProof.password_hash}),{status:401});
    await assert.rejects(google.registerClient(localApproved.user.id,{deviceId:deviceId()},{googleSubject:"local-google"}),{status:401});
    // Fresh Google signup prompts before creating an account; email never auto-merges.
    const beforeUsers = (await database.query("SELECT count(*)::int AS count FROM codmes_users")).rows[0].count;
    const signup = await google.loginClient(identity("fresh-google"), { deviceId: deviceId() });
    assert.equal(signup.status, "account_setup_required");
    assert.equal((await database.query("SELECT count(*)::int AS count FROM codmes_users")).rows[0].count, beforeUsers);
    await assert.rejects(google.loginClient(identity("fresh-google"), { username: "local-client", password: testPassword, deviceId: deviceId() }), { status: 409 });
    // A previously Google-only account sets credentials in place without data loss.
    await database.query("UPDATE codmes_users SET credentials_configured=false,password_hash='google-sign-in-only' WHERE id=$1", [localApproved.user.id]);
    await google.insertIdentity(database, localApproved.user.id, identity("old-google"));
    const migrated = await google.loginClient(identity("old-google"), { username: "migrated-client", password: testPassword, deviceId: deviceId() });
    assert.equal(migrated.user.id, localApproved.user.id);
    assert.equal((await google.clientProfile(migrated.user.id)).profile.id, localProfile.profile.id);
    assert.equal((await accounts.authenticate("migrated-client", testPassword)).id, localApproved.user.id);
    const stored = (await database.query("SELECT password_hash FROM codmes_users WHERE id=$1", [localApproved.user.id])).rows[0].password_hash;
    assert.ok(stored.startsWith("scrypt-v1$"));
    assert.notEqual(stored,testPassword);

  } finally {
    if (apiProcess && apiProcess.exitCode === null && apiProcess.signalCode === null) {
      apiProcess.kill("SIGTERM");
      await once(apiProcess, "exit");
    }
    await database?.close().catch(() => {});
    await stopManagedPostgres(postgres).catch(() => {});
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("Migration 008 preserves existing Google-only account, profile, device and session UUIDs", {
  skip: process.env.CODMES_TEST_MANAGED_POSTGRES !== "true"
}, async () => {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),"codmes-account-migration-"));
  let postgres,database;
  try {
    postgres=await startManagedPostgres({dataRoot:root,port:await freePort()});
    const migrationDir=path.join(root,"migrations");await fs.mkdir(migrationDir);
    const original=path.resolve("server/db/migrations");
    for(const file of (await fs.readdir(original)).filter(name=>/^00[1-7].*\.sql$/.test(name))) await fs.copyFile(path.join(original,file),path.join(migrationDir,file));
    database=createCodmesDatabase({connectionString:postgres.connectionString,migrationsDirectory:migrationDir});await database.migrate();
    const userId=crypto.randomUUID(),workspaceId=crypto.randomUUID(),registrationId=crypto.randomUUID(),sessionId=crypto.randomUUID();
    const token=crypto.randomBytes(32).toString("base64url");
    await database.query("INSERT INTO codmes_users(id,username_normalized,display_name,password_hash,role) VALUES ($1,'google-existing','Existing','google-sign-in-only','user')",[userId]);
    await database.query("INSERT INTO codmes_google_identities(subject,user_id,email,display_name) VALUES ('old-sub',$1,'old@example.com','Existing')",[userId]);
    await database.query("INSERT INTO codmes_workspaces(id,owner_user_id,name,storage_key) VALUES ($1,$2,'Old profile','existing-storage')",[workspaceId,userId]);
    await database.query("INSERT INTO codmes_google_profiles(user_id,workspace_id) VALUES ($1,$2)",[userId,workspaceId]);
    await database.query("INSERT INTO codmes_client_registrations(id,google_subject,device_id_hash,device_name,status) VALUES ($1,'old-sub','existing-device','Laptop','approved')",[registrationId]);
    await database.query("INSERT INTO codmes_auth_sessions(id,user_id,token_hash,auth_context,registration_id,expires_at) VALUES ($1,$2,$3,'client',$4,now()+interval '1 day')",[sessionId,userId,crypto.createHash('sha256').update(token).digest('hex'),registrationId]);
    database.migrationsDirectory=original;assert.deepEqual((await database.migrate()).applied,['008_codmes_accounts.sql']);
    const accounts=new LocalAccountStore(database),google=new GoogleAuthStore(database,accounts);
    assert.equal((await accounts.resolveToken(token)).id,userId);
    assert.equal((await google.clientProfile(userId)).profile.id,workspaceId);
    assert.equal((await database.query("SELECT user_id FROM codmes_client_registrations WHERE id=$1",[registrationId])).rows[0].user_id,userId);
    await accounts.configureCredentials(userId,{username:'existing-codmes',password:testPassword});
    await google.unlinkGoogle(await accounts.resolveSession(token),testPassword);
    assert.equal((await accounts.authenticate('existing-codmes',testPassword)).id,userId);
    assert.equal((await google.clientProfile(userId)).profile.id,workspaceId);
    assert.equal((await accounts.resolveToken(token)).id,userId);
  } finally {
    await database?.close().catch(()=>{});await stopManagedPostgres(postgres).catch(()=>{});await fs.rm(root,{recursive:true,force:true});
  }
});

test("Self-hosted servers have independent administrators, registrations, profiles, and sessions", {
  skip: process.env.CODMES_TEST_MANAGED_POSTGRES !== "true"
}, async () => {
  const fixtures = [];
  async function server() {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-google-isolation-"));
    const fixture = { root };
    fixtures.push(fixture);
    fixture.postgres = await startManagedPostgres({ dataRoot: root, port: await freePort() });
    fixture.database = createCodmesDatabase({ connectionString: fixture.postgres.connectionString });
    await fixture.database.migrate();
    fixture.accounts = new LocalAccountStore(fixture.database);
    fixture.google = new GoogleAuthStore(fixture.database, fixture.accounts);
    fixture.workspaces = new WorkspaceTenancyStore(fixture.database, root);
    fixture.profiles = new ProfileAuthStore(fixture.database, fixture.accounts, fixture.workspaces);
    return fixture;
  }
  try {
    const a = await server();
    const b = await server();
    await assert.rejects(a.google.bootstrapAdmin(identity("failed-admin"), { ...credentials("failed-admin"), password: "short" }, a.workspaces, a.profiles), { status: 400 });
    assert.equal(await a.google.hasAdminLink(), false, "failed setup rolls back the administrator");
    assert.equal((await a.database.query("SELECT count(*)::int AS count FROM codmes_workspaces")).rows[0].count, 0);
    const adminA = await a.google.bootstrapAdmin(identity("admin-a"), { ...credentials("admin-a"), workspaceName: "A", profilePin: "1234" }, a.workspaces, a.profiles);
    const adminB = await b.google.bootstrapAdmin(identity("admin-b"), { ...credentials("admin-b"), workspaceName: "B", profilePin: "5678" }, b.workspaces, b.profiles);
    await assert.rejects(a.google.loginAdmin(identity("admin-b")), { status: 403 });
    await assert.rejects(b.google.loginAdmin(identity("admin-a")), { status: 403 });
    assert.equal(await b.accounts.resolveToken(adminA.token), null);
    assert.equal(await a.accounts.resolveToken(adminB.token), null);
    await assert.rejects(a.google.bootstrapAdmin(identity("another-admin"), { ...credentials("another-admin"),}, a.workspaces, a.profiles), { status: 409 });

    // The same Google identity and device can join both servers independently.
    const device = deviceId();
    await b.google.setApprovalMode("allow");
    const pendingA = await a.google.loginClient(identity("shared-client"), { ...credentials("shared-client"), deviceId: device });
    const approvedB = await b.google.loginClient(identity("shared-client"), { ...credentials("shared-client"), deviceId: device });
    assert.equal(pendingA.status, "pending");
    assert.equal(approvedB.status, "approved");
    assert.equal(await a.google.approvalMode(), "ask");
    await assert.rejects(b.google.clientStatus(pendingA), { status: 401 });
    await assert.rejects(b.google.respondToRegistration(pendingA.requestId, "approve"), { status: 404 });
    await a.google.respondToRegistration(pendingA.requestId, "approve");
    const approvedA = await a.google.clientStatus(pendingA);
    assert.notEqual(approvedA.user.id, approvedB.user.id);
    assert.equal(await b.accounts.resolveToken(approvedA.token), null);
    assert.equal(await a.accounts.resolveToken(approvedB.token), null);
    const stateA = await a.google.ensureClientProfile(approvedA.user, a.workspaces);
    const stateB = await b.google.ensureClientProfile(approvedB.user, b.workspaces);
    assert.deepEqual((await a.workspaces.listForUser(approvedA.user.id)).map(w => w.id), [stateA.profile.id]);
    assert.deepEqual((await b.workspaces.listForUser(approvedB.user.id)).map(w => w.id), [stateB.profile.id]);
    await assert.rejects(a.workspaces.resolveForUser(approvedA.user.id, adminB.workspace.id), { status: 404 });
    const profileA = await a.profiles.open(approvedA.token, stateA.profile.id);
    const profileB = await b.profiles.open(approvedB.token, stateB.profile.id);
    assert.equal(await b.profiles.resolve(profileA.token), null);
    await a.google.respondToRegistration(pendingA.requestId, "remove");
    assert.equal(await a.accounts.resolveToken(approvedA.token), null);
    assert.equal(await a.profiles.resolve(profileA.token), null);
    assert.ok(await b.accounts.resolveToken(approvedB.token));
    assert.ok(await b.profiles.resolve(profileB.token));
    await a.google.linkGoogle(await a.accounts.resolveSession(adminA.token), identity("new-admin-a"), testPassword);
    assert.equal((await b.google.loginAdmin(identity("admin-b"))).user.id, adminB.user.id);
    assert.ok(await b.accounts.resolveToken(adminB.token));
  } finally {
    for (const fixture of fixtures) {
      await fixture.database?.close().catch(() => {});
      await stopManagedPostgres(fixture.postgres).catch(() => {});
      await fs.rm(fixture.root, { recursive: true, force: true });
    }
  }
});
