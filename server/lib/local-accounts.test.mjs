import test from "node:test";
import assert from "node:assert/strict";
import { hashSessionToken, LocalAccountStore, maskAccountIdentifier } from "./local-accounts.mjs";
import { roleAllows } from "./workspace-tenancy.mjs";

test("session tokens are stored as one-way hashes", () => {
  const hashed = hashSessionToken("secret-session-token");
  assert.equal(hashed.length, 64);
  assert.equal(hashed.includes("secret-session-token"), false);
});

test("workspace roles only grant their declared level", () => {
  assert.equal(roleAllows("owner", "editor"), true);
  assert.equal(roleAllows("editor", "viewer"), true);
  assert.equal(roleAllows("viewer", "editor"), false);
});

test("setup identifiers stay masked, including short IDs and Unicode", () => {
  assert.equal(maskAccountIdentifier("jeongu0569"), "j***69");
  assert.equal(maskAccountIdentifier("jeongu0569@gmail.com", true), "j***69@gmail.com");
  assert.equal(maskAccountIdentifier("abc"), "a***");
  assert.equal(maskAccountIdentifier("a@example.com", true), "a***@example.com");
  assert.equal(maskAccountIdentifier(""), "");
  assert.equal(maskAccountIdentifier("😀hello"), "😀***lo");
});

test("manager setup returns only masked administrator hints, not account records", async () => {
  const database = { query: async sql => ({ rows: sql.includes("SELECT EXISTS")
    ? [{ exists: true }] : [{ username_normalized: "administrator", email: "admin@example.com", password_hash: "never disclose" }] }) };
  assert.deepEqual(await new LocalAccountStore(database).managerSetupSummary(), {
    existingServer: true, maskedAccount: { id: "a***or", email: "a***in@example.com" },
  });
});

test("an empty server provides no account hint and allows the initial signup flow", async () => {
  const store = new LocalAccountStore({query:async sql=>({rows:sql.includes("EXISTS")?[{exists:false}]:[]})});
  assert.deepEqual(await store.managerSetupSummary(), {existingServer:false,maskedAccount:null});
});
