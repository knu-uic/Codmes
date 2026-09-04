import { BUILTIN_PROVIDERS, readCredentials } from "./config-store.mjs";

function normalizeOllamaHost(value) {
  return String(value || "http://127.0.0.1:11434")
    .replace(/\/v1\/?$/, "")
    .replace(/\/$/, "");
}

export async function discoverOllamaModels(
  workspaceRoot,
  { env = process.env, fetchImpl = fetch, timeoutMs = 5000 } = {}
) {
  const provider = BUILTIN_PROVIDERS.find((item) => item.id === "ollama-local");
  const credentials = await readCredentials(workspaceRoot);
  const values = credentials.providers?.[provider.id]?.values || {};
  const configuredUrl = values.baseUrl
    || values.BASE_URL
    || values.OLLAMA_HOST
    || env.OLLAMA_HOST
    || provider.defaultBaseUrl;
  const host = normalizeOllamaHost(configuredUrl);

  let response;
  try {
    response = await fetchImpl(`${host}/api/tags`, {
      signal: AbortSignal.timeout(timeoutMs)
    });
  } catch (error) {
    throw Object.assign(
      new Error(`Could not connect to Ollama at ${host}: ${error.message}`),
      { status: 502 }
    );
  }
  if (!response.ok) {
    throw Object.assign(
      new Error(`Ollama model discovery failed: ${response.status}`),
      { status: 502 }
    );
  }

  const payload = await response.json();
  const models = (payload.models || [])
    .filter((item) => {
      const capabilities = Array.isArray(item.capabilities) ? item.capabilities : [];
      return capabilities.length === 0
        || capabilities.some((capability) => ["completion", "tools", "thinking"].includes(capability));
    })
    .map((item) => item.model || item.name)
    .filter(Boolean);

  return {
    provider: provider.id,
    source: "ollama",
    baseUrl: `${host}/v1`,
    models
  };
}
