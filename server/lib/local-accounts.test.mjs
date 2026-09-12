import test from "node:test";
import assert from "node:assert/strict";
import {
  hashLocalPassword,
  hashSessionToken,
  normalizeLocalUsername,
  verifyLocalPassword
} from "./local-accounts.mjs";
import { roleAllows } from "./workspace-tenancy.mjs";

test("local account usernames normalize Unicode and reject paths", () => {
  assert.equal(normalizeLocalUsername("  Family.Admin  "), "family.admin");
  assert.equal(normalizeLocalUsername("엄마_01"), "엄마_01");
  assert.throws(() => normalizeLocalUsername("../other"), /Username/);
  assert.throws(() => normalizeLocalUsername("ab"), /Username/);
});

test("local account passwords use salted scrypt hashes", async () => {
  const first = await hashLocalPassword("correct horse battery staple");
  const second = await hashLocalPassword("correct horse battery staple");
  assert.notEqual(first, second);
  assert.equal(await verifyLocalPassword("correct horse battery staple", first), true);
  assert.equal(await verifyLocalPassword("incorrect password", first), false);
});

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
