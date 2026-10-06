import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { GoogleIdTokenVerifier, googleOAuthClientIds } from "./google-id-token.mjs";

const clientId = "codmes-test.apps.googleusercontent.com";
const now = Date.parse("2026-09-27T00:00:00Z");
const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "test-key", alg: "RS256", use: "sig" };

function token(overrides = {}, signingKey = privateKey) {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "test-key", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({
    iss: "https://accounts.google.com",
    aud: clientId,
    sub: "stable-google-subject",
    iat: Math.floor(now / 1000) - 60,
    exp: Math.floor(now / 1000) + 3600,
    email: "user@example.com",
    email_verified: true,
    name: "Test User",
    ...overrides
  })).toString("base64url");
  const signature = crypto.sign("RSA-SHA256", Buffer.from(`${header}.${payload}`), signingKey).toString("base64url");
  return `${header}.${payload}.${signature}`;
}

function verifier() {
  return new GoogleIdTokenVerifier({
    audiences: [clientId],
    now: () => now,
    fetchImpl: async () => ({
      ok: true,
      headers: { get: () => "public, max-age=300" },
      json: async () => ({ keys: [jwk] })
    })
  });
}

test("Google ID token verifier checks Google signature, audience, issuer, expiry and stable subject", async () => {
  const subject = await verifier().verify(token());
  assert.deepEqual(subject, {
    subject: "stable-google-subject",
    email: "user@example.com",
    displayName: "Test User"
  });
  await assert.rejects(verifier().verify(token({ aud: "other.apps.googleusercontent.com" })), { status: 401 });
  await assert.rejects(verifier().verify(token({ iss: "https://attacker.example" })), { status: 401 });
  await assert.rejects(verifier().verify(token({ exp: Math.floor(now / 1000) - 1 })), { status: 401 });
  await assert.rejects(verifier().verify(token({ sub: "" })), { status: 401 });
  const wrongKey = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
  await assert.rejects(verifier().verify(token({}, wrongKey)), { status: 401 });
});

test("unverified Google email is never accepted as an account identifier", async () => {
  const subject = await verifier().verify(token({ email_verified: false }));
  assert.equal(subject.subject, "stable-google-subject");
  assert.equal(subject.email, "");
});

test("Google OAuth client IDs are selected from configured platform IDs", () => {
  const config = googleOAuthClientIds({
    CODMES_GOOGLE_DESKTOP_CLIENT_ID: clientId,
    CODMES_GOOGLE_MACOS_CLIENT_ID: "macos.apps.googleusercontent.com",
    CODMES_GOOGLE_IOS_CLIENT_ID: "ios.apps.googleusercontent.com",
    CODMES_GOOGLE_OAUTH_CLIENT_IDS: "extra.apps.googleusercontent.com"
  });
  assert.equal(config.clientIds.desktop, clientId);
  assert.equal(config.clientIds.macos, "macos.apps.googleusercontent.com");
  assert.equal(config.audiences.length, 4);
});
