process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { indexSession, readConversationMessages, removeSessionFromConversationIndex, searchConversationIndex } from "./conversation-index.mjs";
import { executeConversationSearch, executeConversationRead } from "./conversation-tools.mjs";

test("Conversation Tools: index, search and read", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conversation-tools-"));
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });
  
  const mockSession = {
    id: "session-123",
    title: "macbook setup",
    kind: "general",
    surface: "chat",
    updatedAt: new Date().toISOString(),
    createdAt: new Date().toISOString(),
    summary: {
      content: "Setting up clamshell mode on macOS.",
      coveredMessageIds: ["1", "2"]
    },
    messages: [
      { role: "user", content: "macbook clamshell mode setup" },
      { role: "assistant", content: "To setup clamshell mode, connect an external display and keyboard." }
    ]
  };
  
  // Write actual session JSON to state root so conversation_read can find it
  await fs.writeFile(
    path.join(root, ".codmes", "sessions", "session-123.json"),
    JSON.stringify(mockSession, null, 2),
    "utf8"
  );
  
  // Index it
  await indexSession(root, mockSession);
  
  // Search
  const searchResult = await executeConversationSearch(root, {
    query: "clamshell"
  });
  
  assert.ok(searchResult.results.length > 0);
  assert.equal(searchResult.results[0].sessionId, "session-123");
  
  // Read
  const readResult = await executeConversationRead(root, {
    sessionId: "session-123",
    messageIds: ["1"],
    includeSurroundingMessages: true,
    surroundingWindow: 1
  });
  
  assert.equal(readResult.sessionId, "session-123");
  assert.ok(readResult.messages.length > 0);
  assert.ok(readResult.messages.some(m => m.content.includes("clamshell")));
});

test("Conversation Tools: deleting an index entry removes its messages and summary", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conversation-delete-"));
  const session = {
    id: "deleted-session",
    title: "Deleted conversation",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    summary: { content: "unique-deleted-summary" },
    messages: [{ id: "u1", role: "user", content: "unique-deleted-message" }]
  };
  await indexSession(root, session);
  assert.ok((await searchConversationIndex(root, "unique-deleted")).length > 0);
  await removeSessionFromConversationIndex(root, session.id);
  assert.deepEqual(await searchConversationIndex(root, "unique-deleted"), []);
});

test("Conversation Tools: fuzzy keyword recall does not require exact phrase match", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conversation-fuzzy-"));
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });

  const session = {
    id: "session-music",
    title: "음악 이야기",
    kind: "general",
    createdAt: "2026-07-07T12:00:00+09:00",
    updatedAt: "2026-07-07T12:30:00+09:00",
    messages: [
      { id: "u1", role: "user", content: "지난주에 재즈 음악을 들었다", createdAt: "2026-07-07T12:00:00+09:00" },
      { id: "a1", role: "assistant", content: "재즈 플레이리스트를 기억해둘게요.", createdAt: "2026-07-07T12:01:00+09:00" }
    ],
    summary: {
      content: "사용자는 지난주 재즈 음악을 들었다.",
      coveredMessageIds: ["u1", "a1"],
      updatedAt: "2026-07-07T12:30:00+09:00"
    }
  };

  await fs.writeFile(
    path.join(root, ".codmes", "sessions", "session-music.json"),
    JSON.stringify(session, null, 2),
    "utf8"
  );
  await indexSession(root, session);

  const result = await executeConversationSearch(root, {
    query: "저번주에 내가 들었던 음악 뭐였지?",
    maxResults: 5
  });

  assert.equal(result.results.length > 0, true);
  assert.equal(result.results[0].sessionId, "session-music");
  assert.ok(result.results.some((item) => /재즈|음악/.test(item.summary || item.snippet || "")));
});

test("Conversation Tools: last_week is previous calendar week and last_7_days is rolling", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conversation-time-"));
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });

  const sessions = [
    {
      id: "previous-calendar-week",
      title: "Previous week",
      createdAt: "2026-07-07T10:00:00+09:00",
      updatedAt: "2026-07-07T10:00:00+09:00",
      messages: [
        { id: "p1", role: "user", content: "calendar-week-only keyword", createdAt: "2026-07-07T10:00:00+09:00" }
      ]
    },
    {
      id: "rolling-week",
      title: "Rolling week",
      createdAt: "2026-07-10T10:00:00+09:00",
      updatedAt: "2026-07-10T10:00:00+09:00",
      messages: [
        { id: "r1", role: "user", content: "rolling keyword", createdAt: "2026-07-10T10:00:00+09:00" }
      ]
    },
    {
      id: "this-week",
      title: "This week",
      createdAt: "2026-07-14T10:00:00+09:00",
      updatedAt: "2026-07-14T10:00:00+09:00",
      messages: [
        { id: "t1", role: "user", content: "this week keyword", createdAt: "2026-07-14T10:00:00+09:00" }
      ]
    }
  ];

  for (const session of sessions) {
    await fs.writeFile(
      path.join(root, ".codmes", "sessions", `${session.id}.json`),
      JSON.stringify(session, null, 2),
      "utf8"
    );
    await indexSession(root, session);
  }

  const now = "2026-07-15T12:00:00+09:00";
  const lastWeek = await searchConversationIndex(root, "keyword", {
    timeRange: "last_week",
    now,
    maxResults: 10
  });
  assert.deepEqual(
    lastWeek.map((item) => item.sessionId).sort(),
    ["previous-calendar-week", "rolling-week"]
  );

  const last7Days = await searchConversationIndex(root, "keyword", {
    timeRange: "last_7_days",
    now,
    maxResults: 10
  });
  assert.deepEqual(
    last7Days.map((item) => item.sessionId).sort(),
    ["rolling-week", "this-week"]
  );
});

test("Conversation Tools: read surrounding messages preserves message ids and removes overlap duplicates", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conversation-read-"));
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });

  const session = {
    id: "session-read",
    title: "Read windows",
    messages: [
      { id: "m-a", role: "user", content: "one" },
      { id: "m-b", role: "assistant", content: "two" },
      { id: "m-c", role: "user", content: "three" },
      { id: "m-d", role: "assistant", content: "four" }
    ]
  };
  await fs.writeFile(
    path.join(root, ".codmes", "sessions", "session-read.json"),
    JSON.stringify(session, null, 2),
    "utf8"
  );

  const read = await readConversationMessages(root, "session-read", ["m-b", "m-c"], {
    includeSurroundingMessages: true,
    surroundingWindow: 1
  });

  assert.deepEqual(read.messages.map((message) => message.id), ["m-a", "m-b", "m-c", "m-d"]);
  assert.equal(read.messages.filter((message) => message.id === "m-b").length, 1);
  assert.equal(read.messages.filter((message) => message.isTarget).length, 2);
});

test("Conversation Tools: archived sessions are hidden unless includeArchived is true", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conversation-archived-"));
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });

  const session = {
    id: "session-archived",
    title: "Archived chat",
    kind: "general",
    createdAt: "2026-07-01T10:00:00+09:00",
    updatedAt: "2026-07-01T10:00:00+09:00",
    archivedAt: "2026-07-02T10:00:00+09:00",
    archiveReason: "general_chat_overflow_30",
    visibleInSidebar: false,
    searchable: true,
    messages: [
      { id: "a1", role: "user", content: "archived keyword", createdAt: "2026-07-01T10:00:00+09:00" }
    ],
    summary: {
      content: "Archived keyword summary.",
      coveredMessageIds: ["a1"],
      updatedAt: "2026-07-01T10:00:00+09:00"
    }
  };
  await fs.writeFile(
    path.join(root, ".codmes", "sessions", "session-archived.json"),
    JSON.stringify(session, null, 2),
    "utf8"
  );
  await indexSession(root, session);

  const hidden = await executeConversationSearch(root, {
    query: "archived keyword"
  });
  assert.equal(hidden.results.length, 0);

  const visible = await executeConversationSearch(root, {
    query: "archived keyword",
    includeArchived: true
  });
  assert.equal(visible.results.length > 0, true);
  assert.equal(visible.results[0].archived, true);
  assert.equal(visible.results[0].archiveReason, "general_chat_overflow_30");
});
