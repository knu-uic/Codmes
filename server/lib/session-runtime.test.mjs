process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { SessionRuntime } from "./session-runtime.mjs";

test("SessionRuntime token budget can retain more than twelve short same-session messages", () => {
  const runtime = new SessionRuntime({});
  const messages = Array.from({ length: 30 }, (_, index) => ({
    id: `short-${index + 1}`,
    role: index % 2 === 0 ? "user" : "assistant",
    content: `short message ${index + 1}`
  }));

  const context = runtime.promptContext({ model: "gemma4:12b-mlx", messages });

  assert.equal(context.history.length, 30);
  assert.equal(context.summary, null);
  assert.equal(context.stats.compactedMessageCount, 0);
});

test("SessionRuntime reuses a persisted model compaction and keeps uncovered messages verbatim", () => {
  const runtime = new SessionRuntime({});
  const messages = Array.from({ length: 30 }, (_, index) => ({
      id: `m${index + 1}`,
      role: index % 2 === 0 ? "assistant" : "user",
      content: `message-${index + 1}`
    }));
  const context = runtime.promptContext({
    provider: "custom",
    model: "demo",
    messages,
    contextCompaction: {
      version: 1,
      mode: "summary",
      provider: "custom",
      model: "demo",
      contextWindow: 4_000,
      thresholdTokens: 2_048,
      coveredMessageCount: 10,
      coveredMessageIds: messages.slice(0, 10).map((message) => message.id),
      tokenEstimate: 40,
      compactionCount: 1,
      summary: "Goal: preserve exact model-produced state.",
      updatedAt: "2026-09-11T00:00:00.000Z"
    }
  }, {
    provider: "custom", model: "demo", contextWindow: 4_000
  });

  assert.equal(context.history.length, 20);
  assert.equal(context.history[0].content, "message-11");
  assert.match(context.summary.content, /model-produced state/);
  assert.equal(context.stats.compactedMessageCount, 10);
});

test("SessionRuntime keeps selected notice images with the chat and removes them on delete", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-session-assets-"));
  const sessionsDirectory = path.join(root, "sessions");
  await fs.mkdir(sessionsDirectory, { recursive: true });
  const sessionId = "session-assets-1";
  await fs.writeFile(path.join(sessionsDirectory, `${sessionId}.json`), JSON.stringify({ id: sessionId }), "utf8");
  const server = http.createServer((req, res) => {
    if (req.url !== "/api/notice-assets/118/content") return res.writeHead(404).end();
    res.writeHead(200, { "content-type": "image/png" });
    res.end(Buffer.from("fake-png"));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const runtime = new SessionRuntime({
    stateStore: { root, workspaceRoot: root }
  });

  try {
    const localized = await runtime.localizeSessionImages(
      sessionId,
      `화면입니다.\n![그림](http://127.0.0.1:${port}/api/notice-assets/118/content)`
    );
    assert.match(localized, new RegExp(`/api/sessions/${sessionId}/assets/[a-f0-9]{24}\\.png`));
    const usage = await runtime.storageUsage();
    assert.equal(usage.sessionCount, 1);
    assert.equal(usage.assetCount, 1);
    assert.ok(await runtime.sessionStorageBytes(sessionId) > Buffer.byteLength(JSON.stringify({ id: sessionId })));

    await runtime.deleteSession(sessionId);
    assert.equal((await runtime.storageUsage()).assetCount, 0);
  } finally {
    server.close();
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("SessionRuntime localizes selected Notes document images", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-document-session-assets-"));
  const sessionsDirectory = path.join(root, "sessions");
  await fs.mkdir(sessionsDirectory, { recursive: true });
  const sessionId = "session-document-assets-1";
  await fs.writeFile(path.join(sessionsDirectory, `${sessionId}.json`), JSON.stringify({ id: sessionId }), "utf8");
  const server = http.createServer((req, res) => {
    if (req.url !== "/api/document-assets/study--12345678/figure-p0001-test.png") return res.writeHead(404).end();
    res.writeHead(200, { "content-type": "image/png" });
    res.end(Buffer.from("notes-figure-png"));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const runtime = new SessionRuntime({ stateStore: { root, workspaceRoot: root } });

  try {
    const localized = await runtime.localizeSessionImages(
      sessionId,
      `계층도입니다.\n![DBMS 계층도](http://127.0.0.1:${port}/api/document-assets/study--12345678/figure-p0001-test.png)`
    );
    assert.match(localized, new RegExp(`/api/sessions/${sessionId}/assets/[a-f0-9]{24}\\.png`));
    assert.equal((await runtime.storageUsage()).assetCount, 1);
  } finally {
    server.close();
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("SessionRuntime copies authenticated document assets directly from its workspace", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-local-document-assets-"));
  const sessionId = "session-local-assets-1";
  const source = path.join(root, ".codmes", "documents", "study--12345678", "index", "images", "figure.png");
  await fs.mkdir(path.dirname(source), { recursive: true });
  await fs.writeFile(source, Buffer.from("private-workspace-image"));
  const runtime = new SessionRuntime({ stateStore: { root, workspaceRoot: root } });
  try {
    const localized = await runtime.localizeSessionImages(
      sessionId,
      "![그림](http://127.0.0.1:8787/api/document-assets/study--12345678/figure.png)"
    );
    assert.match(localized, new RegExp(`/api/sessions/${sessionId}/assets/[a-f0-9]{24}\\.png`));
    assert.equal((await runtime.storageUsage()).assetCount, 1);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
