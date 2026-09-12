import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { estimateContextWindow } from "./runtime/context-budget.mjs";
import {
  planConversationCompaction,
  promptContextFromPlan
} from "./runtime/conversation-compaction.mjs";

function parseThinkTags(str) {
  let text = "";
  let reasoning = "";
  let cursor = 0;
  
  while (cursor < str.length) {
    const openIdx = str.indexOf("<think>", cursor);
    if (openIdx === -1) {
      text += str.slice(cursor);
      break;
    }
    
    text += str.slice(cursor, openIdx);
    
    const closeIdx = str.indexOf("</think>", openIdx);
    if (closeIdx === -1) {
      reasoning += str.slice(openIdx + 7);
      break;
    }
    
    reasoning += str.slice(openIdx + 7, closeIdx);
    cursor = closeIdx + 8;
    
    while (cursor < str.length && /\s/.test(str[cursor])) {
      cursor++;
    }
  }
  
  return { text, reasoning };
}

export class SessionRuntime {
  constructor({ runtime, stateStore }) {
    this.runtime = runtime;
    this.stateStore = stateStore;
  }

  async listSessions(limit = 200, options = {}) {
    let workspaceSessions = [];
    if (this.stateStore) {
      try {
        const { archiveOverflowGeneralSessions } = await import("./runtime/session-archive.mjs");
        await archiveOverflowGeneralSessions(this.stateStore.workspaceRoot, {
          limit: options.generalVisibleLimit || 30
        });
        workspaceSessions = await this.stateStore.listWorkspaceSessions();
      } catch {}
    }

    const seen = new Set();
    const merged = [];

    for (const s of workspaceSessions) {
      if (s.id && !seen.has(s.id)) {
        seen.add(s.id);
        
        // Archive/Sidebar filtering
        if (!options.includeArchived && s.visibleInSidebar === false) {
          continue;
        }
        if (options.folderId && s.folderId !== options.folderId) {
          continue;
        }
        if (options.projectId && s.projectId !== options.projectId) {
          continue;
        }

        const repairedTitle = repairedSessionTitle(s);
        if (repairedTitle && repairedTitle !== s.title) {
          s.title = repairedTitle;
          try {
            s.updatedAt = s.updatedAt || new Date().toISOString();
            await this.stateStore.writeSession(s);
          } catch {}
        }

        merged.push({
          ...s,
          storageBytes: await this.sessionStorageBytes(s.id),
          source: "workspace",
          runtime: "chat-runtime"
        });
      }
    }

    return {
      sessions: merged.slice(0, limit)
    };
  }

  async getSessionMessages(sessionId) {
    if (this.stateStore) {
      try {
        const session = await this.stateStore.readSession(sessionId);
        if (session && Array.isArray(session.messages)) {
          await this.reconcileFinalizedAssistantMessages(session);
          await this.localizeStoredSessionImages(session);
          return {
            sessionId,
            messages: session.messages.map((m, idx) => {
              let content = m.content || "";
              let reasoning = m.reasoning || "";
              if (!reasoning && content.includes("<think>")) {
                const parsed = parseThinkTags(content);
                content = parsed.text;
                reasoning = parsed.reasoning;
              }
              return {
                id: String(idx + 1),
                role: m.role,
                content,
                reasoning,
                timestamp: String(Math.floor(new Date(m.createdAt || 0).getTime() / 1000)),
                toolName: "",
                finishReason: "stop"
              };
            })
          };
        }
      } catch {}
    }
    return { sessionId, messages: [] };
  }

  async deleteSession(sessionId) {
    if (this.stateStore) {
      try {
        const filePath = path.join(this.stateStore.root, "sessions", `${sessionId}.json`);
        await fs.unlink(filePath).catch(() => {});
        await fs.rm(this.sessionAssetsDirectory(sessionId), { recursive: true, force: true });
        const { removeSessionFromConversationIndex } = await import("./runtime/conversation-index.mjs");
        await removeSessionFromConversationIndex(this.stateStore.workspaceRoot, sessionId);
      } catch {}
    }
    return { ok: true };
  }

  async renameSession(sessionId, newTitle) {
    if (this.stateStore) {
      try {
        const session = await this.stateStore.readSession(sessionId);
        if (session) {
          session.title = newTitle;
          session.updatedAt = new Date().toISOString();
          await this.stateStore.writeSession(session);
          return { ok: true };
        }
      } catch {}
    }
    return { ok: false, error: "Session not found." };
  }

  async exportSession(sessionId) {
    if (this.stateStore) {
      try {
        const session = await this.stateStore.readSession(sessionId);
        if (session) {
          const lines = [
            `# Session: ${session.title || sessionId}`,
            `Model: ${session.model || "unknown"}`,
            `Updated: ${session.updatedAt}`,
            ""
          ];
          for (const m of session.messages || []) {
            lines.push(`## ${m.role.toUpperCase()}`);
            lines.push(m.content || "");
            lines.push("");
          }
          return { ok: true, markdown: lines.join("\n") };
        }
      } catch {}
    }
    return { ok: false, error: "Session not found." };
  }

  async pruneSessions() {
    if (this.stateStore) {
      try {
        const sessions = await this.stateStore.listWorkspaceSessions();
        let count = 0;
        for (const s of sessions) {
          const session = await this.stateStore.readSession(s.id);
          if (!session || !session.messages || session.messages.length === 0) {
            await this.deleteSession(s.id);
            count++;
          }
        }
        return { ok: true, pruned: count };
      } catch {}
    }
    return { ok: false, pruned: 0 };
  }

  async appendSessionMessage(sessionId, message) {
    if (this.stateStore) {
      try {
        const session = await this.stateStore.readSession(sessionId);
        if (session) {
          const existingMessages = Array.isArray(session.messages) ? session.messages : [];
          if (message.role === "user" && shouldAutotitleSession(session, existingMessages)) {
            session.title = titleFromFirstUserMessage(message.content || "");
          }
          session.messages = session.messages || [];
          session.messages.push({
            role: message.role,
            content: message.content,
            createdAt: new Date().toISOString(),
            ...definedFields({
              taskId: message.taskId,
              source: message.source,
              toolName: message.toolName,
              finishReason: message.finishReason,
              reasoning: message.reasoning
            })
          });
          session.updatedAt = new Date().toISOString();
          if (message.content) {
            session.preview = message.content.slice(0, 60);
          }

          session.summary = searchableSummaryFromCompaction(session);

          await this.stateStore.writeSession(session);

          // Update Search Index
          try {
            const { indexSession } = await import("./runtime/conversation-index.mjs");
            await indexSession(this.stateStore.workspaceRoot, session);
          } catch {}
          try {
            const { updateMemoryFromSession } = await import("./runtime/memory-retrieval.mjs");
            await updateMemoryFromSession(this.stateStore.workspaceRoot, session);
          } catch {}
        }
      } catch {}
    }
  }

  async finalizeAssistantMessage(sessionId, message) {
    if (!this.stateStore) return;
    try {
      const session = await this.stateStore.readSession(sessionId);
      if (!session) return;
      session.messages = Array.isArray(session.messages) ? session.messages : [];
      const matchingIndex = session.messages.findLastIndex((item) =>
        item.role === "assistant" && item.taskId === message.taskId
      );
      const finalized = {
        role: "assistant",
        content: message.content,
        createdAt: matchingIndex >= 0
          ? session.messages[matchingIndex].createdAt
          : new Date().toISOString(),
        ...definedFields({
          taskId: message.taskId,
          source: "result",
          reasoning: message.reasoning
        })
      };
      if (matchingIndex >= 0) session.messages[matchingIndex] = finalized;
      else session.messages.push(finalized);
      await this.persistUpdatedSession(session, message.content);
    } catch {}
  }

  async localizeSessionImages(sessionId, markdown) {
    if (!this.stateStore || !markdown) return markdown;
    const matches = [...String(markdown).matchAll(/!\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g)];
    if (matches.length === 0) return markdown;
    let localized = String(markdown);
    const assetsDirectory = this.sessionAssetsDirectory(sessionId);
    await fs.mkdir(assetsDirectory, { recursive: true });

    for (const match of matches) {
      const remoteUrl = match[2];
      if (!isCacheableNoticeImageUrl(remoteUrl)) continue;
      try {
        const localImage = await readLocalWorkspaceImage(this.stateStore.workspaceRoot, remoteUrl);
        const response = localImage ? null : await fetch(remoteUrl, { signal: AbortSignal.timeout(15000) });
        if (response && !response.ok) continue;
        const contentType = localImage?.contentType
          || String(response.headers.get("content-type") || "").split(";")[0].toLowerCase();
        const extension = imageExtension(contentType);
        if (!extension) continue;
        const bytes = localImage?.bytes || Buffer.from(await response.arrayBuffer());
        if (bytes.length === 0 || bytes.length > 25 * 1024 * 1024) continue;
        const fileName = `${crypto.createHash("sha256").update(remoteUrl).digest("hex").slice(0, 24)}.${extension}`;
        await fs.writeFile(path.join(assetsDirectory, fileName), bytes);
        localized = localized.split(remoteUrl).join(`/api/sessions/${encodeURIComponent(sessionId)}/assets/${fileName}`);
      } catch {}
    }
    return localized;
  }

  async storageUsage() {
    if (!this.stateStore) return { bytes: 0, sessionCount: 0, assetCount: 0 };
    const sessionsDirectory = path.join(this.stateStore.root, "sessions");
    const totals = { bytes: 0, sessionCount: 0, assetCount: 0 };
    await accumulateStorage(sessionsDirectory, totals);
    return totals;
  }

  async sessionStorageBytes(sessionId) {
    if (!this.stateStore) return 0;
    let bytes = 0;
    try {
      bytes += (await fs.stat(path.join(this.stateStore.root, "sessions", `${safeSessionSegment(sessionId)}.json`))).size;
    } catch {}
    bytes += await directorySize(this.sessionAssetsDirectory(sessionId));
    return bytes;
  }

  sessionAssetsDirectory(sessionId) {
    return path.join(this.stateStore.root, "sessions", "assets", safeSessionSegment(sessionId));
  }

  async reconcileFinalizedAssistantMessages(session) {
    let changed = false;
    for (let index = 0; index < session.messages.length; index += 1) {
      const message = session.messages[index];
      if (message.role !== "assistant" || !message.taskId || message.source === "result") continue;
      try {
        const task = await this.stateStore.readTask(message.taskId);
        const reply = task?.result?.reply;
        if (!reply || reply === message.content) continue;
        session.messages[index] = {
          ...message,
          content: reply,
          reasoning: task.result?.reasoning || message.reasoning,
          source: "result"
        };
        changed = true;
      } catch {}
    }
    if (changed) await this.persistUpdatedSession(session, session.messages.at(-1)?.content || "");
  }

  async localizeStoredSessionImages(session) {
    let changed = false;
    for (let index = 0; index < session.messages.length; index += 1) {
      const message = session.messages[index];
      if (message.role !== "assistant" || !message.content) continue;
      const localized = await this.localizeSessionImages(session.id, message.content);
      if (localized === message.content) continue;
      session.messages[index] = { ...message, content: localized };
      changed = true;
    }
    if (changed) await this.persistUpdatedSession(session, session.messages.at(-1)?.content || "");
  }

  async persistUpdatedSession(session, previewContent = "") {
    session.updatedAt = new Date().toISOString();
    if (previewContent) session.preview = previewContent.slice(0, 60);
    session.summary = searchableSummaryFromCompaction(session);
    await this.stateStore.writeSession(session);
    try {
      const { indexSession } = await import("./runtime/conversation-index.mjs");
      await indexSession(this.stateStore.workspaceRoot, session);
    } catch {}
    try {
      const { updateMemoryFromSession } = await import("./runtime/memory-retrieval.mjs");
      await updateMemoryFromSession(this.stateStore.workspaceRoot, session);
    } catch {}
  }

  promptContext(session, options = {}) {
    const model = options.model || session?.model || "";
    const plan = planConversationCompaction(session || {}, {
      provider: options.provider || session?.provider || "",
      model,
      contextWindow: options.contextWindow || estimateContextWindow(model),
      thresholdRatio: options.compactionThresholdRatio,
      targetRatio: options.compactionTargetRatio,
      protectLastN: options.compactionProtectLastN
    });
    return promptContextFromPlan(plan);
  }

  async persistContextCompaction(sessionId, contextCompaction) {
    if (!this.stateStore || !sessionId || !contextCompaction) return false;
    const session = await this.stateStore.readSession(sessionId);
    if (!session) return false;
    session.contextCompaction = contextCompaction;
    session.summary = searchableSummaryFromCompaction(session);
    session.updatedAt = new Date().toISOString();
    await this.stateStore.writeSession(session);
    try {
      const { indexSession } = await import("./runtime/conversation-index.mjs");
      await indexSession(this.stateStore.workspaceRoot, session);
    } catch {}
    try {
      const { updateMemoryFromSession } = await import("./runtime/memory-retrieval.mjs");
      await updateMemoryFromSession(this.stateStore.workspaceRoot, session);
    } catch {}
    return true;
  }
}

function definedFields(value) {
  return Object.fromEntries(
    Object.entries(value || {}).filter(([, item]) => item !== undefined && item !== null && item !== "")
  );
}

function shouldAutotitleSession(session, messages) {
  if (messages.some((message) => message.role === "user")) return false;
  const title = String(session?.title || "").trim();
  return isGeneratedSessionTitle(title, session?.id);
}

function repairedSessionTitle(session) {
  const title = String(session?.title || "").trim();
  if (!isGeneratedSessionTitle(title, session?.id)) return "";
  const firstUser = (Array.isArray(session?.messages) ? session.messages : [])
    .find((message) => message?.role === "user" && String(message?.content || "").trim());
  return firstUser ? titleFromFirstUserMessage(firstUser.content || "") : "";
}

function isGeneratedSessionTitle(title, sessionId = "") {
  if (!title) return true;
  if (title === sessionId) return true;
  return /^Session(?:\s+\d{1,2}\/\d{1,2}\/\d{2,4})?$/i.test(title)
    || /^Session\s+\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?$/i.test(title)
    || /^(CLI Chat|Codmes Chat|Codmes TUI)\s+(\d{1,2}\/\d{1,2}\/\d{2,4}|\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?)(?:\s+(AM|PM)\s+\d{1,2}:\d{2}:\d{2})?$/i.test(title)
    || /^New session$/i.test(title)
    || /^Untitled(?: chat| session)?$/i.test(title)
    || /^session-\d{4}-\d{2}-\d{2}T/i.test(title);
}

export function titleFromFirstUserMessage(content = "") {
  const collapsed = String(content)
    .replace(/\[[^\]]+\]/g, " ")
    .replace(/```[\s\S]*?```/g, " code ")
    .replace(/\s+/g, " ")
    .trim();
  if (!collapsed) return "New chat";
  const withoutTrailing = collapsed.replace(/[.!?。！？]+$/g, "").trim() || collapsed;
  const maxLength = 34;
  if (Array.from(withoutTrailing).length <= maxLength) return withoutTrailing;
  return `${Array.from(withoutTrailing).slice(0, maxLength).join("").trimEnd()}...`;
}

function safeSessionSegment(value) {
  return String(value || "").replace(/[^a-zA-Z0-9._-]/g, "_");
}

function isCacheableNoticeImageUrl(value) {
  try {
    const url = new URL(value);
    return (url.protocol === "http:" || url.protocol === "https:")
      && (
        /^\/api\/notice-assets\/\d+\/content$/.test(url.pathname)
        || /^\/api\/document-assets\/[^/]+\/[a-zA-Z0-9._-]+\.(?:png|jpg|jpeg|webp)$/.test(url.pathname)
      );
  } catch {
    return false;
  }
}

async function readLocalWorkspaceImage(workspaceRoot, value) {
  try {
    const url = new URL(value);
    const match = url.pathname.match(/^\/api\/document-assets\/([^/]+)\/([a-zA-Z0-9._-]+\.(?:png|jpg|jpeg|webp))$/i);
    if (!match) return null;
    const directory = decodeURIComponent(match[1]);
    const fileName = match[2];
    if (path.basename(directory) !== directory || !/--[a-f0-9]{8}$/.test(directory)) return null;
    const absolutePath = path.join(workspaceRoot, ".codmes", "documents", directory, "index", "images", fileName);
    const bytes = await fs.readFile(absolutePath);
    const extension = path.extname(fileName).toLowerCase();
    return {
      bytes,
      contentType: extension === ".png" ? "image/png" : extension === ".webp" ? "image/webp" : "image/jpeg"
    };
  } catch {
    return null;
  }
}

function imageExtension(contentType) {
  return ({
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/bmp": "bmp"
  })[contentType] || "";
}

async function accumulateStorage(directory, totals) {
  let entries;
  try { entries = await fs.readdir(directory, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      await accumulateStorage(absolutePath, totals);
      continue;
    }
    if (!entry.isFile()) continue;
    const stat = await fs.stat(absolutePath);
    totals.bytes += stat.size;
    if (entry.name.endsWith(".json")) totals.sessionCount += 1;
    else if (absolutePath.includes(`${path.sep}assets${path.sep}`)) totals.assetCount += 1;
  }
}

async function directorySize(directory) {
  let bytes = 0;
  let entries;
  try { entries = await fs.readdir(directory, { withFileTypes: true }); } catch { return 0; }
  for (const entry of entries) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) bytes += await directorySize(absolutePath);
    else if (entry.isFile()) bytes += (await fs.stat(absolutePath)).size;
  }
  return bytes;
}

function searchableSummaryFromCompaction(session = {}) {
  const state = session.contextCompaction;
  if (state?.mode !== "summary" && session.summary?.generator === "auxiliary_model" && session.summary.content) {
    return session.summary;
  }
  const coveredMessageIds = Array.isArray(state?.coveredMessageIds) ? state.coveredMessageIds : [];
  return {
    content: state?.mode === "summary" ? String(state.summary || "") : "",
    generator: state?.mode === "summary"
      ? "auxiliary_model_compaction"
      : state?.mode === "native" ? "native_compaction_opaque" : "none",
    sourceMessageIds: coveredMessageIds,
    coveredMessageIds,
    lastSummarizedMessageId: coveredMessageIds.at(-1) || null,
    updatedAt: state?.updatedAt || new Date().toISOString()
  };
}
