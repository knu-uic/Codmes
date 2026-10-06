import crypto from "node:crypto";

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const MAX_TOKEN_LENGTH = 16_384;
const MAX_JWKS_AGE_MS = 6 * 60 * 60 * 1000;

function unauthorized() {
  return Object.assign(new Error("Google sign-in could not be verified."), { status: 401 });
}

export function googleOAuthClientIds(env = process.env) {
  const clientIds = {
    desktop: String(env.CODMES_GOOGLE_DESKTOP_CLIENT_ID || "").trim(),
    macos: String(env.CODMES_GOOGLE_MACOS_CLIENT_ID || "").trim(),
    ios: String(env.CODMES_GOOGLE_IOS_CLIENT_ID || "").trim(),
    android: String(env.CODMES_GOOGLE_ANDROID_CLIENT_ID || "").trim(),
    web: String(env.CODMES_GOOGLE_WEB_CLIENT_ID || "").trim()
  };
  const extras = String(env.CODMES_GOOGLE_OAUTH_CLIENT_IDS || "")
    .split(",").map((value) => value.trim()).filter(Boolean);
  const audiences = [...new Set([...Object.values(clientIds), ...extras].filter(Boolean))];
  return { clientIds, audiences };
}

function decodeSegment(segment) {
  if (!/^[A-Za-z0-9_-]+$/.test(segment)) throw unauthorized();
  try {
    return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
  } catch {
    throw unauthorized();
  }
}

function cacheMaxAge(headers) {
  const match = String(headers?.get?.("cache-control") || "").match(/(?:^|,)\s*max-age=(\d+)/i);
  return Math.min(MAX_JWKS_AGE_MS, Math.max(60_000, Number(match?.[1] || 300) * 1000));
}

export class GoogleIdTokenVerifier {
  constructor({ fetchImpl = fetch, now = () => Date.now(), audiences = googleOAuthClientIds().audiences } = {}) {
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.audiences = new Set(audiences);
    this.keys = [];
    this.keysExpireAt = 0;
  }

  async loadKeys(force = false) {
    if (!force && this.keys.length && this.keysExpireAt > this.now()) return this.keys;
    const response = await this.fetchImpl(GOOGLE_JWKS_URL, { signal: AbortSignal.timeout(10_000) });
    if (!response.ok) throw Object.assign(new Error("Google sign-in verification is temporarily unavailable."), { status: 503 });
    const body = await response.json();
    if (!Array.isArray(body?.keys) || !body.keys.length || body.keys.length > 30) {
      throw Object.assign(new Error("Google sign-in verification is temporarily unavailable."), { status: 503 });
    }
    this.keys = body.keys.filter((key) => key.kty === "RSA" && key.alg === "RS256" && key.use === "sig" && key.kid);
    this.keysExpireAt = this.now() + cacheMaxAge(response.headers);
    return this.keys;
  }

  async verify(idToken) {
    if (!this.audiences.size) {
      throw Object.assign(new Error("Google sign-in is not configured."), { status: 503 });
    }
    const token = String(idToken || "");
    if (!token || token.length > MAX_TOKEN_LENGTH) throw unauthorized();
    const segments = token.split(".");
    if (segments.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(segments[2])) throw unauthorized();
    const header = decodeSegment(segments[0]);
    const claims = decodeSegment(segments[1]);
    if (header.alg !== "RS256" || typeof header.kid !== "string" || !header.kid) throw unauthorized();
    if (!["https://accounts.google.com", "accounts.google.com"].includes(claims.iss)
      || typeof claims.aud !== "string" || !this.audiences.has(claims.aud)
      || (claims.azp !== undefined && !this.audiences.has(claims.azp))
      || typeof claims.sub !== "string" || !/^[\x21-\x7e]{1,255}$/.test(claims.sub)
      || !Number.isInteger(claims.exp) || claims.exp * 1000 <= this.now()
      || !Number.isInteger(claims.iat) || claims.iat * 1000 > this.now() + 300_000) {
      throw unauthorized();
    }
    let keys;
    try {
      keys = await this.loadKeys();
      if (!keys.some((key) => key.kid === header.kid)) keys = await this.loadKeys(true);
    } catch (error) {
      if (error?.status) throw error;
      throw Object.assign(new Error("Google sign-in verification is temporarily unavailable."), { status: 503 });
    }
    const key = keys.find((candidate) => candidate.kid === header.kid);
    if (!key) throw unauthorized();
    try {
      const valid = crypto.verify(
        "RSA-SHA256",
        Buffer.from(`${segments[0]}.${segments[1]}`),
        crypto.createPublicKey({ key, format: "jwk" }),
        Buffer.from(segments[2], "base64url")
      );
      if (!valid) throw unauthorized();
    } catch {
      throw unauthorized();
    }
    return {
      subject: claims.sub,
      email: claims.email_verified === true || claims.email_verified === "true"
        ? String(claims.email || "").slice(0, 320) : "",
      displayName: String(claims.name || claims.email || "Google user").slice(0, 100)
    };
  }
}
