import fs from "node:fs/promises";
import path from "node:path";
import { resolveTimeRange } from "./time-range.mjs";

export async function ensureConversationIndex(workspaceRoot) {
  const dir = path.join(workspaceRoot, ".codmes", "conversation-index");
  await fs.mkdir(dir, { recursive: true });
  return dir;
}

export async function indexSession(workspaceRoot, session) {
  const dir = await ensureConversationIndex(workspaceRoot);
  
  // 1. Index Session Meta
  const metaPath = path.join(dir, "sessions.jsonl");
  let sessions = [];
  try {
    const data = await fs.readFile(metaPath, "utf8");
    sessions = data.split("\n").filter(Boolean).map(JSON.parse);
  } catch {}
  
  // Remove existing
  sessions = sessions.filter(s => s.id !== session.id);
  // Add new
  sessions.push({
    id: session.id,
    title: session.title,
    kind: session.kind || "general",
    surface: session.surface || "chat",
    folderId: session.folderId || null,
    projectId: session.projectId || null,
    createdAt: session.createdAt || new Date().toISOString(),
    updatedAt: session.updatedAt || new Date().toISOString(),
    lastOpenedAt: session.lastOpenedAt || new Date().toISOString(),
    archivedAt: session.archivedAt || null,
    archiveReason: session.archiveReason || null,
    visibleInSidebar: session.visibleInSidebar !== false,
    searchable: session.searchable !== false,
    pinned: Boolean(session.pinned)
  });
  
  await fs.writeFile(metaPath, sessions.map(s => JSON.stringify(s)).join("\n") + "\n", "utf8");

  // 2. Index Summary
  const summaryPath = path.join(dir, "summaries.jsonl");
  let summaries = [];
  try {
    const data = await fs.readFile(summaryPath, "utf8");
    summaries = data.split("\n").filter(Boolean).map(JSON.parse);
  } catch {}
  summaries = summaries.filter(s => s.sessionId !== session.id);
  if (session.summary && session.summary.content) {
    summaries.push({
      sessionId: session.id,
      summary: session.summary.content,
      updatedAt: session.summary.updatedAt || new Date().toISOString()
    });
  }
  await fs.writeFile(summaryPath, summaries.map(s => JSON.stringify(s)).join("\n") + (summaries.length ? "\n" : ""), "utf8");

  // 3. Index Messages
  if (Array.isArray(session.messages)) {
    const msgPath = path.join(dir, "messages.jsonl");
    let messages = [];
    try {
      const data = await fs.readFile(msgPath, "utf8");
      messages = data.split("\n").filter(Boolean).map(JSON.parse);
    } catch {}
    
    messages = messages.filter(m => m.sessionId !== session.id);
    session.messages.forEach((msg, idx) => {
      messages.push({
        sessionId: session.id,
        messageId: msg.id || String(idx + 1),
        role: msg.role,
        content: msg.content || "",
        createdAt: msg.createdAt || new Date().toISOString()
      });
    });
    
    await fs.writeFile(msgPath, messages.map(m => JSON.stringify(m)).join("\n") + "\n", "utf8");
  }
}

export async function removeSessionFromConversationIndex(workspaceRoot, sessionId) {
  const dir = await ensureConversationIndex(workspaceRoot);
  for (const [fileName, key] of [
    ["sessions.jsonl", "id"],
    ["summaries.jsonl", "sessionId"],
    ["messages.jsonl", "sessionId"]
  ]) {
    const filePath = path.join(dir, fileName);
    let rows = [];
    try {
      rows = (await fs.readFile(filePath, "utf8")).split("\n").filter(Boolean).map(JSON.parse);
    } catch {}
    const next = rows.filter((row) => row?.[key] !== sessionId);
    await fs.writeFile(filePath, next.map((row) => JSON.stringify(row)).join("\n") + (next.length ? "\n" : ""), "utf8");
  }
}

export async function searchConversationIndex(workspaceRoot, query, options = {}) {
  const dir = await ensureConversationIndex(workspaceRoot);
  const q = String(query || "").toLowerCase();
  const tokens = tokenizeQuery(q);
  
  // Read indexing files
  let sessions = [];
  try {
    const data = await fs.readFile(path.join(dir, "sessions.jsonl"), "utf8");
    sessions = data.split("\n").filter(Boolean).map(JSON.parse);
  } catch {}

  let summaries = [];
  try {
    const data = await fs.readFile(path.join(dir, "summaries.jsonl"), "utf8");
    summaries = data.split("\n").filter(Boolean).map(JSON.parse);
  } catch {}

  let messages = [];
  try {
    const data = await fs.readFile(path.join(dir, "messages.jsonl"), "utf8");
    messages = data.split("\n").filter(Boolean).map(JSON.parse);
  } catch {}

  const results = [];
  
  // Time filtering helper
  const parseTime = (val) => new Date(val).getTime();
  const resolvedTimeRange = resolveTimeRange(options.timeRange, {
    now: options.now,
    timezoneOffsetMs: options.timezoneOffsetMs
  });
  let fromTime = resolvedTimeRange?.from ? resolvedTimeRange.from.getTime() : null;
  let toTime = resolvedTimeRange?.to ? resolvedTimeRange.to.getTime() : null;

  // Filter sessions map
  const sessionsMap = new Map(sessions.map(s => [s.id, s]));

  // Search in Summaries
  for (const s of summaries) {
    const sessionObj = sessionsMap.get(s.sessionId);
    if (!sessionObj) continue;
    if (sessionObj.searchable === false) continue;
    if (sessionObj.archivedAt && options.includeArchived !== true) continue;
    
    // Apply filters
    const sessionTime = parseTime(s.updatedAt || sessionObj.updatedAt || sessionObj.createdAt);
    if (fromTime && sessionTime < fromTime) continue;
    if (toTime && sessionTime > toTime) continue;
    if (options.folderId && sessionObj.folderId !== options.folderId) continue;
    if (options.projectId && sessionObj.projectId !== options.projectId) continue;
    
    const content = s.summary.toLowerCase();
    const score = calculateScore(s.summary, q, sessionObj, { ...options, queryTokens: tokens });
    if (!q || score >= 0.18 || content.includes(q)) {
      results.push({
        type: "session_summary",
        sessionId: s.sessionId,
        folderId: sessionObj.folderId,
        projectId: sessionObj.projectId,
        createdAt: sessionObj.createdAt,
        archived: Boolean(sessionObj.archivedAt),
        archivedAt: sessionObj.archivedAt || null,
        archiveReason: sessionObj.archiveReason || null,
        score,
        summary: s.summary
      });
    }
  }

  // Search in Messages
  for (const m of messages) {
    const sessionObj = sessionsMap.get(m.sessionId);
    if (!sessionObj) continue;
    if (sessionObj.searchable === false) continue;
    if (sessionObj.archivedAt && options.includeArchived !== true) continue;

    // Apply filters
    const sessionTime = parseTime(m.createdAt || sessionObj.updatedAt || sessionObj.createdAt);
    if (fromTime && sessionTime < fromTime) continue;
    if (toTime && sessionTime > toTime) continue;
    if (options.folderId && sessionObj.folderId !== options.folderId) continue;
    if (options.projectId && sessionObj.projectId !== options.projectId) continue;

    const content = m.content.toLowerCase();
    const score = calculateScore(m.content, q, sessionObj, { ...options, queryTokens: tokens });
    if (!q || score >= 0.18 || content.includes(q)) {
      results.push({
        type: "session_message",
        sessionId: m.sessionId,
        folderId: sessionObj.folderId,
        projectId: sessionObj.projectId,
        createdAt: sessionObj.createdAt,
        archived: Boolean(sessionObj.archivedAt),
        archivedAt: sessionObj.archivedAt || null,
        archiveReason: sessionObj.archiveReason || null,
        score,
        snippet: m.content,
        sourceMessageIds: [m.messageId]
      });
    }
  }

  // Sort by score desc, then date desc
  const sorted = results
    .sort((a, b) => b.score - a.score || parseTime(b.createdAt) - parseTime(a.createdAt));
  return options.unbounded ? sorted : sorted.slice(0, options.maxResults || 10);
}

function calculateScore(text, query, session, options = {}) {
  // 1. Semantic/Keyword Similarity (45%)
  let similarity = 0;
  const words = options.queryTokens || tokenizeQuery(query);
  if (words.length > 0) {
    let matchCount = 0;
    const lowerText = text.toLowerCase();
    words.forEach(w => {
      if (lowerText.includes(w)) matchCount++;
    });
    similarity = matchCount / words.length;
  } else {
    similarity = 1.0; // If query is empty, treat all as match
  }

  // 2. Keyword Match (20%)
  const keywordMatch = text.toLowerCase().includes(query.toLowerCase()) ? 1.0 : 0.0;

  // 3. Recency Weight (15%)
  const now = options.now ? new Date(options.now).getTime() : Date.now();
  const ageInMs = now - new Date(session.updatedAt || session.createdAt).getTime();
  const ageInDays = ageInMs / (24 * 3600 * 1000);
  let recencyWeight = 0.2;
  if (ageInDays <= 1) recencyWeight = 1.0;
  else if (ageInDays <= 7) recencyWeight = 0.8;
  else if (ageInDays <= 30) recencyWeight = 0.5;

  // 4. Folder/Project Boost (15%)
  let folderOrProjectBoost = 0.3;
  if (options.currentFolderId && session.folderId === options.currentFolderId) {
    folderOrProjectBoost = 1.0;
  }
  if (options.currentProjectId && session.projectId === options.currentProjectId) {
    folderOrProjectBoost = 1.0;
  }

  // 5. User Pinned Boost (5%)
  const userPinnedBoost = session.pinned ? 1.0 : 0.0;

  const finalScore =
    similarity * 0.45 +
    keywordMatch * 0.20 +
    recencyWeight * 0.15 +
    folderOrProjectBoost * 0.15 +
    userPinnedBoost * 0.05;

  return Number(finalScore.toFixed(3));
}

export function tokenizeQuery(query) {
  const stopwords = new Set([
    "내가", "나는", "저는", "우리", "뭐였지", "뭐야", "무엇", "어떤", "있나", "있어",
    "저번주", "이번주", "지난주", "오늘", "어제", "찾아", "검색", "관련", "대화",
    "the", "a", "an", "is", "are", "was", "were", "what", "when", "where", "about"
  ]);
  return Array.from(new Set(
    String(query || "")
      .toLowerCase()
      .split(/[^a-zA-Z0-9가-힣_/-]+/)
      .map(normalizeToken)
      .filter((token) => token.length >= 2 && !stopwords.has(token))
  ));
}

function normalizeToken(token) {
  let value = String(token || "").trim();
  value = value.replace(/(이었|였|었|았|했던|하던|하였|하는|하다|했고|합니다|했어|했음|였다|였다가)$/u, "");
  value = value.replace(/(으로|에서|에게|한테|부터|까지|처럼|보다|이고|하고|이며|이랑|랑|은|는|이|가|을|를|에|의|도|만|과|와)$/u, "");
  if (value === "들었" || value === "들은" || value === "듣던") return "들";
  return value;
}

export async function readConversationMessages(workspaceRoot, sessionId, messageIds = [], options = {}) {
  const sessionPath = path.join(workspaceRoot, ".codmes", "sessions", `${sessionId}.json`);
  let session = null;
  try {
    const data = await fs.readFile(sessionPath, "utf8");
    session = JSON.parse(data);
  } catch {
    return { messages: [] };
  }

  if (!session || !Array.isArray(session.messages)) {
    return { messages: [] };
  }

  const requestedIds = new Set(messageIds.map(String));
  const results = [];
  const msgs = session.messages;

  msgs.forEach((m, idx) => {
    const msgId = String(m.id || idx + 1);
    if (requestedIds.size === 0 || requestedIds.has(msgId)) {
      if (options.includeSurroundingMessages) {
        const window = options.surroundingWindow || 4;
        const start = Math.max(0, idx - window);
        const end = Math.min(msgs.length - 1, idx + window);
        for (let i = start; i <= end; i++) {
          const windowMsgId = String(msgs[i].id || i + 1);
          results.push({
            id: windowMsgId,
            role: msgs[i].role,
            content: msgs[i].content,
            createdAt: msgs[i].createdAt,
            isTarget: i === idx
          });
        }
      } else {
        results.push({
          id: msgId,
          role: m.role,
          content: m.content,
          createdAt: m.createdAt,
          isTarget: true
        });
      }
    }
  });

  // Remove duplicates from window overlaps
  const seenIds = new Set();
  const uniqueResults = [];
  results.forEach(m => {
    if (!seenIds.has(m.id)) {
      seenIds.add(m.id);
      uniqueResults.push(m);
    } else if (m.isTarget) {
      const existing = uniqueResults.find((item) => item.id === m.id);
      if (existing) existing.isTarget = true;
    }
  });

  return {
    sessionId,
    title: session.title,
    messages: uniqueResults
  };
}
