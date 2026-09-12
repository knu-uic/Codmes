import test from "node:test";
import assert from "node:assert/strict";
import {
  activeWorkspaceRoot,
  currentRequestContext,
  updateRequestContext,
  withRequestContext
} from "./request-context.mjs";

test("request contexts isolate concurrent workspace roots", async () => {
  const seen = await Promise.all([
    withRequestContext({ workspaceRoot: "/workspace/a", user: { id: "a" } }, async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      return [activeWorkspaceRoot("/fallback"), currentRequestContext().user.id];
    }),
    withRequestContext({ workspaceRoot: "/workspace/b", user: { id: "b" } }, async () => {
      updateRequestContext({ workspace: { id: "workspace-b" } });
      return [activeWorkspaceRoot("/fallback"), currentRequestContext().workspace.id];
    })
  ]);
  assert.deepEqual(seen, [
    ["/workspace/a", "a"],
    ["/workspace/b", "workspace-b"]
  ]);
  assert.equal(activeWorkspaceRoot("/fallback"), "/fallback");
});
