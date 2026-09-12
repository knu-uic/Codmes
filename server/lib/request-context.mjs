import { AsyncLocalStorage } from "node:async_hooks";

const storage = new AsyncLocalStorage();

export function withRequestContext(context, callback) {
  return storage.run({ ...context }, callback);
}

export function currentRequestContext() {
  return storage.getStore() || null;
}

export function updateRequestContext(values) {
  const current = storage.getStore();
  if (!current) throw new Error("No active Codmes request context.");
  Object.assign(current, values);
  return current;
}

export function activeWorkspaceRoot(fallback) {
  return storage.getStore()?.workspaceRoot || fallback;
}
