export const DEFAULT_CONTEXT_WINDOW = 128_000;
export const DEFAULT_INPUT_BUDGET_RATIO = 0.68;
export const DEFAULT_HISTORY_BUDGET_RATIO = 0.55;
export const DEFAULT_CHECKPOINT_BUDGET_RATIO = 0.18;

export function estimateTextTokens(value = "") {
  const text = String(value || "");
  let ascii = 0;
  let nonAscii = 0;
  for (const character of text) {
    if (character.codePointAt(0) <= 0x7f) ascii += 1;
    else nonAscii += 1;
  }
  return Math.max(1, Math.ceil(ascii / 4 + nonAscii / 1.5));
}

export function estimateMessageTokens(message = {}) {
  const content = typeof message.content === "string"
    ? message.content
    : JSON.stringify(message.content || "");
  return 4 + estimateTextTokens(content);
}

export function estimateMessagesTokens(messages = []) {
  return Math.max(1, (messages || []).reduce((sum, message) => sum + estimateMessageTokens(message), 0));
}

export function estimateContextWindow(model = "") {
  const id = String(model || "").toLowerCase();
  if (!id) return DEFAULT_CONTEXT_WINDOW;
  if (id.includes("codex")) return 400_000;
  if (id.includes("gemma") || id.includes("llama") || id.includes("mistral")) return 32_000;
  if (id.includes("claude") || id.includes("opus") || id.includes("sonnet")) return 200_000;
  if (id.includes("qwen") || id.includes("deepseek") || id.includes("kimi")) return 128_000;
  if (id.includes("gpt-5") || id.includes("gpt-4.1")) return 400_000;
  if (id.includes("gemini-2.5") || id.includes("gemini-3")) return 1_000_000;
  return DEFAULT_CONTEXT_WINDOW;
}

export function contextBudgetForModel(model = "", overrides = {}) {
  const contextWindow = positiveInteger(overrides.contextWindow) || estimateContextWindow(model);
  const inputBudget = positiveInteger(overrides.inputBudget)
    || Math.max(4_096, Math.floor(contextWindow * DEFAULT_INPUT_BUDGET_RATIO));
  const historyTokenBudget = positiveInteger(overrides.historyTokenBudget)
    || Math.max(2_048, Math.floor(inputBudget * DEFAULT_HISTORY_BUDGET_RATIO));
  const checkpointTokenBudget = positiveInteger(overrides.checkpointTokenBudget)
    || Math.max(512, Math.floor(inputBudget * DEFAULT_CHECKPOINT_BUDGET_RATIO));
  return {
    contextWindow,
    inputBudget,
    historyTokenBudget,
    checkpointTokenBudget,
    reservedTokenBudget: Math.max(0, contextWindow - inputBudget)
  };
}

export function truncateTextToTokenBudget(value, maxTokens, marker = "\n…[context compacted]…\n") {
  const text = String(value || "");
  const budget = Math.max(1, Number.parseInt(maxTokens, 10) || 1);
  if (estimateTextTokens(text) <= budget) return text;
  const markerTokens = estimateTextTokens(marker);
  const contentBudget = Math.max(2, budget - markerTokens);
  const headBudget = Math.ceil(contentBudget * 0.6);
  const tailBudget = Math.max(1, contentBudget - headBudget);
  return `${takeTokenPrefix(text, headBudget)}${marker}${takeTokenSuffix(text, tailBudget)}`;
}

function takeTokenPrefix(text, budget) {
  let result = "";
  let weight = 0;
  for (const character of String(text || "")) {
    const nextWeight = weight + characterTokenWeight(character);
    if (Math.ceil(nextWeight) > budget) break;
    result += character;
    weight = nextWeight;
  }
  return result;
}

function takeTokenSuffix(text, budget) {
  let result = "";
  let weight = 0;
  const characters = Array.from(String(text || ""));
  for (let index = characters.length - 1; index >= 0; index -= 1) {
    const nextWeight = weight + characterTokenWeight(characters[index]);
    if (Math.ceil(nextWeight) > budget) break;
    result = characters[index] + result;
    weight = nextWeight;
  }
  return result;
}

function characterTokenWeight(character) {
  return character.codePointAt(0) <= 0x7f ? 0.25 : (2 / 3);
}

function positiveInteger(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}
