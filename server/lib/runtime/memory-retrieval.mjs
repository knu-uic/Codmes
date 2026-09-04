import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { resolveTimeRange } from "./time-range.mjs";

export const DEFAULT_MEMORY_SETTINGS = {
  autoSaveProjectMemory: true,
  autoSaveFolderMemory: true,
  autoSaveSessionSummaryMemory: true,
  autoSaveUserMemory: false,
  memoryReviewRequired: true
};

export const MEMORY_SEARCH_DEFINITION = {
  type: "function",
  function: {
    name: "memory_search",
    description: "Search past long-term user preferences, project/folder memories, and session summaries. Never use this for current external-service state such as KNU notices, LMS tasks, portal grades, account status, or other live data; use tool_discovery for those.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        query: { type: "string", description: "Memory search query." },
        currentFolderId: { type: "string" },
        currentProjectId: { type: "string" },
        timeRange: { type: "string", description: "today, yesterday, this_week, last_week, last_7_days, or ISO range." },
        maxResults: { type: "integer", minimum: 1, maximum: 50 }
      },
      required: ["query"]
    }
  }
};

export async function searchMemory(workspaceRoot, query, context = {}) {
  const q = String(query || "").toLowerCase();
  const timeRange = resolveTimeRange(context.timeRange, { now: context.now });
  
  // Sources to collect candidates from:
  // 1. User memories
  // 2. Project memories (if currentProjectId matches)
  // 3. Folder memories (if currentFolderId matches)
  // 4. Session summaries (from all sessions)
  
  const candidates = [];
  
  // 1. User memories
  try {
    const filePath = path.join(workspaceRoot, ".codmes", "memory", "user", "memories.jsonl");
    const data = await fs.readFile(filePath, "utf8");
    const lines = data.split("\n").filter(Boolean).map(JSON.parse);
    lines.forEach(m => {
      candidates.push({
        ...m,
        type: "user_memory",
        content: m.content,
        createdAt: m.createdAt || new Date().toISOString(),
        pinned: Boolean(m.pinned),
        source: m.sourceSessionIds || []
      });
    });
  } catch {}

  // 2. Folder memories
  if (context.currentFolderId) {
    try {
      const filePath = path.join(workspaceRoot, ".codmes", "memory", "folders", `folder-${context.currentFolderId}.json`);
      const data = await fs.readFile(filePath, "utf8");
      const list = JSON.parse(data);
      list.forEach(m => {
        candidates.push({
          ...m,
          type: "folder_memory",
          folderId: context.currentFolderId,
          content: m.content,
          createdAt: m.createdAt || new Date().toISOString(),
          pinned: Boolean(m.pinned)
        });
      });
    } catch {}
  }

  // 3. Project memories
  if (context.currentProjectId) {
    try {
      const filePath = path.join(workspaceRoot, ".codmes", "memory", "projects", `project-${context.currentProjectId}.jsonl`);
      const data = await fs.readFile(filePath, "utf8");
      const lines = data.split("\n").filter(Boolean).map(JSON.parse);
      lines.forEach(m => {
        candidates.push({
          ...m,
          type: "project_memory",
          projectId: context.currentProjectId,
          content: m.content,
          createdAt: m.createdAt || new Date().toISOString(),
          pinned: Boolean(m.pinned)
        });
      });
    } catch {}
  }

  // 4. Session summaries
  const sessionsDir = path.join(workspaceRoot, ".codmes", "sessions");
  try {
    const files = await fs.readdir(sessionsDir);
    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      try {
        const data = await fs.readFile(path.join(sessionsDir, file), "utf8");
        const session = JSON.parse(data);
        if (session.summary && session.summary.content) {
          candidates.push({
            type: "session_summary_memory",
            sessionId: session.id,
            folderId: session.folderId,
            projectId: session.projectId,
            content: session.summary.content,
            createdAt: session.summary.updatedAt || session.updatedAt || session.createdAt || new Date().toISOString(),
            pinned: Boolean(session.pinned)
          });
        }
      } catch {}
    }
  } catch {}

  // Filter & Score candidates
  const scored = candidates
    .filter((candidate) => isWithinTimeRange(candidate.createdAt, timeRange))
    .map(c => {
    const score = calculateMemoryScore(c, q, context);
    return { ...c, score, reason: buildMemoryReason(c, score, context) };
  });

  // Sort by score desc
  return scored
    .filter(c => !q || c.score >= memoryThreshold(c, context))
    .sort((a, b) => b.score - a.score || new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
    .slice(0, context.maxResults || 10);
}

export async function updateMemoryFromSession(workspaceRoot, session, options = {}) {
  const settings = {
    ...DEFAULT_MEMORY_SETTINGS,
    ...(await readMemorySettings(workspaceRoot)),
    ...(options.memorySettings || {})
  };
  const candidates = extractMemoryCandidates(session, options);
  const saved = [];
  const reviewCandidates = [];
  const blocked = [];
  const deletedHashes = await readDeletedMemoryHashes(workspaceRoot);
  for (const candidate of candidates) {
    const normalized = normalizeMemory(candidate, candidate.type);
    if (deletedHashes.has(normalized.contentHash)) {
      blocked.push({ ...normalized, reason: "matches_deleted_memory_tombstone" });
      continue;
    }
    if (isSensitiveMemory(normalized.content)) {
      reviewCandidates.push(await saveMemoryCandidate(workspaceRoot, normalized, "sensitive_review_required"));
      continue;
    }
    if (candidate.type === "user_memory") {
      if (settings.autoSaveUserMemory && !settings.memoryReviewRequired) {
        saved.push(await saveUserMemory(workspaceRoot, normalized));
      } else {
        reviewCandidates.push(await saveMemoryCandidate(workspaceRoot, normalized, "user_memory_review_required"));
      }
    } else if (candidate.type === "project_memory") {
      if (settings.autoSaveProjectMemory) saved.push(await saveProjectMemory(workspaceRoot, candidate.projectId, normalized));
      else reviewCandidates.push(await saveMemoryCandidate(workspaceRoot, normalized, "project_memory_review_required"));
    } else if (candidate.type === "folder_memory") {
      if (settings.autoSaveFolderMemory) saved.push(await saveFolderMemory(workspaceRoot, candidate.folderId, normalized));
      else reviewCandidates.push(await saveMemoryCandidate(workspaceRoot, normalized, "folder_memory_review_required"));
    } else if (candidate.type === "session_summary_memory") {
      if (settings.autoSaveSessionSummaryMemory) saved.push(await saveSessionSummaryMemory(workspaceRoot, normalized));
      else reviewCandidates.push(await saveMemoryCandidate(workspaceRoot, normalized, "session_summary_review_required"));
    }
  }
  return { saved, candidates: reviewCandidates, blocked };
}

export async function readMemorySettings(workspaceRoot) {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "settings.json");
  try {
    const raw = JSON.parse(await fs.readFile(filePath, "utf8"));
    return {
      ...DEFAULT_MEMORY_SETTINGS,
      ...Object.fromEntries(
        Object.entries(raw || {}).filter(([, value]) => typeof value === "boolean")
      )
    };
  } catch {
    return { ...DEFAULT_MEMORY_SETTINGS };
  }
}

export async function writeMemorySettings(workspaceRoot, patch = {}) {
  const next = {
    ...(await readMemorySettings(workspaceRoot)),
    ...Object.fromEntries(
      Object.entries(patch || {}).filter(([, value]) => typeof value === "boolean")
    )
  };
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "settings.json");
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(next, null, 2) + "\n", "utf8");
  return next;
}

export async function listMemoryCandidates(workspaceRoot) {
  const rows = [];
  await collectJsonl(rows, path.join(workspaceRoot, ".codmes", "memory", "candidates.jsonl"));
  return rows.filter((item) => item.status !== "rejected" && item.status !== "approved");
}

export async function approveMemoryCandidate(workspaceRoot, candidateId, patch = {}) {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "candidates.jsonl");
  const rows = await readJsonl(filePath);
  const idx = rows.findIndex((item) => item.id === candidateId);
  if (idx === -1) throw Object.assign(new Error(`Memory candidate not found: ${candidateId}`), { status: 404 });
  const candidate = normalizeMemory({ ...rows[idx], ...patch }, rows[idx].type);
  let saved;
  if (candidate.type === "user_memory") saved = await saveUserMemory(workspaceRoot, candidate);
  else if (candidate.type === "project_memory") saved = await saveProjectMemory(workspaceRoot, candidate.projectId, candidate);
  else if (candidate.type === "folder_memory") saved = await saveFolderMemory(workspaceRoot, candidate.folderId, candidate);
  else saved = await saveSessionSummaryMemory(workspaceRoot, candidate);
  rows[idx] = { ...rows[idx], status: "approved", approvedAt: new Date().toISOString(), savedMemoryId: saved.id };
  await writeJsonl(filePath, rows);
  return { ok: true, candidate: rows[idx], memory: saved };
}

export async function rejectMemoryCandidate(workspaceRoot, candidateId, reason = "rejected") {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "candidates.jsonl");
  const rows = await readJsonl(filePath);
  const idx = rows.findIndex((item) => item.id === candidateId);
  if (idx === -1) throw Object.assign(new Error(`Memory candidate not found: ${candidateId}`), { status: 404 });
  rows[idx] = { ...rows[idx], status: "rejected", rejectedAt: new Date().toISOString(), rejectReason: reason };
  await writeJsonl(filePath, rows);
  return { ok: true, candidate: rows[idx] };
}

export async function recordDeletedMemoryTombstone(workspaceRoot, memory, reason = "user_deleted") {
  const normalized = normalizeMemory(memory || {}, memory?.type || "user_memory");
  const tombstone = {
    id: `deleted-memory-${normalized.contentHash}`,
    memoryId: normalized.id,
    contentHash: normalized.contentHash,
    reason,
    deletedAt: new Date().toISOString()
  };
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "deleted-memory-hashes.jsonl");
  await upsertJsonl(filePath, tombstone);
  return tombstone;
}

export async function readMemoryById(workspaceRoot, memoryId) {
  const all = [];
  await collectJsonl(all, path.join(workspaceRoot, ".codmes", "memory", "user", "memories.jsonl"));
  await collectJsonl(all, path.join(workspaceRoot, ".codmes", "memory", "sessions", "session-summaries.jsonl"));
  await collectGlobJsonl(all, path.join(workspaceRoot, ".codmes", "memory", "projects"));
  await collectFolderMemory(all, path.join(workspaceRoot, ".codmes", "memory", "folders"));
  return all.find((memory) => memory.id === memoryId) || null;
}

export function extractMemoryCandidates(session, _options = {}) {
  if (!session || !Array.isArray(session.messages)) return [];
  const sourceMessageIds = session.messages.map((message, index) => message.id || String(index + 1));
  const content = [
    session.summary?.content || "",
    ...session.messages
      .filter((message) => ["user", "assistant"].includes(message.role))
      .slice(-12)
      .map((message) => message.content || "")
  ].join("\n").trim();
  if (!content) return [];

  const tags = extractTags(content);
  const base = {
    sourceSessionIds: [session.id].filter(Boolean),
    sourceMessageIds,
    tags,
    createdAt: session.createdAt || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    pinned: false
  };
  const candidates = [];

  if (session.summary?.content) {
    candidates.push({
      ...base,
      id: stableMemoryId("session", session.id || "", session.summary.content),
      type: "session_summary_memory",
      content: session.summary.content
    });
  }

  const preference = extractPreference(content);
  if (preference) {
    candidates.push({
      ...base,
      id: stableMemoryId("user", session.id || "", preference),
      type: "user_memory",
      content: preference
    });
  }

  if (session.projectId && session.summary?.content) {
    candidates.push({
      ...base,
      id: stableMemoryId("project", session.projectId, session.summary.content),
      type: "project_memory",
      projectId: session.projectId,
      content: session.summary.content
    });
  }

  if (session.folderId && session.summary?.content) {
    candidates.push({
      ...base,
      id: stableMemoryId("folder", session.folderId, session.summary.content),
      type: "folder_memory",
      folderId: session.folderId,
      content: session.summary.content
    });
  }

  return candidates;
}

export async function saveUserMemory(workspaceRoot, memory) {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "user", "memories.jsonl");
  return await upsertJsonl(filePath, normalizeMemory(memory, "user_memory"));
}

export async function saveProjectMemory(workspaceRoot, projectId, memory) {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "projects", `project-${safeId(projectId)}.jsonl`);
  return await upsertJsonl(filePath, normalizeMemory({ ...memory, projectId }, "project_memory"));
}

export async function saveFolderMemory(workspaceRoot, folderId, memory) {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "folders", `folder-${safeId(folderId)}.json`);
  let list = [];
  try {
    list = JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {}
  const normalized = normalizeMemory({ ...memory, folderId }, "folder_memory");
  const next = upsertArray(list, normalized);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(next, null, 2) + "\n", "utf8");
  return normalized;
}

export async function saveSessionSummaryMemory(workspaceRoot, memory) {
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "sessions", "session-summaries.jsonl");
  return await upsertJsonl(filePath, normalizeMemory(memory, "session_summary_memory"));
}

function calculateMemoryScore(candidate, query, context) {
  const text = String(candidate.content || "").toLowerCase();
  
  // 1. Semantic/Keyword Similarity (45%)
  let similarity = 0;
  const words = query.split(/\s+/).filter(Boolean);
  if (words.length > 0) {
    let matchCount = 0;
    words.forEach(w => {
      if (text.includes(w)) matchCount++;
    });
    similarity = matchCount / words.length;
    if (similarity === 0) return 0;
  } else {
    similarity = 1.0;
  }

  // 2. Keyword Match (20%)
  const keywordMatch = text.includes(query) ? 1.0 : 0.0;

  // 3. Recency Weight (15%)
  const ageInMs = Date.now() - new Date(candidate.createdAt).getTime();
  const ageInDays = ageInMs / (24 * 3600 * 1000);
  let recencyWeight = 0.2;
  if (ageInDays <= 1) recencyWeight = 1.0;
  else if (ageInDays <= 7) recencyWeight = 0.8;
  else if (ageInDays <= 30) recencyWeight = 0.5;

  // Boost if date ranges are specified
  if (context.timeRange) {
    // optional boost
  }

  // 4. Folder/Project Boost (15%)
  let folderOrProjectBoost = 0.3;
  if (context.currentFolderId && candidate.folderId === context.currentFolderId) {
    folderOrProjectBoost = 1.0;
  }
  if (context.currentProjectId && candidate.projectId === context.currentProjectId) {
    folderOrProjectBoost = 1.0;
  }

  // 5. User Pinned Boost (5%)
  const userPinnedBoost = candidate.pinned ? 1.0 : 0.0;

  const finalScore =
    similarity * 0.45 +
    keywordMatch * 0.20 +
    recencyWeight * 0.15 +
    folderOrProjectBoost * 0.15 +
    userPinnedBoost * 0.05;

  return Number(finalScore.toFixed(3));
}

function isWithinTimeRange(createdAt, range) {
  if (!range) return true;
  const time = Date.parse(createdAt || "");
  if (!Number.isFinite(time)) return true;
  if (range.from && time < range.from.getTime()) return false;
  if (range.to && time > range.to.getTime()) return false;
  return true;
}

async function upsertJsonl(filePath, memory) {
  const list = await readJsonl(filePath);
  const next = upsertArray(list, memory);
  await writeJsonl(filePath, next);
  return next.find((item) => item.id === memory.id || item.contentHash === memory.contentHash) || memory;
}

async function readJsonl(filePath) {
  try {
    return (await fs.readFile(filePath, "utf8")).split("\n").filter(Boolean).map(JSON.parse);
  } catch {
    return [];
  }
}

async function writeJsonl(filePath, rows) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, rows.map((item) => JSON.stringify(item)).join("\n") + (rows.length ? "\n" : ""), "utf8");
}

async function collectJsonl(target, filePath) {
  try {
    const rows = (await fs.readFile(filePath, "utf8")).split("\n").filter(Boolean).map(JSON.parse);
    target.push(...rows);
  } catch {}
}

async function collectGlobJsonl(target, dirPath) {
  let files = [];
  try {
    files = await fs.readdir(dirPath);
  } catch {
    return;
  }
  for (const file of files) {
    if (file.endsWith(".jsonl")) await collectJsonl(target, path.join(dirPath, file));
  }
}

async function collectFolderMemory(target, dirPath) {
  let files = [];
  try {
    files = await fs.readdir(dirPath);
  } catch {
    return;
  }
  for (const file of files) {
    if (!file.endsWith(".json")) continue;
    try {
      const rows = JSON.parse(await fs.readFile(path.join(dirPath, file), "utf8"));
      if (Array.isArray(rows)) target.push(...rows);
    } catch {}
  }
}

function upsertArray(list, memory) {
  const idx = list.findIndex((item) =>
    item.id === memory.id
    || (item.contentHash && memory.contentHash && item.contentHash === memory.contentHash)
    || similarMemoryContent(item.content, memory.content)
  );
  if (idx >= 0) {
    list[idx] = {
      ...list[idx],
      ...memory,
      id: list[idx].id || memory.id,
      createdAt: list[idx].createdAt || memory.createdAt,
      updatedAt: new Date().toISOString(),
      sourceSessionIds: mergeArray(list[idx].sourceSessionIds, memory.sourceSessionIds),
      sourceMessageIds: mergeArray(list[idx].sourceMessageIds, memory.sourceMessageIds),
      tags: mergeArray(list[idx].tags, memory.tags)
    };
    return list;
  }
  return [...list, memory];
}

function normalizeMemory(memory, fallbackType) {
  const content = String(memory.content || "").trim();
  const contentHash = memory.contentHash || hashMemoryContent(content);
  return {
    id: memory.id || stableMemoryId(fallbackType, memory.projectId || memory.folderId || "", content),
    type: memory.type || fallbackType,
    content,
    contentHash,
    projectId: memory.projectId || undefined,
    folderId: memory.folderId || undefined,
    sourceSessionIds: memory.sourceSessionIds || [],
    sourceMessageIds: memory.sourceMessageIds || [],
    tags: memory.tags || [],
    createdAt: memory.createdAt || new Date().toISOString(),
    updatedAt: memory.updatedAt || new Date().toISOString(),
    pinned: Boolean(memory.pinned)
  };
}

async function saveMemoryCandidate(workspaceRoot, memory, reason) {
  const normalized = normalizeMemory(memory, memory.type || "user_memory");
  const candidate = {
    ...normalized,
    id: `memory-candidate-${normalized.contentHash}`,
    status: "pending",
    reviewReason: reason,
    candidateCreatedAt: new Date().toISOString()
  };
  const filePath = path.join(workspaceRoot, ".codmes", "memory", "candidates.jsonl");
  return await upsertJsonl(filePath, candidate);
}

async function readDeletedMemoryHashes(workspaceRoot) {
  const rows = await readJsonl(path.join(workspaceRoot, ".codmes", "memory", "deleted-memory-hashes.jsonl"));
  return new Set(rows.map((row) => row.contentHash).filter(Boolean));
}

function isSensitiveMemory(content) {
  const text = String(content || "");
  return /(api[_ -]?key|password|passwd|secret|token|bearer|주민등록|여권|신용카드|credit card|private key)/i.test(text);
}

function hashMemoryContent(content) {
  return crypto.createHash("sha256").update(normalizeContentForHash(content)).digest("hex").slice(0, 32);
}

function normalizeContentForHash(content) {
  return String(content || "").toLowerCase().replace(/\s+/g, " ").trim();
}

function similarMemoryContent(a, b) {
  const left = normalizeContentForHash(a);
  const right = normalizeContentForHash(b);
  if (!left || !right) return false;
  if (left === right) return true;
  return left.length > 20 && right.length > 20 && (left.includes(right) || right.includes(left));
}

function mergeArray(a = [], b = []) {
  return Array.from(new Set([...(Array.isArray(a) ? a : []), ...(Array.isArray(b) ? b : [])].filter(Boolean)));
}

function memoryThreshold(candidate, context) {
  if (context.currentFolderId && candidate.folderId === context.currentFolderId) return 0.2;
  if (context.currentProjectId && candidate.projectId === context.currentProjectId) return 0.2;
  return Number.isFinite(Number(context.minScore)) ? Number(context.minScore) : 0.35;
}

function buildMemoryReason(candidate, score, context) {
  if (context.currentFolderId && candidate.folderId === context.currentFolderId) return `folder match, score ${score}`;
  if (context.currentProjectId && candidate.projectId === context.currentProjectId) return `project match, score ${score}`;
  if (candidate.pinned) return `pinned memory, score ${score}`;
  return `keyword/time relevance score ${score}`;
}

function stableMemoryId(...parts) {
  return `memory-${crypto.createHash("sha256").update(parts.join("\n")).digest("hex").slice(0, 20)}`;
}

function extractTags(text) {
  const tags = [];
  const lower = String(text || "").toLowerCase();
  for (const [needle, tag] of [
    ["codmes", "codmes"],
    ["hermes", "hermes"],
    ["codex", "code-agent"],
    ["Codmes Search", "rag"],
    ["pdf", "pdf"],
    ["옵시디언", "obsidian"],
    ["음악", "music"]
  ]) {
    if (lower.includes(needle)) tags.push(tag);
  }
  return Array.from(new Set(tags));
}

function extractPreference(text) {
  const lines = String(text || "").split(/\n+/).map((line) => line.trim()).filter(Boolean);
  const preferenceLine = lines.find((line) => /선호|원해|원한다|좋아|싫어|prefer|preference|want/i.test(line));
  if (!preferenceLine) return "";
  return preferenceLine.slice(0, 500);
}

function safeId(value) {
  return String(value || "default").replace(/[^a-zA-Z0-9_.-]/g, "_");
}
