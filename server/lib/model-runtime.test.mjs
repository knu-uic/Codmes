import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { ModelRuntime } from "./model-runtime.mjs";
import { setDefaultModel } from "./runtime/config-store.mjs";

test("listModels merges live Ollama chat models into the chat picker registry", async () => {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-model-runtime-"));
  try {
    await setDefaultModel(workspaceRoot, "ollama-local", "gemma4:12b-mlx");
    const runtime = new ModelRuntime({
      workspaceRoot,
      discoverOllama: async () => ({
        provider: "ollama-local",
        source: "ollama",
        models: ["qwen3.6:27b", "gemma4:12b-mlx", "gemma4:e2b-mlx"]
      })
    });

    const result = await runtime.listModels();
    assert.deepEqual(
      result.models.filter((item) => item.provider === "ollama-local").map((item) => item.id),
      ["ollama-local:gemma4:12b-mlx", "ollama-local:qwen3.6:27b", "ollama-local:gemma4:e2b-mlx"]
    );
    assert.equal(result.models.find((item) => item.id === "ollama-local:gemma4:12b-mlx").isActive, true);
  } finally {
    await fs.rm(workspaceRoot, { recursive: true, force: true });
  }
});

test("listModels keeps the configured registry available when Ollama is stopped", async () => {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-model-runtime-"));
  try {
    await setDefaultModel(workspaceRoot, "ollama-local", "offline-model");
    const runtime = new ModelRuntime({
      workspaceRoot,
      discoverOllama: async () => { throw new Error("offline"); }
    });
    const result = await runtime.listModels();
    assert.ok(result.models.some((item) => item.id === "ollama-local:offline-model"));
  } finally {
    await fs.rm(workspaceRoot, { recursive: true, force: true });
  }
});
