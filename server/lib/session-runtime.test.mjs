process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { buildSessionSummary, SessionRuntime } from "./session-runtime.mjs";

test("SessionRuntime summary captures topics, decisions, preferences, entities, and covered ids", () => {
  const summary = buildSessionSummary({
    id: "session-summary",
    messages: [
      { id: "u1", role: "user", content: "Codmes 방향은 Hermes wrapper가 아니라 독립 런타임으로 가기로 결정했어." },
      { id: "a1", role: "assistant", content: "좋아요. Codmes Search와 RAG를 내부 경로로 정리하겠습니다." },
      { id: "u2", role: "user", content: "나는 Codex 스타일 UI를 좋아하고 Obsidian처럼 보여주길 원해." }
    ]
  });

  assert.ok(summary.content);
  assert.equal(summary.content.includes("Conversation starting with"), false);
  assert.ok(summary.topics.includes("Codmes"));
  assert.ok(summary.entities.includes("Codmes"));
  assert.ok(summary.entities.includes("Obsidian"));
  assert.ok(summary.decisions.some((item) => /결정/.test(item)));
  assert.ok(summary.preferences.some((item) => /좋아|원해/.test(item)));
  assert.deepEqual(summary.coveredMessageIds, ["u1", "a1", "u2"]);
  assert.deepEqual(summary.sourceMessageIds, ["u1", "a1", "u2"]);
});

test("SessionRuntime promptHistory returns recent visible user and assistant turns only", () => {
  const runtime = new SessionRuntime({});
  const history = runtime.promptHistory({
    messages: [
      { role: "system", content: "hidden" },
      { role: "tool", content: "tool output" },
      { role: "user", content: "one" },
      { role: "assistant", content: "two" },
      { role: "user", content: "three" }
    ]
  }, { recentLimit: 2 });

  assert.deepEqual(history, [
    { role: "assistant", content: "two" },
    { role: "user", content: "three" }
  ]);
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
