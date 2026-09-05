process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  approveMemoryCandidate,
  MEMORY_SEARCH_DEFINITION,
  listMemoryCandidates,
  readMemoryById,
  recordDeletedMemoryTombstone,
  searchMemory,
  updateMemoryFromSession
} from "./memory-retrieval.mjs";

test("Memory Retrieval: tool contract excludes current external-service state", () => {
  assert.match(
    MEMORY_SEARCH_DEFINITION.function.description,
    /Never use this for current external-service state/
  );
});

test("Memory Retrieval: search across memory pools", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-memory-retrieval-"));
  await fs.mkdir(path.join(root, ".codmes", "memory", "user"), { recursive: true });
  await fs.mkdir(path.join(root, ".codmes", "memory", "folders"), { recursive: true });
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });
  
  // 1. User memory
  await fs.writeFile(
    path.join(root, ".codmes", "memory", "user", "memories.jsonl"),
    JSON.stringify({ content: "User has a MacBook Pro 16 inch.", pinned: true, createdAt: new Date().toISOString() }) + "\n",
    "utf8"
  );
  
  // 2. Folder memory
  await fs.writeFile(
    path.join(root, ".codmes", "memory", "folders", "folder-computer.json"),
    JSON.stringify([{ content: "Computer folder: local LLM setup.", pinned: false, createdAt: new Date().toISOString() }]),
    "utf8"
  );
  
  // Search without folder ID
  const search1 = await searchMemory(root, "macbook");
  assert.equal(search1.length, 1);
  assert.equal(search1[0].type, "user_memory");
  
  // Search with folder ID (computer)
  const search2 = await searchMemory(root, "local LLM", {
    currentFolderId: "computer"
  });
  
  assert.equal(search2.length, 1);
  assert.equal(search2[0].type, "folder_memory");
  assert.equal(search2[0].folderId, "computer");
});

test("Memory Retrieval: update pipeline saves scoped memories and reviews user memory by default", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-memory-update-"));
  const session = {
    id: "session-memory",
    projectId: "project-alpha",
    folderId: "folder-notes",
    createdAt: "2026-07-08T10:00:00+09:00",
    summary: {
      content: "주제: Codmes, RAG\n결정: Codmes Search를 공식 검색 경로로 사용한다\n선호: 사용자는 다크 모드 UI를 좋아한다",
      coveredMessageIds: ["u1", "a1"],
      updatedAt: "2026-07-08T10:05:00+09:00"
    },
    messages: [
      { id: "u1", role: "user", content: "나는 다크 모드 UI를 좋아해" },
      { id: "a1", role: "assistant", content: "기억해둘게요." }
    ]
  };

  const result = await updateMemoryFromSession(root, session);
  assert.equal(result.saved.length, 3);
  assert.equal(result.candidates.length, 1);
  assert.ok(result.saved.every((memory) => memory.sourceSessionIds.includes("session-memory")));
  assert.ok(result.saved.every((memory) => memory.sourceMessageIds.includes("u1")));

  const pending = await listMemoryCandidates(root);
  const userCandidate = pending.find((memory) => memory.type === "user_memory");
  assert.ok(userCandidate);
  assert.match(userCandidate.content, /다크 모드/);
  const approved = await approveMemoryCandidate(root, userCandidate.id);
  const loaded = await readMemoryById(root, approved.memory.id);
  assert.equal(loaded.id, approved.memory.id);

  const projectSearch = await searchMemory(root, "Codmes Search", {
    currentProjectId: "project-alpha",
    maxResults: 10
  });
  assert.equal(projectSearch.some((memory) => memory.type === "project_memory"), true);

  const folderSearch = await searchMemory(root, "Codmes", {
    currentFolderId: "folder-notes",
    maxResults: 10
  });
  assert.equal(folderSearch.some((memory) => memory.type === "folder_memory"), true);
});

test("Memory Retrieval: duplicate content merges sources and deleted memories are not regenerated", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-memory-merge-delete-"));
  const first = {
    id: "s1",
    createdAt: "2026-07-08T10:00:00+09:00",
    summary: {
      content: "선호: 사용자는 compact UI를 선호한다",
      updatedAt: "2026-07-08T10:01:00+09:00"
    },
    messages: [{ id: "u1", role: "user", content: "compact UI를 선호한다" }]
  };
  const second = {
    ...first,
    id: "s2",
    messages: [{ id: "u2", role: "user", content: "compact UI를 선호한다" }]
  };

  await updateMemoryFromSession(root, first, {
    memorySettings: { autoSaveUserMemory: true, memoryReviewRequired: false }
  });
  await updateMemoryFromSession(root, second, {
    memorySettings: { autoSaveUserMemory: true, memoryReviewRequired: false }
  });

  const results = await searchMemory(root, "compact UI", { maxResults: 10 });
  const userMemory = results.find((item) => item.type === "user_memory");
  assert.ok(userMemory);
  assert.deepEqual(userMemory.sourceSessionIds.sort(), ["s1", "s2"]);

  await recordDeletedMemoryTombstone(root, userMemory, "user_deleted");
  const third = await updateMemoryFromSession(root, {
    ...first,
    id: "s3",
    messages: [{ id: "u3", role: "user", content: "compact UI를 선호한다" }]
  }, {
    memorySettings: { autoSaveUserMemory: true, memoryReviewRequired: false }
  });
  assert.equal(third.saved.some((item) => item.type === "user_memory"), false);
  assert.equal(third.blocked.some((item) => item.reason === "matches_deleted_memory_tombstone"), true);
});
