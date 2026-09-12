import {
  estimateMessageTokens,
  estimateMessagesTokens,
  estimateTextTokens
} from "./context-budget.mjs";

export const CONVERSATION_COMPACTION_VERSION = 1;
export const DEFAULT_COMPACTION_THRESHOLD_RATIO = 0.5;
export const DEFAULT_COMPACTION_TARGET_RATIO = 0.2;
export const DEFAULT_PROTECTED_TAIL_MESSAGES = 0;

export function planConversationCompaction(session = {}, options = {}) {
  const messages = visibleMessages(session.messages);
  const provider = String(options.provider || "");
  const model = String(options.model || session.model || "");
  const contextWindow = positiveInteger(options.contextWindow) || 128_000;
  const thresholdRatio = ratio(options.thresholdRatio, DEFAULT_COMPACTION_THRESHOLD_RATIO);
  const targetRatio = ratio(options.targetRatio, DEFAULT_COMPACTION_TARGET_RATIO);
  const protectLastN = nonNegativeInteger(options.protectLastN, DEFAULT_PROTECTED_TAIL_MESSAGES);
  const thresholdTokens = Math.max(2_048, Math.floor(contextWindow * thresholdRatio));
  const targetTailTokens = Math.max(512, Math.floor(thresholdTokens * targetRatio));
  const existing = compatibleState(session.contextCompaction, { provider, model, messageCount: messages.length });
  const coveredMessageCount = existing?.coveredMessageCount || 0;
  const uncovered = messages.slice(coveredMessageCount);
  const effectiveTokenEstimate = stateTokenEstimate(existing) + estimateMessagesTokens(uncovered);

  const base = {
    messages,
    provider,
    model,
    contextWindow,
    thresholdTokens,
    targetTailTokens,
    protectLastN,
    existingState: existing,
    coveredMessageCount,
    effectiveTokenEstimate
  };

  if (effectiveTokenEstimate < thresholdTokens) {
    return { ...base, shouldCompact: false, reason: "below_threshold", tail: uncovered };
  }

  const tokenTailStart = tokenBoundedTailStart(messages, targetTailTokens);
  const protectedTailStart = Math.max(0, messages.length - protectLastN);
  const nextCoveredMessageCount = Math.max(
    coveredMessageCount,
    Math.min(tokenTailStart, protectedTailStart)
  );
  if (nextCoveredMessageCount <= coveredMessageCount) {
    return { ...base, shouldCompact: false, reason: "protected_tail", tail: uncovered };
  }

  return {
    ...base,
    shouldCompact: true,
    reason: "threshold_reached",
    nextCoveredMessageCount,
    messagesToCompact: messages.slice(coveredMessageCount, nextCoveredMessageCount),
    tail: messages.slice(nextCoveredMessageCount),
    coveredMessageIds: messages
      .slice(0, nextCoveredMessageCount)
      .map((message, index) => messageId(message, index))
  };
}

export function promptContextFromPlan(plan, state = plan?.existingState || null) {
  const coveredMessageCount = state?.coveredMessageCount || 0;
  const history = (plan?.messages || [])
    .slice(coveredMessageCount)
    .map((message) => ({ role: message.role, content: String(message.content || "") }));
  const summary = state?.mode === "summary" && state.summary
    ? {
        content: state.summary,
        coveredMessageIds: state.coveredMessageIds || [],
        lastSummarizedMessageId: state.coveredMessageIds?.at(-1) || null,
        updatedAt: state.updatedAt
      }
    : null;
  const nativeCompaction = state?.mode === "native" && Array.isArray(state.output)
    ? { output: state.output, provider: state.provider, model: state.model }
    : null;
  return {
    history,
    fallbackHistory: (plan?.messages || []).map((message) => ({
      role: message.role,
      content: String(message.content || "")
    })),
    summary,
    nativeCompaction,
    state,
    stats: {
      contextWindow: plan?.contextWindow || state?.contextWindow || 0,
      thresholdTokens: plan?.thresholdTokens || state?.thresholdTokens || 0,
      effectiveTokenEstimate: plan?.effectiveTokenEstimate || estimateMessagesTokens(history),
      recentMessageCount: history.length,
      compactedMessageCount: coveredMessageCount,
      compactionMode: state?.mode || "none",
      compactionCount: state?.compactionCount || 0
    }
  };
}

export function createCompactionState(plan, compacted = {}) {
  const mode = compacted.mode === "native" ? "native" : "summary";
  const output = mode === "native" && Array.isArray(compacted.output) ? compacted.output : undefined;
  const summary = mode === "summary" ? String(compacted.summary || "").trim() : undefined;
  if (mode === "native" && !output?.length) throw new Error("Native compaction returned no output items.");
  if (mode === "summary" && !summary) throw new Error("Auxiliary compaction returned an empty summary.");
  const previousCount = plan.existingState?.compactionCount || 0;
  const state = {
    version: CONVERSATION_COMPACTION_VERSION,
    mode,
    provider: plan.provider,
    model: plan.model,
    contextWindow: plan.contextWindow,
    thresholdTokens: plan.thresholdTokens,
    coveredMessageCount: plan.nextCoveredMessageCount,
    coveredMessageIds: plan.coveredMessageIds,
    tokenEstimate: mode === "native"
      ? estimateTextTokens(JSON.stringify(output))
      : estimateTextTokens(summary),
    compactionCount: previousCount + 1,
    updatedAt: new Date().toISOString()
  };
  if (output) state.output = output;
  if (summary) state.summary = summary;
  return state;
}

export function compactionTranscript(plan) {
  const parts = [];
  if (plan?.existingState?.mode === "summary" && plan.existingState.summary) {
    parts.push("PREVIOUS COMPACTED STATE:\n" + plan.existingState.summary);
  }
  const messages = plan?.existingState?.mode === "native"
    ? plan.messages.slice(0, plan.nextCoveredMessageCount)
    : plan?.messagesToCompact;
  if (messages?.length) {
    parts.push("NEW CONVERSATION TO COMPACT:\n" + messages
      .map((message) => `${message.role.toUpperCase()}: ${String(message.content || "")}`)
      .join("\n\n"));
  }
  return parts.join("\n\n");
}

function compatibleState(value, expected) {
  if (!value || value.version !== CONVERSATION_COMPACTION_VERSION) return null;
  if (String(value.provider || "") !== expected.provider || String(value.model || "") !== expected.model) return null;
  const count = positiveInteger(value.coveredMessageCount);
  if (!count || count > expected.messageCount) return null;
  if (value.mode === "native" && !Array.isArray(value.output)) return null;
  if (value.mode === "summary" && !String(value.summary || "").trim()) return null;
  return value;
}

function stateTokenEstimate(state) {
  if (!state) return 0;
  if (positiveInteger(state.tokenEstimate)) return positiveInteger(state.tokenEstimate);
  if (state.mode === "native") return estimateTextTokens(JSON.stringify(state.output || []));
  return estimateTextTokens(state.summary || "");
}

function tokenBoundedTailStart(messages, tokenBudget) {
  let used = 0;
  let start = messages.length;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const tokens = estimateMessageTokens(messages[index]);
    if (used + tokens > tokenBudget) break;
    used += tokens;
    start = index;
  }
  return start;
}

function nonNegativeInteger(value, fallback = 0) {
  if (value === undefined || value === null || value === "") return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function visibleMessages(messages) {
  return (Array.isArray(messages) ? messages : [])
    .filter((message) => message?.role === "user" || message?.role === "assistant");
}

function messageId(message, index) {
  return String(message?.id || index + 1);
}

function positiveInteger(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function ratio(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 && number < 1 ? number : fallback;
}
