process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import {
  createCompactionState,
  planConversationCompaction,
  promptContextFromPlan
} from "./conversation-compaction.mjs";

function messages(count, size = 20) {
  return Array.from({ length: count }, (_, index) => ({
    id: `m${index + 1}`,
    role: index % 2 === 0 ? "user" : "assistant",
    content: `${index + 1}:${"x".repeat(size)}`
  }));
}

test("conversation compaction keeps every same-session message below the threshold", () => {
  const sessionMessages = messages(40);
  const plan = planConversationCompaction({ messages: sessionMessages }, {
    provider: "custom", model: "demo", contextWindow: 32_000
  });
  const context = promptContextFromPlan(plan);
  assert.equal(plan.shouldCompact, false);
  assert.equal(context.history.length, sessionMessages.length);
  assert.equal(context.summary, null);
});

test("conversation compaction keeps a token-bounded tail instead of a fixed message count", () => {
  const sessionMessages = messages(40, 1_000);
  const plan = planConversationCompaction({ messages: sessionMessages }, {
    provider: "custom", model: "demo", contextWindow: 4_000
  });
  assert.equal(plan.shouldCompact, true);
  assert.ok(plan.tail.length < 12);
  assert.deepEqual(plan.tail.map((message) => message.id), sessionMessages.slice(-plan.tail.length).map((message) => message.id));
});

test("a huge prior message may be compacted instead of being kept by a fixed-count rule", () => {
  const sessionMessages = [
    { id: "m1", role: "user", content: "old" },
    { id: "m2", role: "assistant", content: "x".repeat(20_000) }
  ];
  const plan = planConversationCompaction({ messages: sessionMessages }, {
    provider: "custom", model: "demo", contextWindow: 4_000
  });
  assert.equal(plan.shouldCompact, true);
  assert.equal(plan.nextCoveredMessageCount, 2);
  assert.deepEqual(plan.tail, []);
});

test("conversation compaction extends a compatible checkpoint instead of restarting", () => {
  const firstMessages = messages(40, 1_000);
  const firstPlan = planConversationCompaction({ messages: firstMessages }, {
    provider: "custom", model: "demo", contextWindow: 4_000
  });
  const firstState = createCompactionState(firstPlan, { mode: "summary", summary: "first semantic checkpoint" });
  const expandedMessages = [...firstMessages, ...messages(12, 1_000).map((message, index) => ({
    ...message, id: `n${index + 1}`
  }))];
  const secondPlan = planConversationCompaction({ messages: expandedMessages, contextCompaction: firstState }, {
    provider: "custom", model: "demo", contextWindow: 4_000
  });
  assert.equal(secondPlan.existingState, firstState);
  assert.equal(secondPlan.shouldCompact, true);
  assert.ok(secondPlan.nextCoveredMessageCount > firstState.coveredMessageCount);
  const secondState = createCompactionState(secondPlan, { mode: "summary", summary: "updated semantic checkpoint" });
  assert.equal(secondState.compactionCount, 2);
});

test("conversation compaction ignores checkpoints from another model", () => {
  const sessionMessages = messages(40, 1_000);
  const oldState = {
    version: 1,
    mode: "summary",
    provider: "custom",
    model: "old-model",
    coveredMessageCount: 20,
    coveredMessageIds: sessionMessages.slice(0, 20).map((message) => message.id),
    summary: "old state",
    tokenEstimate: 4
  };
  const plan = planConversationCompaction({ messages: sessionMessages, contextCompaction: oldState }, {
    provider: "custom", model: "new-model", contextWindow: 4_000
  });
  assert.equal(plan.existingState, null);
  assert.equal(plan.coveredMessageCount, 0);
});
