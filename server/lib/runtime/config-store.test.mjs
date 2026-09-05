import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  appendProviderCredentialEntry,
  ensureRuntimeConfig,
  envAliases,
  listProviderCredentialEntries,
  listProviderRegistry,
  listCredentialStatus,
  providerEnvKeys,
  readCredentials,
  readRuntimeConfig,
  getMcpCredential,
  getMcpCredentialStatus,
  normalizeMcpServerConfig,
  removeMcpCredential,
  removeSharedPluginCredential,
  removeProviderCredentialEntry,
  runtimeConfigDir,
  setMcpCredential,
  setSharedPluginCredential,
  selectProviderCredentialEntry,
  setCredentialValue,
  setDefaultModel
} from "./config-store.mjs";

test("shared plugin credential is stored for Surface and MCP and removed together", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-shared-plugin-auth-"));
  await setSharedPluginCredential(root, "knu-user-session", "portal-jwt", {
    username: "20260001"
  });
  assert.equal(await getMcpCredential(root, "knu-user-session"), "portal-jwt");
  const auth = JSON.parse(
    await fs.readFile(path.join(runtimeConfigDir(root), "auth.json"), "utf8")
  );
  assert.equal(auth.plugin_credentials["knu-user-session"].token, "portal-jwt");
  assert.equal(auth.plugin_credentials["knu-user-session"].username, "20260001");
  assert.equal(auth.mcp_credentials["knu-user-session"].token, "portal-jwt");

  await removeSharedPluginCredential(root, "knu-user-session");
  const removed = JSON.parse(
    await fs.readFile(path.join(runtimeConfigDir(root), "auth.json"), "utf8")
  );
  assert.equal(removed.plugin_credentials["knu-user-session"], undefined);
  assert.equal(removed.mcp_credentials["knu-user-session"], undefined);
});

test("remote MCP config preserves legacy stdio, validates HTTPS, and keeps bearer server-only", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-remote-mcp-"));
  await ensureRuntimeConfig(root);
  const legacy = normalizeMcpServerConfig({ name: "legacy", command: "node", args: ["server.mjs"] });
  assert.equal(legacy.transport, "stdio");
  const remote = normalizeMcpServerConfig({ name: "knu-rag", transport: "streamable_http", url: "https://example.test/api/mcp/", credential_id: "knu-rag", surfaces: ["chat"] });
  assert.equal(remote.url.endsWith("/"), true);
  assert.throws(() => normalizeMcpServerConfig({ ...remote, url: "http://example.test/api/mcp/" }), /HTTPS/);
  assert.throws(() => normalizeMcpServerConfig({ ...remote, url: "https://token@example.test/api/mcp/" }), /without credentials/);
  assert.throws(() => normalizeMcpServerConfig({ ...remote, args: ["Bearer secret"] }), /does not accept args/);

  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "provider-secret");
  await setMcpCredential(root, "knu-rag", "remote-bearer-secret");
  assert.equal(await getMcpCredentialStatus(root, "knu-rag"), true);
  assert.equal(await getMcpCredential(root, "knu-rag"), "remote-bearer-secret");
  const authPath = path.join(runtimeConfigDir(root), "auth.json");
  const auth = JSON.parse(await fs.readFile(authPath, "utf8"));
  assert.equal(auth.credential_pool["openai-api"][0].access_token, "provider-secret");
  assert.equal(auth.mcp_credentials["knu-rag"].token, "remote-bearer-secret");
  assert.equal((await fs.stat(runtimeConfigDir(root))).mode & 0o777, 0o700);
  assert.equal((await fs.stat(authPath)).mode & 0o777, 0o600);
  await removeMcpCredential(root, "knu-rag");
  assert.equal(await getMcpCredentialStatus(root, "knu-rag"), false);
});

test("provider registry only exposes usable user-facing providers", () => {
  const ids = listProviderRegistry().map((provider) => provider.id);
  assert.deepEqual(ids, ["openai-codex", "ollama-cloud", "ollama-local"]);
});

test("Hermes-compatible custom endpoint config is executable by Codmes", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-custom-model-"));
  await ensureRuntimeConfig(root);
  await fs.writeFile(path.join(runtimeConfigDir(root), "config.yaml"), `model:
  default: gemma4:e2b-mlx
  provider: custom
  base_url: http://127.0.0.1:11434/v1
  api_mode: chat_completions
custom_providers:
  - name: Ollama Local
    base_url: http://127.0.0.1:11434/v1
    model: gemma4:e2b-mlx
    api_mode: chat_completions
`);

  const config = await readRuntimeConfig(root);
  const credentials = await readCredentials(root);
  assert.equal(config.defaultModel.baseUrl, "http://127.0.0.1:11434/v1");
  assert.equal(config.defaultModel.apiMode, "chat_completions");
  assert.equal(credentials.providers.custom.values.baseUrl, "http://127.0.0.1:11434/v1");

  await setDefaultModel(root, "custom", "another-model");
  const updated = await fs.readFile(path.join(runtimeConfigDir(root), "config.yaml"), "utf8");
  assert.match(updated, /base_url: http:\/\/127\.0\.0\.1:11434\/v1/);
  assert.match(updated, /api_mode: chat_completions/);
  assert.match(updated, /model: gemma4:e2b-mlx/);

  await setDefaultModel(root, "openai-codex", "gpt-5.4");
  const switched = await readRuntimeConfig(root);
  assert.equal(switched.defaultModel.baseUrl, null);
  assert.equal(switched.defaultModel.apiMode, null);
});

test("OAuth providers count token-only credentials as configured", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-oauth-status-"));
  await ensureRuntimeConfig(root);
  await setCredentialValue(root, "openai-codex", "access_token", "token-value");
  const status = await listCredentialStatus(root, {});
  const codex = status.find((item) => item.provider === "openai-codex");
  assert.equal(codex.configured, true);
});

test("provider credential entries are listed, selected, and removed without exposing tokens", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-credential-pool-"));
  await ensureRuntimeConfig(root);
  const authPath = path.join(runtimeConfigDir(root), "auth.json");
  await fs.writeFile(authPath, JSON.stringify({
    version: 1,
    credential_pool: {
      "openai-codex": [
        {
          id: "first",
          label: "First Codex",
          auth_type: "oauth",
          access_token: fakeJwt({ email: "first@example.com", exp: 1893456000 }),
          refresh_token: "refresh-one"
        },
        {
          id: "second",
          label: "Second Codex",
          auth_type: "oauth",
          access_token: fakeJwt({
            "https://api.openai.com/auth": { chatgpt_account_id: "acct_second" },
            exp: 1893456001
          })
        }
      ]
    }
  }, null, 2) + "\n", "utf8");

  const entries = await listProviderCredentialEntries(root, "openai-codex");
  assert.equal(entries.length, 2);
  assert.equal(entries[0].active, true);
  assert.equal(entries[0].email, "first@example.com");
  assert.equal(entries[0].hasRefreshToken, true);
  assert.equal(entries[1].accountId, "acct_second");
  assert.equal(entries[0].access_token, undefined);
  assert.equal(entries[0].refresh_token, undefined);

  const selected = await selectProviderCredentialEntry(root, "openai-codex", "second");
  assert.equal(selected.id, "second");
  const reordered = await listProviderCredentialEntries(root, "openai-codex");
  assert.deepEqual(reordered.map((entry) => entry.id), ["second", "first"]);
  assert.equal(reordered[0].active, true);

  const removed = await removeProviderCredentialEntry(root, "openai-codex", "second");
  assert.equal(removed.removed, true);
  const remaining = await listProviderCredentialEntries(root, "openai-codex");
  assert.deepEqual(remaining.map((entry) => entry.id), ["first"]);
});

test("appended provider credential becomes the active account", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-credential-append-"));
  await ensureRuntimeConfig(root);
  await appendProviderCredentialEntry(root, "openai-codex", {
    id: "old",
    label: "Old",
    auth_type: "oauth",
    access_token: fakeJwt({ email: "old@example.com" })
  });
  await appendProviderCredentialEntry(root, "openai-codex", {
    id: "new",
    label: "New",
    auth_type: "oauth",
    access_token: fakeJwt({ email: "new@example.com" })
  });
  const entries = await listProviderCredentialEntries(root, "openai-codex");
  assert.deepEqual(entries.map((entry) => entry.id), ["new", "old"]);
  assert.equal(entries[0].active, true);
  assert.equal(entries[0].email, "new@example.com");
});

test("CODMES env keys are used directly without legacy aliases", async () => {
  assert.deepEqual(envAliases("CODMES_OPENAI_API_KEY"), ["CODMES_OPENAI_API_KEY"]);
  assert.deepEqual(envAliases("CODMES_CUSTOM_API_KEY"), ["CODMES_CUSTOM_API_KEY"]);

  const keys = providerEnvKeys({ env: ["CODMES_OPENAI_API_KEY", "OPENAI_API_KEY"] });
  assert.deepEqual(keys, ["CODMES_OPENAI_API_KEY", "OPENAI_API_KEY"]);

  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-env-status-"));
  await ensureRuntimeConfig(root);
  const status = await listCredentialStatus(root, {
    CODMES_OPENAI_API_KEY: "new-key"
  });
  const openai = status.find((item) => item.provider === "openai-api");
  assert.equal(openai.configured, true);
  assert.ok(openai.envKeys.includes("CODMES_OPENAI_API_KEY"));
});

function fakeJwt(payload) {
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${header}.${body}.signature`;
}
