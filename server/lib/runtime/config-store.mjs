import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { parseConfigYaml, stringifyConfigYaml } from "./yaml-utils.mjs";
import { migrateWorkspaceState, stateRoot } from "./state-dir.mjs";

export const BUILTIN_PROVIDERS = [
  { id: "nous", name: "Nous Research", authType: "oauth_device_code", tab: "accounts", env: ["CODMES_NOUS_API_KEY", "NOUS_API_KEY"], models: ["anthropic/claude-fable-5", "anthropic/claude-opus-4.8", "openai/gpt-5.5", "openai/gpt-5.4-mini"] },
  { id: "openrouter", name: "OpenRouter", authType: "api_key", tab: "keys", env: ["CODMES_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"], models: ["anthropic/claude-opus-4.8", "openai/gpt-5.5", "openai/gpt-5.4-mini", "google/gemini-3-pro-preview"] },
  { id: "moa", name: "Mixture of Agents", authType: "virtual", tab: "keys", env: [], models: ["default"] },
  { id: "novita", name: "NovitaAI", authType: "api_key", tab: "keys", env: ["CODMES_NOVITA_API_KEY", "NOVITA_API_KEY"], baseUrlEnv: "NOVITA_BASE_URL", models: ["moonshotai/kimi-k2.5", "minimax/minimax-m2.7", "zai-org/glm-5"] },
  { id: "lmstudio", name: "LM Studio", authType: "api_key", tab: "keys", env: ["CODMES_LM_API_KEY", "LM_API_KEY"], baseUrlEnv: "LM_BASE_URL", defaultBaseUrl: "http://127.0.0.1:1234/v1", models: ["local-model"] },
  { id: "anthropic", name: "Anthropic", authType: "api_key", tab: "keys", env: ["CODMES_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"], baseUrlEnv: "ANTHROPIC_BASE_URL", models: ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6"] },
  { id: "openai-codex", name: "OpenAI Codex", authType: "oauth_external", tab: "accounts", env: [], models: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark"] },
  { id: "openai-api", name: "OpenAI API", authType: "api_key", tab: "keys", env: ["CODMES_OPENAI_API_KEY", "OPENAI_API_KEY"], baseUrlEnv: "OPENAI_BASE_URL", models: ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5-mini"] },
  { id: "alibaba", name: "Qwen Cloud", authType: "api_key", tab: "keys", env: ["CODMES_DASHSCOPE_API_KEY", "DASHSCOPE_API_KEY"], baseUrlEnv: "DASHSCOPE_BASE_URL", models: ["qwen3.7-max", "qwen3.6-plus", "qwen3-coder-plus"] },
  { id: "xai-oauth", name: "xAI Grok OAuth", authType: "oauth_external", tab: "accounts", env: [], models: ["grok-build-0.1", "grok-composer-2.5-fast", "grok-4.3"] },
  { id: "xiaomi", name: "Xiaomi MiMo", authType: "api_key", tab: "keys", env: ["CODMES_XIAOMI_API_KEY", "XIAOMI_API_KEY"], baseUrlEnv: "XIAOMI_BASE_URL", models: ["mimo-v2.5-pro", "mimo-v2.5", "mimo-v2-pro"] },
  { id: "tencent-tokenhub", name: "Tencent TokenHub", authType: "api_key", tab: "keys", env: ["CODMES_TOKENHUB_API_KEY", "TOKENHUB_API_KEY"], baseUrlEnv: "TOKENHUB_BASE_URL", models: ["hy3-preview"] },
  { id: "nvidia", name: "NVIDIA NIM", authType: "api_key", tab: "keys", env: ["CODMES_NVIDIA_API_KEY", "NVIDIA_API_KEY"], baseUrlEnv: "NVIDIA_BASE_URL", models: ["nvidia/llama-3.1-nemotron-70b-instruct", "nvidia/llama-3.3-70b-instruct"] },
  { id: "copilot", name: "GitHub Copilot", authType: "api_key", tab: "keys", env: ["CODMES_COPILOT_GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"], baseUrlEnv: "COPILOT_API_BASE_URL", models: ["gpt-5.4", "gpt-5.4-mini", "gpt-5-mini", "gpt-4.1"] },
  { id: "copilot-acp", name: "GitHub Copilot ACP", authType: "external_process", tab: "accounts", env: [], models: ["gpt-5.4", "gpt-5.4-mini", "gpt-5-mini", "gpt-4.1"] },
  { id: "huggingface", name: "Hugging Face", authType: "api_key", tab: "keys", env: ["CODMES_HF_TOKEN", "HF_TOKEN"], baseUrlEnv: "HF_BASE_URL", models: ["Qwen/Qwen3.5-72B-Instruct", "deepseek-ai/DeepSeek-V3.2"] },
  { id: "gemini", name: "Google AI Studio", authType: "api_key", tab: "keys", env: ["CODMES_GOOGLE_API_KEY", "CODMES_GEMINI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"], baseUrlEnv: "GEMINI_BASE_URL", models: ["gemini-3.1-flash-lite", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-3.5-flash"] },
  { id: "vertex", name: "Google Vertex AI", authType: "vertex", tab: "keys", env: ["CODMES_GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_APPLICATION_CREDENTIALS"], models: [] },
  { id: "deepseek", name: "DeepSeek", authType: "api_key", tab: "keys", env: ["CODMES_DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"], baseUrlEnv: "DEEPSEEK_BASE_URL", models: ["deepseek-chat", "deepseek-reasoner"] },
  { id: "xai", name: "xAI", authType: "api_key", tab: "keys", env: ["CODMES_XAI_API_KEY", "XAI_API_KEY"], baseUrlEnv: "XAI_BASE_URL", models: ["grok-build-0.1", "grok-4.3"] },
  { id: "zai", name: "Z.AI / GLM", authType: "api_key", tab: "keys", env: ["CODMES_GLM_API_KEY", "CODMES_ZAI_API_KEY", "GLM_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY"], baseUrlEnv: "GLM_BASE_URL", models: ["glm-5.2", "glm-5", "glm-4-9b"] },
  { id: "kimi-coding", name: "Kimi / Kimi Coding Plan", authType: "api_key", tab: "keys", env: ["CODMES_KIMI_API_KEY", "KIMI_API_KEY", "KIMI_CODING_API_KEY"], baseUrlEnv: "KIMI_BASE_URL", models: ["kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5", "kimi-for-coding"] },
  { id: "kimi-coding-cn", name: "Kimi / Moonshot China", authType: "api_key", tab: "keys", env: ["CODMES_KIMI_CN_API_KEY", "KIMI_CN_API_KEY"], models: ["kimi-k2.6", "kimi-k2.5", "kimi-k2-thinking"] },
  { id: "stepfun", name: "StepFun Step Plan", authType: "api_key", tab: "keys", env: ["CODMES_STEPFUN_API_KEY", "STEPFUN_API_KEY"], baseUrlEnv: "STEPFUN_BASE_URL", models: ["step-3.5-flash", "step-3.5-flash-2603"] },
  { id: "minimax", name: "MiniMax", authType: "api_key", tab: "keys", env: ["CODMES_MINIMAX_API_KEY", "MINIMAX_API_KEY"], baseUrlEnv: "MINIMAX_BASE_URL", models: ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5"] },
  { id: "minimax-oauth", name: "MiniMax OAuth", authType: "oauth_minimax", tab: "accounts", env: [], models: ["MiniMax-M3", "MiniMax-M2.7"] },
  { id: "minimax-cn", name: "MiniMax China", authType: "api_key", tab: "keys", env: ["CODMES_MINIMAX_CN_API_KEY", "MINIMAX_CN_API_KEY"], baseUrlEnv: "MINIMAX_CN_BASE_URL", models: ["MiniMax-M3", "MiniMax-M2.7"] },
  { id: "ollama-cloud", name: "Ollama Cloud", authType: "api_key", tab: "keys", env: ["CODMES_OLLAMA_API_KEY", "OLLAMA_API_KEY"], baseUrlEnv: "OLLAMA_BASE_URL", models: ["deepseek-v4-flash", "minimax-m2.5", "glm-4.7"] },
  { id: "ollama-local", name: "Ollama Local", authType: "none", tab: "local", env: [], baseUrlEnv: "OLLAMA_HOST", defaultBaseUrl: "http://127.0.0.1:11434/v1", models: [] },
  { id: "arcee", name: "Arcee AI", authType: "api_key", tab: "keys", env: ["CODMES_ARCEEAI_API_KEY", "ARCEEAI_API_KEY"], baseUrlEnv: "ARCEE_BASE_URL", models: ["trinity-large-thinking", "trinity-large-preview", "trinity-mini"] },
  { id: "gmi", name: "GMI Cloud", authType: "api_key", tab: "keys", env: ["CODMES_GMI_API_KEY", "GMI_API_KEY"], baseUrlEnv: "GMI_BASE_URL", models: ["zai-org/GLM-5.1-FP8", "deepseek-ai/DeepSeek-V3.2", "openai/gpt-5.4"] },
  { id: "kilocode", name: "Kilo Code", authType: "api_key", tab: "keys", env: ["CODMES_KILOCODE_API_KEY", "KILOCODE_API_KEY"], baseUrlEnv: "KILOCODE_BASE_URL", models: ["inclusionai/ling-2.6-1t", "inclusionai/ring-2.6-1t", "meta-llama/llama-3.1-70b-instruct"] },
  { id: "opencode-zen", name: "OpenCode Zen", authType: "api_key", tab: "keys", env: ["CODMES_OPENCODE_ZEN_API_KEY", "OPENCODE_ZEN_API_KEY"], baseUrlEnv: "OPENCODE_ZEN_BASE_URL", models: ["ring-2.6-1t-free", "mimo-v2-pro-free", "deepseek-v4-flash"] },
  { id: "opencode-go", name: "OpenCode Go", authType: "api_key", tab: "keys", env: ["CODMES_OPENCODE_GO_API_KEY", "OPENCODE_GO_API_KEY"], baseUrlEnv: "OPENCODE_GO_BASE_URL", models: ["deepseek-v4-flash", "minimax-m2.5", "qwen3.7-plus"] },
  { id: "bedrock", name: "AWS Bedrock", authType: "aws_sdk", tab: "keys", env: ["AWS_PROFILE", "AWS_REGION"], models: ["us.anthropic.claude-sonnet-4-6", "us.amazon.nova-pro-v1:0"] },
  { id: "azure-foundry", name: "Azure Foundry", authType: "api_key", tab: "keys", env: ["CODMES_AZURE_FOUNDRY_API_KEY", "AZURE_FOUNDRY_API_KEY"], baseUrlEnv: "AZURE_FOUNDRY_BASE_URL", models: [] },
  { id: "qwen-oauth", name: "Qwen OAuth Portal", authType: "oauth_external", tab: "accounts", env: ["CODMES_QWEN_API_KEY", "QWEN_API_KEY"], models: [] },
  { id: "alibaba-coding-plan", name: "Alibaba Cloud Coding Plan", authType: "api_key", tab: "keys", env: ["CODMES_ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_CODING_PLAN_API_KEY", "DASHSCOPE_API_KEY"], baseUrlEnv: "ALIBABA_CODING_PLAN_BASE_URL", models: ["qwen3.7-max", "qwen3.6-plus", "qwen3-coder-plus"] },
  { id: "custom", name: "Custom OpenAI-compatible", authType: "api_key", tab: "keys", env: ["CODMES_CUSTOM_API_KEY"], baseUrlEnv: "CODMES_CUSTOM_BASE_URL", models: ["custom-model"] },
  { id: "google-antigravity", name: "Google Antigravity OAuth", authType: "oauth_external", tab: "accounts", env: ["CODMES_GOOGLE_ANTIGRAVITY_TOKEN"], models: ["google-antigravity"] }
];

const USER_FACING_PROVIDER_IDS = new Set([
  "openai-codex",
  "ollama-cloud",
  "ollama-local"
]);

export function runtimeConfigDir(workspaceRoot) {
  return path.join(stateRoot(workspaceRoot), "config");
}

export async function ensureRuntimeConfig(workspaceRoot) {
  await migrateWorkspaceState(workspaceRoot);
  const dir = runtimeConfigDir(workspaceRoot);
  await fs.mkdir(dir, { recursive: true });
  await fs.chmod(dir, 0o700);
  const configPath = path.join(dir, "config.yaml");
  await writeYamlIfMissing(configPath, "model:\n  default:\n  provider:\n");
  const configContent = await fs.readFile(configPath, "utf8");
  const parsedConfig = parseConfigYaml(configContent);
  if (!/^mcp_servers:/m.test(configContent)) {
    parsedConfig.mcp_servers = [{
      name: "knu-rag",
      transport: "streamable_http",
      url: "http://127.0.0.1:8000/api/mcp/",
      surfaces: ["chat"],
      enabled: true
    }];
    await fs.writeFile(configPath, stringifyConfigYaml(configContent, parsedConfig), "utf8");
  }
  await writeJsonIfMissing(path.join(dir, "auth.json"), { version: 1, credential_pool: {} });
  await fs.chmod(path.join(dir, "auth.json"), 0o600);
}

export function listProviderRegistry() {
  return BUILTIN_PROVIDERS.filter((provider) => USER_FACING_PROVIDER_IDS.has(provider.id)).map((provider) => ({
    ...provider,
    env: providerEnvKeys(provider),
    baseUrlEnv: primaryCodmesEnvKey(provider.baseUrlEnv)
  }));
}

export async function readRuntimeConfig(workspaceRoot) {
  await ensureRuntimeConfig(workspaceRoot);
  const filePath = path.join(runtimeConfigDir(workspaceRoot), "config.yaml");
  try {
    const content = await fs.readFile(filePath, "utf8");
    const parsed = parseConfigYaml(content);
    return {
      schemaVersion: 1,
      defaultModel: parsed.model ? {
        provider: parsed.model.provider || null,
        model: parsed.model.default || null,
        baseUrl: parsed.model.base_url || null,
        apiMode: parsed.model.api_mode || null,
        id: (parsed.model.provider && parsed.model.default) ? `${parsed.model.provider}:${parsed.model.default}` : null,
        updatedAt: new Date().toISOString()
      } : null,
      fallbackChain: parsed.model?.fallback_chain || [],
      disabledTools: parsed.disabled_tools || [],
      mcpServers: normalizeMcpServers(parsed.mcp_servers || []),
      models: [],
      providers: {}
    };
  } catch (error) {
    return {
      schemaVersion: 1,
      defaultModel: null,
      fallbackChain: [],
      disabledTools: [],
      mcpServers: [],
      models: [],
      providers: {}
    };
  }
}

export async function writeRuntimeConfig(workspaceRoot, value) {
  await ensureRuntimeConfig(workspaceRoot);
  const filePath = path.join(runtimeConfigDir(workspaceRoot), "config.yaml");
  let existingContent = "";
  try {
    existingContent = await fs.readFile(filePath, "utf8");
  } catch {}

  const parsed = parseConfigYaml(existingContent);
  if (value.defaultModel) {
    parsed.model = {
      ...(parsed.model || {}),
      default: value.defaultModel.model,
      provider: value.defaultModel.provider,
      fallback_chain: value.fallbackChain || parsed.model?.fallback_chain || []
    };
    if (value.defaultModel.baseUrl !== undefined) parsed.model.base_url = value.defaultModel.baseUrl || "";
    if (value.defaultModel.apiMode !== undefined) parsed.model.api_mode = value.defaultModel.apiMode || "";
  } else {
    parsed.model = null;
  }

  if (value.fallbackChain !== undefined) {
    if (parsed.model) {
      parsed.model.fallback_chain = value.fallbackChain;
    } else {
      parsed.model = { fallback_chain: value.fallbackChain, default: "", provider: "" };
    }
  }
  if (value.disabledTools !== undefined) {
    parsed.disabled_tools = value.disabledTools;
  }
  if (value.mcpServers !== undefined) {
    parsed.mcp_servers = normalizeMcpServers(value.mcpServers);
  }

  const updatedContent = stringifyConfigYaml(existingContent, parsed);
  await fs.writeFile(filePath, updatedContent, "utf8");
}

export function normalizeMcpServers(servers) {
  if (!Array.isArray(servers)) return [];
  return servers.map(normalizeMcpServerConfig);
}

export function normalizeMcpServerConfig(server = {}) {
  const name = String(server.name || "").trim();
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) throw new Error("MCP server name must contain only letters, numbers, dashes, and underscores.");
  const transport = String(server.transport || "stdio").trim() || "stdio";
  const enabled = server.enabled !== false;
  if (transport === "stdio") {
    const command = String(server.command || "").trim();
    if (!command) throw new Error("Missing MCP command.");
    return { name, transport, command, args: Array.isArray(server.args) ? server.args.map(String) : [], enabled,
      env: sanitizeMcpStringMap(server.env), scopePath: String(server.scopePath || server.scope_path || "").trim() };
  }
  if (transport !== "streamable_http") throw new Error("MCP transport must be 'stdio' or 'streamable_http'.");
  const url = String(server.url || "").trim();
  const credentialId = String(server.credential_id || server.credentialId || "").trim();
  const surfaces = Array.isArray(server.surfaces) ? [...new Set(server.surfaces.map(String).map((s) => s.trim()).filter(Boolean))] : [];
  if (!surfaces.length || surfaces.some((surface) => !["chat", "notes", "code"].includes(surface))) throw new Error("MCP streamable_http requires at least one allowed surface.");
  let parsed;
  try { parsed = new URL(url); } catch { throw new Error("MCP streamable_http requires an absolute HTTPS url."); }
  const isLoopbackHttp = parsed.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname);
  if ((!isLoopbackHttp && parsed.protocol !== "https:") || !parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("MCP streamable_http requires an absolute HTTPS url, or loopback HTTP, without credentials, query, or fragment.");
  }
  if (!credentialId && !isLoopbackHttp) throw new Error("A valid MCP credential_id is required.");
  if (credentialId && !/^[a-zA-Z0-9_-]+$/.test(credentialId)) throw new Error("A valid MCP credential_id is required.");
  if ((Array.isArray(server.args) && server.args.length) || Object.keys(sanitizeMcpStringMap(server.env)).length) {
    throw new Error("MCP streamable_http does not accept args or env; provision its credential server-side.");
  }
  return { name, transport, url, ...(credentialId ? { credential_id: credentialId } : {}), surfaces, enabled };
}

function sanitizeMcpStringMap(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).map(([key, val]) => [String(key).trim(), String(val ?? "").trim()]).filter(([key, val]) => key && val));
}

export async function setMcpCredential(workspaceRoot, credentialId, token) {
  await ensureRuntimeConfig(workspaceRoot);
  const id = String(credentialId || "").trim();
  const value = String(token || "").trim();
  if (!/^[a-zA-Z0-9_-]+$/.test(id) || !value) throw new Error("A valid credential id and non-empty token are required.");
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  const auth = await readAuthObject(authPath);
  auth.mcp_credentials = { ...(auth.mcp_credentials || {}), [id]: { token: value } };
  await writeAuthObject(authPath, auth);
  return { credentialId: id, configured: true };
}

export async function getMcpCredential(workspaceRoot, credentialId) {
  await ensureRuntimeConfig(workspaceRoot);
  const auth = await readAuthObject(path.join(runtimeConfigDir(workspaceRoot), "auth.json"));
  return String(auth.mcp_credentials?.[String(credentialId || "")]?.token || "") || null;
}

export async function getMcpCredentialStatus(workspaceRoot, credentialId) {
  return Boolean(await getMcpCredential(workspaceRoot, credentialId));
}

export async function removeMcpCredential(workspaceRoot, credentialId) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  const auth = await readAuthObject(authPath);
  const id = String(credentialId || "");
  const removed = Boolean(auth.mcp_credentials?.[id]);
  if (auth.mcp_credentials) delete auth.mcp_credentials[id];
  await writeAuthObject(authPath, auth);
  return { credentialId: id, removed };
}

async function readAuthObject(authPath) {
  try { return JSON.parse(await fs.readFile(authPath, "utf8")); } catch { return { version: 1, credential_pool: {} }; }
}

async function writeAuthObject(authPath, value) {
  const temp = `${authPath}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  await fs.writeFile(temp, JSON.stringify(value, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await fs.chmod(temp, 0o600);
  await fs.rename(temp, authPath);
  await fs.chmod(authPath, 0o600);
}

export async function listRuntimeModels(workspaceRoot) {
  const config = await readRuntimeConfig(workspaceRoot);
  const defaultModel = config.defaultModel;
  const rows = [];
  const seen = new Set();

  if (defaultModel) {
    const id = defaultModel.id || `${defaultModel.provider}:${defaultModel.model}`;
    if (id && !seen.has(id)) {
      seen.add(id);
      rows.push({
        id,
        name: defaultModel.model,
        model: defaultModel.model,
        provider: defaultModel.provider,
        source: "config",
        isActive: true
      });
    }
  }

  // Get status of all credentials to find configured providers
  const statuses = await listCredentialStatus(workspaceRoot);
  const configuredProviders = new Set(
    statuses.filter((s) => s.configured).map((s) => s.provider)
  );

  for (const provider of BUILTIN_PROVIDERS) {
    if (!configuredProviders.has(provider.id)) continue;
    for (const modelName of provider.models || []) {
      const id = `${provider.id}:${modelName}`;
      if (seen.has(id)) continue;
      seen.add(id);
      const isActive = defaultModel && defaultModel.provider === provider.id && defaultModel.model === modelName;
      rows.push({
        id,
        name: modelName,
        model: modelName,
        provider: provider.id,
        source: "registry",
        isActive: Boolean(isActive)
      });
    }
  }

  return rows;
}

export async function setDefaultModel(workspaceRoot, provider, model) {
  const config = await readRuntimeConfig(workspaceRoot);
  const next = {
    provider,
    model,
    id: `${provider}:${model}`,
    updatedAt: new Date().toISOString()
  };
  await writeRuntimeConfig(workspaceRoot, {
    ...config,
    defaultModel: next
  });
  return next;
}

export async function readCredentials(workspaceRoot) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  const configPath = path.join(runtimeConfigDir(workspaceRoot), "config.yaml");

  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}

  let configObj = { custom_providers: [] };
  try {
    const yamlContent = await fs.readFile(configPath, "utf8");
    configObj = parseConfigYaml(yamlContent);
  } catch {}

  const credentials = {
    schemaVersion: 1,
    providers: {}
  };

  const pool = authObj.credential_pool || {};

  // Hermes-compatible custom endpoint setup stores the active endpoint on
  // model.base_url. Expose it under the stable `custom` runtime provider so a
  // model selected by the vendored TUI is immediately executable by AIW.
  if (configObj.model?.provider === "custom" && configObj.model?.base_url) {
    credentials.providers.custom = {
      values: {
        baseUrl: configObj.model.base_url,
        BASE_URL: configObj.model.base_url,
        CODMES_CUSTOM_BASE_URL: configObj.model.base_url,
        CODMES_CUSTOM_BASE_URL: configObj.model.base_url
      }
    };
  }

  // Map credentials from auth.json credential_pool
  for (const [providerId, entries] of Object.entries(pool)) {
    if (!Array.isArray(entries) || entries.length === 0) continue;
    const activeEntry = entries[0]; // pick first/active entry
    if (!credentials.providers[providerId]) {
      credentials.providers[providerId] = { values: {} };
    }
    const values = credentials.providers[providerId].values;

    if (activeEntry.access_token) {
      values.apiKey = activeEntry.access_token;
      values.API_KEY = activeEntry.access_token;
      values.token = activeEntry.access_token;
      values.TOKEN = activeEntry.access_token;
      
      const providerDef = BUILTIN_PROVIDERS.find((p) => p.id === providerId);
      if (providerDef && providerDef.env) {
        for (const envKey of providerEnvKeys(providerDef)) {
          values[envKey] = activeEntry.access_token;
        }
      }
    }
    if (activeEntry.base_url) {
      values.baseUrl = activeEntry.base_url;
      values.BASE_URL = activeEntry.base_url;
      const providerDef = BUILTIN_PROVIDERS.find((p) => p.id === providerId);
      if (providerDef && providerDef.baseUrlEnv) {
        for (const envKey of providerBaseUrlKeys(providerDef)) {
          values[envKey] = activeEntry.base_url;
        }
      }
    }
  }

  // Layer custom providers config
  if (configObj.custom_providers) {
    for (const cp of configObj.custom_providers) {
      const providerId = cp.name;
      if (!credentials.providers[providerId]) {
        credentials.providers[providerId] = { values: {} };
      }
      const values = credentials.providers[providerId].values;
      if (cp.base_url) {
        values.baseUrl = cp.base_url;
        values.BASE_URL = cp.base_url;
        values.CODMES_CUSTOM_BASE_URL = cp.base_url;
        values.CODMES_CUSTOM_BASE_URL = cp.base_url;
      }

      if (
        configObj.model?.provider === "custom"
        && cp.base_url
        && cp.base_url === configObj.model?.base_url
      ) {
        credentials.providers.custom = {
          values: {
            ...(credentials.providers.custom?.values || {}),
            ...values
          }
        };
      }
      if (cp.key_env) {
        const poolEntries = pool[providerId] || [];
        if (poolEntries.length > 0 && poolEntries[0].access_token) {
          for (const envKey of envAliases(cp.key_env)) {
            values[envKey] = poolEntries[0].access_token;
          }
          values.apiKey = poolEntries[0].access_token;
          values.API_KEY = poolEntries[0].access_token;
        }
      }
    }
  }

  return credentials;
}

export async function readProviderCredentialEntry(workspaceRoot, providerId) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}
  const entries = authObj.credential_pool?.[providerId];
  if (!Array.isArray(entries) || entries.length === 0) return null;
  return { ...entries[0] };
}

export async function listProviderCredentialEntries(workspaceRoot, providerId) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}
  const entries = authObj.credential_pool?.[providerId];
  if (!Array.isArray(entries)) return [];
  return entries.map((entry, index) => sanitizeCredentialEntry(entry, index));
}

export async function appendProviderCredentialEntry(workspaceRoot, providerId, entry) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}
  if (!authObj.credential_pool) authObj.credential_pool = {};
  if (!Array.isArray(authObj.credential_pool[providerId])) {
    authObj.credential_pool[providerId] = [];
  }
  const entries = authObj.credential_pool[providerId];
  const nextEntry = {
    id: entry.id || crypto.randomBytes(6).toString("hex"),
    label: entry.label || `${providerId}-credential-${entries.length + 1}`,
    auth_type: entry.auth_type || entry.authType || "oauth",
    priority: 0,
    source: entry.source || "manual",
    ...entry
  };
  authObj.credential_pool[providerId] = [
    nextEntry,
    ...entries.map((item, index) => ({ ...item, priority: index + 1 }))
  ];
  await fs.writeFile(authPath, JSON.stringify(authObj, null, 2) + "\n", "utf8");
  return sanitizeCredentialEntry(nextEntry, 0);
}

export async function selectProviderCredentialEntry(workspaceRoot, providerId, credentialId) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}
  const entries = authObj.credential_pool?.[providerId];
  if (!Array.isArray(entries) || entries.length === 0) {
    throw Object.assign(new Error(`No credentials stored for provider '${providerId}'.`), { status: 404 });
  }
  const index = entries.findIndex((entry) => String(entry.id || "") === String(credentialId || ""));
  if (index < 0) {
    throw Object.assign(new Error(`Credential '${credentialId}' not found for provider '${providerId}'.`), { status: 404 });
  }
  const [selected] = entries.splice(index, 1);
  entries.unshift(selected);
  authObj.credential_pool[providerId] = entries;
  await fs.writeFile(authPath, JSON.stringify(authObj, null, 2) + "\n", "utf8");
  return sanitizeCredentialEntry(selected, 0);
}

export async function removeProviderCredentialEntry(workspaceRoot, providerId, credentialId) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}
  const entries = authObj.credential_pool?.[providerId];
  if (!Array.isArray(entries)) return { provider: providerId, credentialId, removed: false };
  const next = entries.filter((entry) => String(entry.id || "") !== String(credentialId || ""));
  const removed = next.length !== entries.length;
  if (next.length > 0) {
    authObj.credential_pool[providerId] = next;
  } else {
    delete authObj.credential_pool[providerId];
  }
  await fs.writeFile(authPath, JSON.stringify(authObj, null, 2) + "\n", "utf8");
  return { provider: providerId, credentialId, removed };
}

export async function patchProviderCredentialEntry(workspaceRoot, providerId, patch) {
  await ensureRuntimeConfig(workspaceRoot);
  const authPath = path.join(runtimeConfigDir(workspaceRoot), "auth.json");
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}
  if (!authObj.credential_pool) authObj.credential_pool = {};
  if (!Array.isArray(authObj.credential_pool[providerId])) {
    authObj.credential_pool[providerId] = [];
  }
  let entry = authObj.credential_pool[providerId][0];
  if (!entry) {
    entry = {
      id: crypto.randomBytes(3).toString("hex"),
      label: `${providerId}-credential-1`,
      auth_type: "api_key",
      priority: 0,
      source: "manual"
    };
    authObj.credential_pool[providerId].push(entry);
  }
  Object.assign(entry, patch);
  await fs.writeFile(authPath, JSON.stringify(authObj, null, 2) + "\n", "utf8");
  return { ...entry };
}

export async function writeCredentials(workspaceRoot, value) {
  // Kept for backward compatibility interface, but we write via auth.json and config.yaml in setCredentialValue
  await ensureRuntimeConfig(workspaceRoot);
}

export async function listCredentialStatus(workspaceRoot, env = process.env) {
  const credentials = await readCredentials(workspaceRoot);
  return BUILTIN_PROVIDERS.map((provider) => {
    const stored = credentials.providers?.[provider.id] || {};
    const rawStoredKeys = Object.keys(stored.values || {});
    const storedKeys = rawStoredKeys.filter(
      (k) => k !== "apiKey" && k !== "API_KEY" && k !== "token" && k !== "TOKEN" && k !== "baseUrl" && k !== "BASE_URL"
    );
    const hasSecretOnlyStoredCredential = rawStoredKeys.some((key) =>
      ["apiKey", "API_KEY", "token", "TOKEN"].includes(key)
    );
    const envKeys = providerEnvKeys(provider).filter((key) => Boolean(env[key]));
    for (const key of providerBaseUrlKeys(provider)) {
      if (env[key]) envKeys.push(key);
    }
    
    // Check if configured
    let configured = storedKeys.length > 0
      || envKeys.length > 0
      || provider.authType === "none"
      || (provider.authType.startsWith("oauth") && hasSecretOnlyStoredCredential);
    if (provider.id === "custom") {
      // Custom provider needs base_url configuration to be "configured"
      const hasBaseUrl = stored.values?.baseUrl
        || stored.values?.CODMES_CUSTOM_BASE_URL
        || stored.values?.CODMES_CUSTOM_BASE_URL
        || env.CODMES_CUSTOM_BASE_URL
        || env.CODMES_CUSTOM_BASE_URL;
      configured = Boolean(hasBaseUrl);
    }

    return {
      provider: provider.id,
      name: provider.name,
      authType: provider.authType,
      configured,
      storedKeys,
      envKeys
    };
  });
}

export async function setCredentialValue(workspaceRoot, providerId, key, value) {
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
  if (!provider) throw Object.assign(new Error(`Unknown provider: ${providerId}`), { status: 400 });

  const dir = runtimeConfigDir(workspaceRoot);
  const authPath = path.join(dir, "auth.json");
  const configPath = path.join(dir, "config.yaml");

  // Read config.yaml
  let configContent = "";
  try {
    configContent = await fs.readFile(configPath, "utf8");
  } catch {}
  const configObj = parseConfigYaml(configContent);
  if (!Array.isArray(configObj.custom_providers)) configObj.custom_providers = [];

  // Read auth.json
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}

  if (!authObj.credential_pool) authObj.credential_pool = {};
  if (!authObj.credential_pool[providerId]) authObj.credential_pool[providerId] = [];

  const pool = authObj.credential_pool[providerId];
  let entry = pool[0];
  if (!entry) {
    entry = {
      id: crypto.randomBytes(3).toString("hex"),
      label: providerId === "custom" ? "api-key-1" : `${providerId}-api-key-1`,
      auth_type: "api_key",
      priority: 0,
      source: "manual",
      access_token: "",
      base_url: ""
    };
    pool.push(entry);
  }

  if (providerId === "custom") {
    if (envAliases("CODMES_CUSTOM_BASE_URL").includes(key)) {
      entry.base_url = value;
      // Also update config.yaml custom_providers
      let cp = configObj.custom_providers.find((c) => c.name === "custom");
      if (!cp) {
        cp = { name: "custom", base_url: value, key_env: "CODMES_CUSTOM_API_KEY" };
        configObj.custom_providers.push(cp);
      } else {
        cp.base_url = value;
      }
    } else if (envAliases("CODMES_CUSTOM_API_KEY").includes(key)) {
      entry.access_token = value;
      // Ensure custom_providers is configured in config.yaml
      let cp = configObj.custom_providers.find((c) => c.name === "custom");
      if (!cp) {
        cp = { name: "custom", base_url: entry.base_url || "", key_env: "CODMES_CUSTOM_API_KEY" };
        configObj.custom_providers.push(cp);
      }
    }
  } else {
    // Normal provider
    const isApiKey = providerEnvKeys(provider).includes(key);
    const isBaseUrl = providerBaseUrlKeys(provider).includes(key);
    if (isApiKey || key.toLowerCase().includes("key") || key.toLowerCase().includes("token")) {
      entry.access_token = value;
    } else if (isBaseUrl || key.toLowerCase().includes("url")) {
      entry.base_url = value;
    } else {
      entry.access_token = value;
    }
  }

  // Write files back
  await fs.writeFile(authPath, JSON.stringify(authObj, null, 2) + "\n", "utf8");
  await fs.writeFile(configPath, stringifyConfigYaml(configContent, configObj), "utf8");

  return {
    provider: providerId,
    key,
    stored: true
  };
}

export async function removeCredentialValue(workspaceRoot, providerId, key = "") {
  const dir = runtimeConfigDir(workspaceRoot);
  const authPath = path.join(dir, "auth.json");
  const configPath = path.join(dir, "config.yaml");

  // Read config.yaml
  let configContent = "";
  try {
    configContent = await fs.readFile(configPath, "utf8");
  } catch {}
  const configObj = parseConfigYaml(configContent);
  if (!Array.isArray(configObj.custom_providers)) configObj.custom_providers = [];

  // Read auth.json
  let authObj = { version: 1, credential_pool: {} };
  try {
    authObj = JSON.parse(await fs.readFile(authPath, "utf8"));
  } catch {}

  const pool = authObj.credential_pool || {};
  if (!pool[providerId]) return { provider: providerId, removed: false };

  if (!key) {
    delete pool[providerId];
    if (providerId === "custom") {
      configObj.custom_providers = configObj.custom_providers.filter((c) => c.name !== "custom");
    }
  } else {
    const entry = pool[providerId][0];
    if (entry) {
      if (providerId === "custom") {
        if (envAliases("CODMES_CUSTOM_BASE_URL").includes(key)) {
          entry.base_url = "";
          configObj.custom_providers = configObj.custom_providers.filter((c) => c.name !== "custom");
        } else if (envAliases("CODMES_CUSTOM_API_KEY").includes(key)) {
          entry.access_token = "";
        }
      } else {
        const provider = BUILTIN_PROVIDERS.find((item) => item.id === providerId);
        const isApiKey = provider && providerEnvKeys(provider).includes(key);
        const isBaseUrl = provider && providerBaseUrlKeys(provider).includes(key);
        if (isApiKey || key.toLowerCase().includes("key") || key.toLowerCase().includes("token")) {
          entry.access_token = "";
        } else if (isBaseUrl || key.toLowerCase().includes("url")) {
          entry.base_url = "";
        }
      }
    }
  }

  // Write files back
  await fs.writeFile(authPath, JSON.stringify(authObj, null, 2) + "\n", "utf8");
  await fs.writeFile(configPath, stringifyConfigYaml(configContent, configObj), "utf8");

  return { provider: providerId, key, removed: true };
}

function sanitizeCredentialEntry(entry, index = 0) {
  const token = String(entry?.access_token || entry?.token || "").trim();
  const claims = decodeJwtPayload(token);
  const idClaims = decodeJwtPayload(entry?.id_token);
  const openaiAuth = claims?.["https://api.openai.com/auth"] || {};
  const accountId = stringOrEmpty(openaiAuth.chatgpt_account_id)
    || stringOrEmpty(idClaims?.["https://api.openai.com/auth"]?.chatgpt_account_id)
    || stringOrEmpty(claims?.chatgpt_account_id)
    || stringOrEmpty(idClaims?.chatgpt_account_id)
    || stringOrEmpty(claims?.account_id);
  const email = stringOrEmpty(entry?.account_email)
    || stringOrEmpty(entry?.email)
    || stringOrEmpty(claims?.email)
    || stringOrEmpty(idClaims?.email)
    || stringOrEmpty(claims?.preferred_username)
    || stringOrEmpty(idClaims?.preferred_username)
    || stringOrEmpty(claims?.username);
  return {
    id: String(entry?.id || `credential-${index + 1}`),
    label: String(entry?.label || email || accountId || `Credential ${index + 1}`),
    authType: String(entry?.auth_type || entry?.authType || ""),
    source: String(entry?.source || ""),
    priority: Number.isFinite(Number(entry?.priority)) ? Number(entry.priority) : index,
    active: index === 0,
    hasAccessToken: Boolean(token),
    hasRefreshToken: Boolean(String(entry?.refresh_token || "").trim()),
    baseUrl: String(entry?.base_url || ""),
    accountId,
    email,
    expiresAt: Number.isFinite(Number(claims?.exp)) && Number(claims.exp) > 0
      ? new Date(Number(claims.exp) * 1000).toISOString()
      : ""
  };
}

function decodeJwtPayload(token) {
  try {
    const parts = String(token || "").split(".");
    if (parts.length < 2) return null;
    const padded = parts[1] + "=".repeat((4 - (parts[1].length % 4)) % 4);
    return JSON.parse(Buffer.from(padded, "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

function stringOrEmpty(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

export function envAliases(key) {
  const raw = String(key || "").trim();
  return raw ? [raw] : [];
}

export function providerEnvKeys(provider) {
  return Array.from(new Set((provider.env || []).flatMap(envAliases)));
}

export function providerBaseUrlKeys(provider) {
  return Array.from(new Set(envAliases(provider.baseUrlEnv || "")));
}

function primaryCodmesEnvKey(key) {
  return key || "";
}

async function writeJsonIfMissing(filePath, value) {
  try {
    await fs.access(filePath);
  } catch {
    await fs.writeFile(filePath, JSON.stringify(value, null, 2) + "\n", "utf8");
  }
}

async function writeYamlIfMissing(filePath, value) {
  try {
    await fs.access(filePath);
  } catch {
    await fs.writeFile(filePath, value, "utf8");
  }
}
