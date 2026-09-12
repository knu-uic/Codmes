process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import {
  contextBudgetForModel,
  estimateContextWindow,
  estimateTextTokens,
  truncateTextToTokenBudget
} from "./context-budget.mjs";

test("context budgets reserve capacity according to the selected model", () => {
  const gemma = contextBudgetForModel("gemma4:12b-mlx");
  const large = contextBudgetForModel("qwen3.6:27b");

  assert.equal(estimateContextWindow("gemma4:12b-mlx"), 32_000);
  assert.equal(estimateContextWindow("qwen3.6:27b"), 128_000);
  assert.ok(gemma.inputBudget < gemma.contextWindow);
  assert.ok(gemma.reservedTokenBudget >= gemma.contextWindow * 0.3);
  assert.ok(large.historyTokenBudget > gemma.historyTokenBudget);
});

test("token estimation accounts for Korean text and compaction keeps both ends", () => {
  assert.ok(estimateTextTokens("가나다라마바") > estimateTextTokens("abcdef"));
  const compacted = truncateTextToTokenBudget(`START-${"x".repeat(4000)}-END`, 120);
  assert.match(compacted, /^START-/);
  assert.match(compacted, /-END$/);
  assert.match(compacted, /context compacted/);
  assert.ok(estimateTextTokens(compacted) <= 122);
});
