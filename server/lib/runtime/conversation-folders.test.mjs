process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  listFolders,
  createFolder,
  updateFolder,
  deleteFolder,
  getFolderMemory,
  updateFolderMemory,
  moveSessionToFolder,
  setSessionPinned
} from "./conversation-folders.mjs";

test("Conversation Folders: CRUD and memory settings", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conv-folders-"));
  await fs.mkdir(path.join(root, ".codmes", "sessions"), { recursive: true });
  
  // 1. Create
  const folder = await createFolder(root, { name: "Music", icon: "music", color: "pink" });
  assert.equal(folder.name, "Music");
  assert.equal(folder.icon, "music");
  
  // 2. List
  const folders = await listFolders(root);
  assert.equal(folders.length, 1);
  
  // 3. Update
  const updated = await updateFolder(root, folder.id, { name: "Jazz" });
  assert.equal(updated.name, "Jazz");
  
  // 4. Memory
  const mem = await getFolderMemory(root, folder.id);
  assert.equal(mem.length, 0);
  
  await updateFolderMemory(root, folder.id, [{ content: "I love wave to earth." }]);
  const updatedMem = await getFolderMemory(root, folder.id);
  assert.equal(updatedMem.length, 1);
  assert.equal(updatedMem[0].content, "I love wave to earth.");
  
  // 5. Delete
  await deleteFolder(root, folder.id);
  const foldersPost = await listFolders(root);
  assert.equal(foldersPost.length, 0);
});

test("Conversation Folders: sessions can be moved into and out of folders", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-conv-folder-session-"));
  const sessionsDir = path.join(root, ".codmes", "sessions");
  await fs.mkdir(sessionsDir, { recursive: true });

  const folder = await createFolder(root, { name: "Project Alpha" });
  const sessionId = "session-test-folder";
  await fs.writeFile(path.join(sessionsDir, `${sessionId}.json`), JSON.stringify({
    id: sessionId,
    title: "Planning chat",
    messages: [],
    createdAt: new Date().toISOString()
  }, null, 2), "utf8");

  const moved = await moveSessionToFolder(root, sessionId, folder.id);
  assert.equal(moved.folderId, folder.id);
  assert.equal(moved.kind, "folder");

  const stored = JSON.parse(await fs.readFile(path.join(sessionsDir, `${sessionId}.json`), "utf8"));
  assert.equal(stored.folderId, folder.id);
  assert.equal(stored.kind, "folder");

  const unassigned = await moveSessionToFolder(root, sessionId, null);
  assert.equal(unassigned.folderId, null);
  assert.equal(unassigned.projectId, null);
  assert.equal(unassigned.kind, "general");

  const movedToProject = await moveSessionToFolder(
    root,
    sessionId,
    null,
    "/workspace/hermes-connection",
    "hermes-connection"
  );
  assert.equal(movedToProject.folderId, null);
  assert.equal(movedToProject.projectId, "/workspace/hermes-connection");
  assert.equal(movedToProject.projectTitle, "hermes-connection");
  assert.equal(movedToProject.kind, "project");

  const movedFromProjectToFolder = await moveSessionToFolder(root, sessionId, folder.id);
  assert.equal(movedFromProjectToFolder.folderId, folder.id);
  assert.equal(movedFromProjectToFolder.projectId, null);
  assert.equal(movedFromProjectToFolder.projectTitle, null);

  const pinned = await setSessionPinned(root, sessionId, true);
  assert.equal(pinned.pinned, true);
  const pinnedStored = JSON.parse(await fs.readFile(path.join(sessionsDir, `${sessionId}.json`), "utf8"));
  assert.equal(pinnedStored.pinned, true);

  const unpinned = await setSessionPinned(root, sessionId, false);
  assert.equal(unpinned.pinned, false);
});
