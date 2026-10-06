import test from "node:test";
import assert from "node:assert/strict";
import { waitForReadiness, ReadinessTimeoutError, ReadinessCancelledError } from "../src/auth-readiness.ts";

function clock() {
  let time = 0;
  return { now: () => time, wait: async milliseconds => { time += milliseconds; } };
}

test("ready server proceeds immediately without manual refresh", async () => {
  let calls = 0;
  const result = await waitForReadiness(async () => { calls++; return "login"; }, { isCurrent: () => true });
  assert.equal(result, "login");
  assert.equal(calls, 1);
});

test("cold startup retries transient failures and automatically reaches login", async () => {
  let calls = 0;
  const timing = clock();
  const result = await waitForReadiness(async () => {
    if (++calls < 4) throw new Error("connection refused");
    return { bootstrapRequired: false };
  }, { isCurrent: () => true, ...timing });
  assert.deepEqual(result, { bootstrapRequired: false });
  assert.equal(calls, 4);
  assert.equal(timing.now(), 3000);
});

test("persistent startup failure stops polling at its deadline and retains diagnostics", async () => {
  const failure = new Error("server unavailable");
  const timing = clock();
  let calls = 0;
  await assert.rejects(waitForReadiness(async () => { calls++; throw failure; }, {
    isCurrent: () => true, timeoutMs: 2500, intervalMs: 1000, ...timing,
  }), error => error instanceof ReadinessTimeoutError && error.lastError === failure);
  assert.equal(timing.now(), 2500);
  assert.equal(calls, 3);
});

test("obsolete auth screen cannot overwrite a newer screen after a successful probe", async () => {
  let current = true;
  await assert.rejects(waitForReadiness(async () => { current = false; return "old login"; }, {
    isCurrent: () => current,
  }), ReadinessCancelledError);
});

test("cancelling startup polling prevents further probes", async () => {
  let current = true;
  let calls = 0;
  await assert.rejects(waitForReadiness(async () => { calls++; throw new Error("not ready"); }, {
    isCurrent: () => current, wait: async () => { current = false; },
  }), ReadinessCancelledError);
  assert.equal(calls, 1);
});
