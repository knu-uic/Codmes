import { closeSync, existsSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { fileKind, resolveWorkspacePath } from "./path-utils.mjs";
import {
  extractAndCacheDocument,
  extractDocumentAnnotationBlocks,
  documentOriginalBackupPath,
  isDocumentIngestFile,
  pruneDocumentIngestCacheFiles,
  removeDocumentIngestCacheFiles
} from "./document-ingest.mjs";
import { searchConversationIndex } from "./runtime/conversation-index.mjs";

const DEFAULT_MAX_RESULTS = 20;
const DEFAULT_MAX_SCAN_FILES = 1000;
const DEFAULT_MAX_FILE_BYTES = 1024 * 1024 * 1024;
const DEFAULT_CHUNK_CHARS = 1800;
const DEFAULT_CHUNK_OVERLAP = 220;

const SEARCHABLE_KINDS = new Set(["markdown", "code", "file", "pdf", "image", "document", "spreadsheet"]);
const SEARCHABLE_EXTENSIONS = new Set([
  ".md",
  ".markdown",
  ".txt",
  ".json",
  ".yaml",
  ".yml",
  ".toml",
  ".js",
  ".jsx",
  ".ts",
  ".tsx",
  ".py",
  ".swift",
  ".go",
  ".rs",
  ".java",
  ".c",
  ".cc",
  ".cpp",
  ".h",
  ".hpp",
  ".html",
  ".css",
  ".sh",
  ".ps1",
  ".pdf",
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".bmp",
  ".tif",
  ".tiff",
  ".heic",
  ".doc",
  ".docx",
  ".ppt",
  ".pptx",
  ".hwp",
  ".hwpx",
  ".odt",
  ".odp",
  ".xlsx",
  ".xls",
  ".zip"
]);

export function searchStatus(workspaceRoot) {
  const filePath = searchIndexPath(workspaceRoot);
  const hasIndex = existsSync(filePath);
  let builtAt = null;
  let itemCount = 0;
  let chunkCount = 0;
  let indexBytes = 0;
  if (hasIndex) {
    try {
      const stat = statSync(filePath);
      indexBytes = stat.size;
      const index = readSearchIndexMetadataSync(filePath);
      builtAt = index.builtAt || null;
      itemCount = Number(index.itemCount || 0);
      chunkCount = Number(index.chunkCount || 0);
    } catch {
      builtAt = null;
    }
  }
  return {
    provider: hasIndex ? "codmes-search-index" : "workspace-scan",
    workspaceRoot,
    available: true,
    indexed: hasIndex,
    realtimeIndexing: true,
    watchMode: "fs.watch-recursive-when-supported",
    description: hasIndex
      ? "Codmes built-in search index. Semantic ranking is planned inside Codmes Search Runtime."
      : "Codmes built-in scan search. Run codmes index rebuild to create the local search index.",
    partialIndexing: true,
    indexPath: path.relative(workspaceRoot, filePath).replace(/\\/g, "/"),
    builtAt,
    itemCount,
    chunkCount,
    indexBytes,
    maxFileBytes: configuredMaxFileBytes(),
    searchableExtensions: Array.from(SEARCHABLE_EXTENSIONS).sort()
  };
}

export async function searchWorkspace(workspaceRoot, request = {}) {
  const query = String(request.query || "").trim();
  if (!query) throw Object.assign(new Error("Missing search query."), { status: 400 });
  const scopePath = resolveWorkspacePath(workspaceRoot, request.scopePath || "").relativePath;
  const maxResults = request.unbounded
    ? Number.POSITIVE_INFINITY
    : clampNumber(request.maxResults, 1, 100, DEFAULT_MAX_RESULTS);
  if (!request.forceScan) {
    const indexed = await searchBuiltIndex(workspaceRoot, { ...request, query, scopePath, maxResults });
    if (indexed) return indexed;
  }
  const maxScanFiles = clampNumber(request.maxScanFiles, 10, 5000, DEFAULT_MAX_SCAN_FILES);
  const candidates = filterCandidates(
    await listSearchableFiles(workspaceRoot, scopePath, {
      maxScanFiles,
      maxFileBytes: configuredMaxFileBytes(request.maxFileBytes)
    }),
    request
  );
  const results = [];
  for (const file of candidates) {
    if (results.length >= maxResults) break;
    const hit = await searchFile(workspaceRoot, file, query);
    if (hit) results.push(hit);
  }
  return {
    provider: "workspace-scan",
    indexed: false,
    query,
    scopePath,
    totalCandidates: candidates.length,
    resultCount: results.length,
    results
  };
}

export async function globalSearch(workspaceRoot, request = {}) {
  const query = String(request.query || request.q || "").trim();
  if (!query) throw Object.assign(new Error("Missing search query."), { status: 400 });
  const surface = normalizeGlobalSurface(request.surface || "all");
  const pageSize = clampNumber(request.limit || request.maxResults, 1, 100, 100);
  const afterResultId = decodeGlobalSearchCursor(request.cursor, query, surface);
  const fileResults = await searchGlobalFileIndex(workspaceRoot, { query, surface });
  const organizedFiles = organizeGlobalFileResults(fileResults, query);
  const conversationResults = await searchGlobalConversations(workspaceRoot, {
    query,
    surface,
    unbounded: true
  });
  const orderedConversations = conversationResults
    .filter((result) => result.surface && surfaceMatches(result.surface, surface))
    .filter((result) => !isInternalSearchPath(result.target?.path || ""))
    .sort((a, b) => (
      b.score - a.score
      || String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""))
      || a.id.localeCompare(b.id)
    ));
  const allResults = [...organizedFiles.results, ...orderedConversations];
  const cursorIndex = afterResultId
    ? allResults.findIndex((result) => result.id === afterResultId)
    : -1;
  if (afterResultId && cursorIndex < 0) {
    throw Object.assign(new Error("Global search cursor expired. Run the search again."), { status: 409 });
  }
  const offset = cursorIndex + 1;
  const results = allResults.slice(offset, offset + pageSize);
  const nextOffset = offset + results.length;
  return {
    provider: "codmes-global-search",
    query,
    surface,
    scope: { type: "global" },
    documents: organizedFiles.documents,
    resultCount: allResults.length,
    returnedCount: results.length,
    nextCursor: nextOffset < allResults.length
      ? encodeGlobalSearchCursor(results.at(-1)?.id, query, surface)
      : null,
    hasMore: nextOffset < allResults.length,
    results
  };
}

function encodeGlobalSearchCursor(afterResultId, query, surface) {
  return Buffer.from(JSON.stringify({ version: 1, afterResultId, query, surface }), "utf8").toString("base64url");
}

function decodeGlobalSearchCursor(cursor, query, surface) {
  if (!cursor) return null;
  try {
    const decoded = JSON.parse(Buffer.from(String(cursor), "base64url").toString("utf8"));
    if (decoded.version !== 1 || decoded.query !== query || decoded.surface !== surface) throw new Error();
    if (typeof decoded.afterResultId !== "string" || !decoded.afterResultId) throw new Error();
    return decoded.afterResultId;
  } catch {
    throw Object.assign(new Error("Invalid or expired global search cursor."), { status: 400 });
  }
}

export function searchIndexPath(workspaceRoot) {
  return path.join(workspaceRoot, ".codmes", "index", "search.json");
}

export async function readSearchIndex(workspaceRoot) {
  try {
    return JSON.parse(await fs.readFile(searchIndexPath(workspaceRoot), "utf8"));
  } catch {
    return null;
  }
}

export async function buildSearchIndex(workspaceRoot, options = {}) {
  const roots = sanitizeRoots(options.roots || [""]);
  const maxScanFiles = clampNumber(options.maxScanFiles, 10, 20000, 10000);
  const filesByPath = new Map();
  for (const root of roots) {
    const files = await listSearchableFiles(workspaceRoot, root, {
      maxScanFiles,
      maxFileBytes: configuredMaxFileBytes(options.maxFileBytes)
    });
    for (const file of files) filesByPath.set(file.path, file);
  }
  const files = Array.from(filesByPath.values()).sort((a, b) => a.path.localeCompare(b.path));
  const chunks = [];
  const items = [];
  for (const file of files) {
    const indexed = await indexFile(workspaceRoot, file, options).catch(() => null);
    if (!indexed) continue;
    items.push(indexed.item);
    chunks.push(...indexed.chunks);
  }
  const index = {
    schemaVersion: 1,
    provider: "codmes-search-index",
    builtAt: new Date().toISOString(),
    roots,
    embeddings: normalizeEmbeddingConfig(options.embeddings || options),
    itemCount: items.length,
    chunkCount: chunks.length,
    items,
    chunks
  };
  const filePath = searchIndexPath(workspaceRoot);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(index, null, 2) + "\n", "utf8");
  await pruneDocumentIngestCacheFiles(workspaceRoot);
  return index;
}

export async function updateSearchIndex(workspaceRoot, changedPaths = [], options = {}) {
  for (const changedPath of [].concat(changedPaths || [])) {
    const rel = String(changedPath || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
    if (!rel || isInternalSearchPath(rel)) continue;
    const resolved = resolveWorkspacePath(workspaceRoot, rel);
    const stat = await fs.stat(resolved.absolutePath).catch(() => null);
    if (!stat) await removeDocumentIngestCacheFiles(workspaceRoot, [rel]);
  }
  const current = await readSearchIndex(workspaceRoot);
  if (!current) return await buildSearchIndex(workspaceRoot, options);
  const itemByPath = new Map((current.items || []).map((item) => [item.path, item]));
  const chunksByPath = new Map();
  for (const chunk of current.chunks || []) {
    if (!chunksByPath.has(chunk.path)) chunksByPath.set(chunk.path, []);
    chunksByPath.get(chunk.path).push(chunk);
  }
  for (const changedPath of [].concat(changedPaths || [])) {
    const rel = String(changedPath || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
    if (!rel || isInternalSearchPath(rel)) continue;
    const resolved = resolveWorkspacePath(workspaceRoot, rel);
    const stat = await fs.stat(resolved.absolutePath).catch(() => null);
    if (!stat) {
      removeIndexedPath(itemByPath, chunksByPath, rel);
      continue;
    }
    if (stat.isDirectory()) {
      const files = await listSearchableFiles(workspaceRoot, rel, {
        maxScanFiles: 5000,
        maxFileBytes: configuredMaxFileBytes(options.maxFileBytes)
      });
      const livePaths = new Set(files.map((file) => file.path));
      for (const pathKey of Array.from(itemByPath.keys())) {
        if (pathKey.startsWith(`${rel}/`) && !livePaths.has(pathKey)) {
          itemByPath.delete(pathKey);
          chunksByPath.delete(pathKey);
        }
      }
      for (const file of files) {
        const next = await indexFile(workspaceRoot, file, options).catch(() => null);
        if (next) {
          itemByPath.set(next.item.path, next.item);
          chunksByPath.set(next.item.path, next.chunks);
        }
      }
      continue;
    }
    if (!isSearchableTextFile(rel) || stat.size > configuredMaxFileBytes(options.maxFileBytes)) {
      itemByPath.delete(rel);
      chunksByPath.delete(rel);
      continue;
    }
    const next = await indexFile(workspaceRoot, {
      path: rel,
      absolutePath: resolved.absolutePath,
      kind: fileKind(rel),
      size: stat.size,
      modifiedAt: stat.mtime.toISOString()
    }, options).catch(() => null);
    if (next) {
      itemByPath.set(next.item.path, next.item);
      chunksByPath.set(next.item.path, next.chunks);
    }
  }
  const items = Array.from(itemByPath.values()).sort((a, b) => a.path.localeCompare(b.path));
  const chunks = items.flatMap((item) => chunksByPath.get(item.path) || []);
  const index = {
    ...current,
    provider: "codmes-search-index",
    builtAt: new Date().toISOString(),
    roots: sanitizeRoots(options.roots || current.roots || [""]),
    embeddings: normalizeEmbeddingConfig(
      options.embeddings || (hasEmbeddingOptions(options) ? options : current.embeddings)
    ),
    itemCount: items.length,
    chunkCount: chunks.length,
    items,
    chunks
  };
  const filePath = searchIndexPath(workspaceRoot);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(index, null, 2) + "\n", "utf8");
  return index;
}

async function searchBuiltIndex(workspaceRoot, request) {
  const index = await readSearchIndex(workspaceRoot);
  if (!index || !Array.isArray(index.chunks)) return null;
  const query = String(request.query || "").trim();
  const scopePath = String(request.scopePath || "").replace(/^\/+|\/+$/g, "");
  const maxResults = request.unbounded
    ? Number.POSITIVE_INFINITY
    : clampNumber(request.maxResults, 1, 100, DEFAULT_MAX_RESULTS);
  const chunks = index.chunks.filter((chunk) => inScope(chunk.path, scopePath) && !isInternalSearchPath(chunk.path));
  const kinds = requestedKinds(request);
  const scored = [];
  for (const chunk of chunks) {
    if (kinds.size > 0 && !kinds.has(String(chunk.kind).toLowerCase())) continue;
    const match = scoreIndexedChunk(chunk, query);
    if (match.score <= 0) continue;
    scored.push({
      path: chunk.path,
      kind: chunk.kind,
      score: match.score,
      snippet: match.snippet,
      chunkId: chunk.id,
      chunkIndex: chunk.chunkIndex,
      page: chunk.page ?? null,
      source: chunk.source || null,
      bbox: chunk.bbox || null
    });
  }
  const deduped = [];
  const seenPaths = new Set();
  for (const hit of scored.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path))) {
    if (seenPaths.has(hit.path)) continue;
    seenPaths.add(hit.path);
    deduped.push(hit);
    if (deduped.length >= maxResults) break;
  }
  return {
    provider: "codmes-search-index",
    indexed: true,
    query,
    scopePath,
    builtAt: index.builtAt || null,
    totalCandidates: chunks.length,
    resultCount: deduped.length,
    results: deduped
  };
}

async function searchGlobalFileIndex(workspaceRoot, request) {
  const index = await readSearchIndex(workspaceRoot);
  if (!index || !Array.isArray(index.chunks)) {
    return searchGlobalFileScan(workspaceRoot, request);
  }
  const query = String(request.query || "").trim();
  const itemByPath = new Map((index.items || []).map((item) => [item.path, item]));
  const matches = [];
  for (const item of itemByPath.values()) {
    if (isInternalSearchPath(item.path)) continue;
    const resultSurface = surfaceForPath(item.path);
    if (!surfaceMatches(resultSurface, request.surface)) continue;
    const titleMatch = classifyFileNameMatch(item.path, query);
    if (titleMatch === "none") continue;
    matches.push(toGlobalItemResult(item, resultSurface));
  }
  for (const chunk of index.chunks) {
    if (isInternalSearchPath(chunk.path)) continue;
    const resultSurface = surfaceForPath(chunk.path);
    if (!surfaceMatches(resultSurface, request.surface)) continue;
    const item = itemByPath.get(chunk.path) || {};
    const match = matchGlobalChunk(chunk, query);
    if (!match.matched) continue;
    matches.push(toGlobalFileResult(workspaceRoot, chunk, item, resultSurface, match));
  }
  return dedupeGlobalResults(matches);
}

async function searchGlobalFileScan(workspaceRoot, request) {
  const scopePath = request.surface === "notes" ? "Notes" : request.surface === "codes" ? "Codes" : "";
  const legacy = await searchWorkspace(workspaceRoot, {
    query: request.query,
    scopePath,
    unbounded: true,
    maxScanFiles: 5000,
    forceScan: true
  }).catch(() => ({ results: [] }));
  return (legacy.results || [])
    .filter((result) => !isInternalSearchPath(result.path))
    .map((result) => {
      const resultSurface = surfaceForPath(result.path);
      return {
        id: stableResultId("file", result.path, result.page ?? "", result.snippet || ""),
        surface: resultSurface,
        kind: globalFileKind(result.path, result.kind, result.source),
        title: path.basename(result.path),
        subtitle: subtitleForPath(result.path, result.page),
        snippet: result.snippet || result.path,
        score: 0,
        updatedAt: result.modifiedAt || null,
        target: {
          path: result.path,
          page: normalizedPage(result.page),
          sessionId: null,
          messageId: null,
          projectId: null,
          line: null,
          bbox: result.bbox || null
        }
      };
    })
    .filter((result) => surfaceMatches(result.surface, request.surface));
}

async function searchGlobalConversations(workspaceRoot, request) {
  const sessionsById = await readConversationSessionsById(workspaceRoot);
  const hits = await searchConversationIndex(workspaceRoot, request.query, {
    unbounded: request.unbounded,
    includeArchived: false
  }).catch(() => []);
  return hits
    .map((hit) => {
      const session = sessionsById.get(hit.sessionId) || {};
      const resultSurface = conversationSurface(session, hit);
      if (!surfaceMatches(resultSurface, request.surface)) return null;
      const isMessage = hit.type === "session_message";
      const title = session.title || hit.title || `Session ${hit.sessionId}`;
      const messageId = Array.isArray(hit.sourceMessageIds) ? hit.sourceMessageIds[0] : null;
      return {
        id: stableResultId("conversation", hit.sessionId, messageId || "", hit.type || ""),
        surface: resultSurface,
        kind: resultSurface === "codes"
          ? (isMessage ? "code_message" : "code_session")
          : (isMessage ? "chat_message" : "chat_session"),
        title,
        subtitle: conversationSubtitle(session, hit, resultSurface),
        snippet: hit.snippet || hit.summary || title,
        score: normalizeLegacyScore(hit.score) + (isMessage ? 5 : 12),
        updatedAt: session.updatedAt || hit.createdAt || null,
        target: {
          path: null,
          page: null,
          sessionId: hit.sessionId || null,
          messageId: messageId || null,
          projectId: session.projectId || hit.projectId || null,
          line: null
        }
      };
    })
    .filter(Boolean);
}

async function readConversationSessionsById(workspaceRoot) {
  const filePath = path.join(workspaceRoot, ".codmes", "conversation-index", "sessions.jsonl");
  const sessions = new Map();
  try {
    const text = await fs.readFile(filePath, "utf8");
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      const session = JSON.parse(line);
      sessions.set(session.id, session);
    }
  } catch {}
  return sessions;
}

function toGlobalFileResult(workspaceRoot, chunk, item, surface, match) {
  const page = normalizedPage(chunk.page);
  return {
    id: stableResultId("file", chunk.id || chunk.path, page ?? "", chunk.chunkIndex ?? ""),
    surface,
    kind: globalFileKind(chunk.path, chunk.kind, chunk.source),
    title: path.basename(chunk.path),
    subtitle: subtitleForPath(chunk.path, page),
    snippet: match.snippet,
    score: 0,
    updatedAt: item.modifiedAt || null,
    target: {
      path: chunk.path,
      page,
      sessionId: null,
      messageId: null,
      projectId: null,
      line: null,
      bbox: searchFocusBoundingBox(workspaceRoot, chunk, match)
    }
  };
}

function toGlobalItemResult(item, surface) {
  return {
    id: stableResultId("item", item.path),
    surface,
    kind: surface === "notes" ? "note_file" : "code_file",
    title: path.basename(item.path),
    subtitle: item.path,
    snippet: item.path,
    score: 0,
    updatedAt: item.modifiedAt || null,
    target: {
      path: item.path,
      page: null,
      sessionId: null,
      messageId: null,
      projectId: null,
      line: null,
      bbox: null
    }
  };
}

function classifyFileNameMatch(filePath, query) {
  const fileName = path.basename(filePath || "");
  const lowerFileName = normalizeSearchText(fileName);
  const lowerTitle = lowerFileName.replace(path.extname(lowerFileName), "");
  const phrase = normalizeSearchText(query);
  if (lowerTitle === phrase || lowerFileName === phrase) return "exact";
  if (lowerTitle.startsWith(phrase) || lowerFileName.startsWith(phrase)) return "prefix";
  if (lowerFileName.includes(phrase)) return "contains";
  return "none";
}

function matchGlobalChunk(chunk, query) {
  const text = String(chunk.text || "").normalize("NFC");
  const lowerText = normalizeSearchText(text);
  const phrase = normalizeSearchText(query);
  const exactIndex = lowerText.indexOf(phrase);
  const tokens = phrase.split(/\s+/).filter(Boolean);
  const matched = exactIndex >= 0 || (tokens.length > 1 && tokens.every((token) => lowerText.includes(token)));
  if (!matched) return { matched: false, snippet: "" };
  const index = exactIndex >= 0 ? exactIndex : firstTokenIndex(lowerText, tokens);
  return {
    matched: true,
    snippet: index >= 0 ? snippet(text, index, query.length) : chunk.path,
    exactIndex,
    exactLength: exactIndex >= 0 ? phrase.length : 0
  };
}

function searchFocusBoundingBox(workspaceRoot, chunk, match) {
  const bbox = chunk.bbox || null;
  if (
    !bbox
    || String(chunk.kind || "").toLowerCase() !== "pdf"
    || !Number.isInteger(match?.exactIndex)
    || match.exactIndex < 0
    || !Number.isFinite(match?.exactLength)
    || match.exactLength <= 0
    || !existsSync(documentOriginalBackupPath(workspaceRoot, chunk.path))
  ) {
    return bbox;
  }
  const text = String(chunk.text || "").normalize("NFC");
  if (!text || /[\r\n]/.test(text)) return bbox;
  const startFraction = Math.max(0, Math.min(1, match.exactIndex / text.length));
  const widthFraction = Math.max(0, Math.min(1 - startFraction, match.exactLength / text.length));
  if (widthFraction <= 0) return bbox;

  const adjust = (box) => {
    if (!box || ![box.x, box.y, box.width, box.height].every((value) => Number.isFinite(Number(value)))) {
      return box;
    }
    const x = Number(box.x);
    const y = Number(box.y);
    const width = Number(box.width);
    const height = Number(box.height);
    const visualY = Math.max(0, y - height * 0.82);
    return {
      ...box,
      x: x + width * startFraction,
      y: visualY,
      width: width * widthFraction,
      height: height * 1.22
    };
  };
  return {
    ...adjust(bbox),
    normalized: adjust(bbox.normalized)
  };
}

function organizeGlobalFileResults(results, query) {
  const groups = new Map();
  results.forEach((result, sourceIndex) => {
    const filePath = result.target?.path;
    if (!filePath) return;
    if (!groups.has(filePath)) groups.set(filePath, []);
    groups.get(filePath).push({ result, sourceIndex });
  });
  const titleMatchRank = { exact: 3, prefix: 2, contains: 1, none: 0 };
  const documents = Array.from(groups, ([filePath, entries]) => {
    const contentEntries = entries.filter(({ result }) => !isGlobalFileTitleResult(result));
    const pages = new Set(contentEntries.map(({ result }) => result.target?.page).filter(Number.isFinite));
    const titleMatch = classifyFileNameMatch(filePath, query);
    return {
      path: filePath,
      title: path.basename(filePath),
      surface: entries[0]?.result.surface || surfaceForPath(filePath),
      titleMatch,
      matchedPageCount: pages.size,
      occurrenceCount: contentEntries.length,
      entries
    };
  }).sort((a, b) => (
    titleMatchRank[b.titleMatch] - titleMatchRank[a.titleMatch]
    || b.matchedPageCount - a.matchedPageCount
    || b.occurrenceCount - a.occurrenceCount
    || a.path.localeCompare(b.path)
  ));
  const orderedResults = documents.flatMap((document) => document.entries
    .sort(compareGlobalFileEntries)
    .map(({ result }) => result));
  return {
    documents: documents.map(({ entries, ...summary }) => summary),
    results: orderedResults
  };
}

function compareGlobalFileEntries(lhs, rhs) {
  const lhsTitle = isGlobalFileTitleResult(lhs.result);
  const rhsTitle = isGlobalFileTitleResult(rhs.result);
  if (lhsTitle !== rhsTitle) return lhsTitle ? -1 : 1;
  const lhsPage = Number(lhs.result.target?.page);
  const rhsPage = Number(rhs.result.target?.page);
  if (Number.isFinite(lhsPage) && Number.isFinite(rhsPage) && lhsPage !== rhsPage) return lhsPage - rhsPage;
  if (Number.isFinite(lhsPage) !== Number.isFinite(rhsPage)) return Number.isFinite(lhsPage) ? -1 : 1;
  const lhsBox = normalizedSearchBox(lhs.result.target?.bbox);
  const rhsBox = normalizedSearchBox(rhs.result.target?.bbox);
  if (lhsBox.y !== rhsBox.y) return lhsBox.y - rhsBox.y;
  if (lhsBox.x !== rhsBox.x) return lhsBox.x - rhsBox.x;
  return lhs.sourceIndex - rhs.sourceIndex || lhs.result.id.localeCompare(rhs.result.id);
}

function normalizedSearchBox(bbox) {
  const box = bbox?.normalized || bbox || {};
  return {
    x: Number.isFinite(Number(box.x)) ? Number(box.x) : Number.POSITIVE_INFINITY,
    y: Number.isFinite(Number(box.y)) ? Number(box.y) : Number.POSITIVE_INFINITY
  };
}

function isGlobalFileTitleResult(result) {
  return result.kind === "note_file" || result.kind === "code_file";
}

function dedupeGlobalResults(results, maxResults = Number.POSITIVE_INFINITY) {
  const seen = new Set();
  const deduped = [];
  for (const result of results) {
    const key = `${result.kind}:${result.target.path || ""}:${result.target.page ?? ""}:${result.snippet}`;
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(result);
    if (deduped.length >= maxResults) break;
  }
  return deduped;
}

function normalizeGlobalSurface(value) {
  const surface = String(value || "all").toLowerCase();
  return ["all", "notes", "codes", "chat"].includes(surface) ? surface : "all";
}

function surfaceMatches(surface, filter) {
  return filter === "all" || surface === filter;
}

function surfaceForPath(relativePath) {
  const first = String(relativePath || "").split("/")[0]?.toLowerCase();
  if (first === "notes" || first === "documents") return "notes";
  if (first === "codes" || first === "code" || first === "projects") return "codes";
  return "codes";
}

function globalFileKind(relativePath, kind, source) {
  const ext = path.extname(relativePath || "").toLowerCase();
  const normalizedSource = String(source || "").toLowerCase();
  if (normalizedSource.includes("annotation")) return "pdf_annotation";
  if (ext === ".pdf" || kind === "pdf") return "pdf_chunk";
  if (ext === ".md" || ext === ".markdown" || kind === "markdown") return "markdown_chunk";
  if (surfaceForPath(relativePath) === "notes") return "note_chunk";
  return "code_chunk";
}

function subtitleForPath(relativePath, page) {
  const normalized = normalizedPage(page);
  const pageText = normalized ? ` · ${normalized} page` : "";
  return `${relativePath}${pageText}`;
}

function normalizedPage(page) {
  const value = Number(page);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function conversationSurface(session, hit) {
  const surface = String(session.surface || "").toLowerCase();
  if (surface === "code" || surface === "codes") return "codes";
  if (surface === "chat") return "chat";
  if (session.projectId || hit.projectId) return "codes";
  return "chat";
}

function conversationSubtitle(session, hit, surface) {
  if (surface === "codes") {
    return [session.projectId || hit.projectId || "Code session", session.folderId].filter(Boolean).join(" · ");
  }
  return [session.folderId || "Chat session", session.updatedAt || hit.createdAt].filter(Boolean).join(" · ");
}

function normalizeLegacyScore(score) {
  const value = Number(score || 0);
  if (!Number.isFinite(value)) return 0;
  return value <= 1 ? Math.round(value * 100) : value;
}

function firstTokenIndex(text, tokens) {
  for (const token of tokens) {
    const index = text.indexOf(token);
    if (index >= 0) return index;
  }
  return -1;
}

async function indexFile(workspaceRoot, file, options = {}) {
  const document = await readSearchableDocument(workspaceRoot, file).catch(() => ({ text: "", blocks: [] }));
  const content = String(document.text || "");
  const item = {
    path: file.path,
    kind: file.kind,
    size: file.size,
    modifiedAt: file.modifiedAt,
    textLength: content.length,
    chunkCount: 0,
    blockCount: Array.isArray(document.blocks) ? document.blocks.length : 0
  };
  const chunks = [];
  const blocks = Array.isArray(document.blocks) && document.blocks.length
    ? document.blocks
    : content
      ? [{ text: content, source: file.kind, page: null, bbox: null, kind: file.kind, path: file.path }]
      : [];
  for (const block of blocks) {
    const blockText = String(block.text || "").trim();
    if (!blockText) continue;
    const fileChunks = chunkText(content, {
      ...options,
      text: blockText,
      chunkChars: clampNumber(options.chunkChars, 400, 8000, DEFAULT_CHUNK_CHARS),
      overlap: clampNumber(options.chunkOverlap, 0, 2000, DEFAULT_CHUNK_OVERLAP)
    });
    fileChunks.forEach((chunk, index) => {
      const chunkIndex = chunks.length;
      chunks.push({
        id: stableChunkId(file.path, chunkIndex, block.source || "", block.page || "", chunk.start, chunk.text),
        path: file.path,
        kind: block.kind || file.kind,
        chunkIndex,
        blockIndex: blocks.indexOf(block),
        start: chunk.start,
        end: chunk.end,
        text: chunk.text,
        source: block.source || file.kind,
        page: Number.isFinite(Number(block.page)) ? Number(block.page) : null,
        bbox: block.bbox || null
      });
    });
  }
  item.chunkCount = chunks.length;
  return { item, chunks };
}

function removeIndexedPath(itemByPath, chunksByPath, rel) {
  for (const pathKey of Array.from(itemByPath.keys())) {
    if (pathKey === rel || pathKey.startsWith(`${rel}/`)) {
      itemByPath.delete(pathKey);
      chunksByPath.delete(pathKey);
    }
  }
}

function normalizeEmbeddingConfig(config = {}) {
  return {
    provider: String(config.embeddingsProvider || config.provider || "none"),
    baseUrl: String(config.openaiBaseUrl || config.baseUrl || ""),
    model: String(config.openaiEmbedModel || config.model || ""),
    dimensions: Number.parseInt(String(config.openaiEmbedDim || config.dimensions || "0"), 10) || null,
    mode: "configured-for-future-vector-index"
  };
}

function hasEmbeddingOptions(options = {}) {
  return Boolean(
    options.embeddingsProvider ||
    options.openaiBaseUrl ||
    options.openaiEmbedModel ||
    options.openaiEmbedDim ||
    options.provider ||
    options.baseUrl ||
    options.model ||
    options.dimensions
  );
}

async function listSearchableFiles(workspaceRoot, relativePath, options) {
  const resolved = resolveWorkspacePath(workspaceRoot, relativePath);
  const results = [];
  async function visit(absolutePath) {
    if (results.length >= options.maxScanFiles) return;
    const stat = await fs.stat(absolutePath);
    if (stat.isDirectory()) {
      const entries = await fs.readdir(absolutePath, { withFileTypes: true });
      entries.sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
      for (const entry of entries) {
        if (entry.name === ".DS_Store" || entry.name === ".hermes-workspace") continue;
        if (shouldSkipDirectoryEntry(workspaceRoot, absolutePath, entry.name)) continue;
        await visit(path.join(absolutePath, entry.name));
        if (results.length >= options.maxScanFiles) return;
      }
      return;
    }
    if (stat.size > configuredMaxFileBytes(options.maxFileBytes)) return;
    const rel = path.relative(workspaceRoot, absolutePath).replace(/\\/g, "/");
    if (!isSearchableTextFile(rel)) return;
    results.push({
      path: rel,
      absolutePath,
      kind: fileKind(rel),
      size: stat.size,
      modifiedAt: stat.mtime.toISOString()
    });
  }
  await visit(resolved.absolutePath).catch((error) => {
    if (error?.code !== "ENOENT") throw error;
  });
  return results;
}

function configuredMaxFileBytes(value) {
  const configured = Number.parseInt(
    String(value || process.env.CODMES_SEARCH_MAX_FILE_BYTES || DEFAULT_MAX_FILE_BYTES),
    10
  );
  return Number.isSafeInteger(configured) && configured > 0 ? configured : DEFAULT_MAX_FILE_BYTES;
}

function shouldSkipDirectoryEntry(workspaceRoot, parentAbsolutePath, entryName) {
  if (INTERNAL_DIRECTORY_NAMES.has(entryName)) return true;
  const parentRel = path.relative(workspaceRoot, parentAbsolutePath).replace(/\\/g, "/");
  return false;
}

async function searchFile(workspaceRoot, file, query) {
  const needle = normalizeSearchText(query);
  const filenameIndex = normalizeSearchText(file.path).indexOf(needle);
  if (filenameIndex >= 0) {
    return {
      path: file.path,
      kind: file.kind,
      size: file.size,
      modifiedAt: file.modifiedAt,
      score: 1.25,
      snippet: file.path
    };
  }
  let text;
  try {
    text = await readSearchableText(workspaceRoot, file);
  } catch {
    return null;
  }
  if (!text) return null;
  const normalizedText = text.normalize("NFC");
  const haystack = normalizeSearchText(normalizedText);
  const index = haystack.indexOf(needle);
  if (index < 0) return null;
  return {
    path: file.path,
    kind: file.kind,
    size: file.size,
    modifiedAt: file.modifiedAt,
    score: scoreHit(normalizedText, query, index),
    snippet: snippet(normalizedText, index, needle.length)
  };
}

function filterCandidates(candidates, request) {
  const kinds = requestedKinds(request);
  const modifiedAfter = parseDate(request.modifiedAfter);
  const modifiedBefore = parseDate(request.modifiedBefore);
  return candidates.filter((file) => {
    if (kinds.size > 0 && !kinds.has(String(file.kind).toLowerCase())) return false;
    const modifiedAt = Date.parse(file.modifiedAt);
    if (modifiedAfter && modifiedAt < modifiedAfter.getTime()) return false;
    if (modifiedBefore && modifiedAt > modifiedBefore.getTime()) return false;
    return true;
  });
}

async function readSearchableDocument(workspaceRoot, file) {
  if (isDocumentIngestFile(file.path)) {
    const document = await extractAndCacheDocument(workspaceRoot, file.absolutePath, file.path);
    const annotationBlocks = await extractDocumentAnnotationBlocks(workspaceRoot, file.path).catch(() => []);
    if (!annotationBlocks.length) return document;
    const text = [document.text, annotationBlocks.map((block) => block.text).join("\n\n")]
      .filter(Boolean)
      .join("\n\n")
      .trim();
    return {
      ...document,
      text,
      blocks: [...(document.blocks || []), ...annotationBlocks]
    };
  }
  const text = await fs.readFile(file.absolutePath, "utf8");
  return {
    text,
    blocks: [{ path: file.path, kind: file.kind, source: file.kind, page: null, bbox: null, text }]
  };
}

async function readSearchableText(workspaceRoot, file) {
  const document = await readSearchableDocument(workspaceRoot, file);
  return document.text || "";
}

function requestedKinds(request) {
  return new Set(
    []
      .concat(request.kind || [])
      .concat(request.kinds || [])
      .filter(Boolean)
      .map((item) => String(item).toLowerCase())
  );
}

function parseDate(value) {
  if (!value) return null;
  const time = Date.parse(String(value));
  return Number.isFinite(time) ? new Date(time) : null;
}

function isSearchableTextFile(relativePath) {
  if (isInternalSearchPath(relativePath)) return false;
  const ext = path.extname(relativePath).toLowerCase();
  if (SEARCHABLE_EXTENSIONS.has(ext)) return true;
  return SEARCHABLE_KINDS.has(fileKind(relativePath));
}

const INTERNAL_DIRECTORY_NAMES = new Set([
  ".codmes",
  ".git",
  "node_modules",
  ".build",
  "DerivedData",
  "dist",
  "vendor",
  "cache",
  "thumbnails"
]);

function isInternalSearchPath(relativePath) {
  const value = String(relativePath || "").replace(/\\/g, "/");
  if (!value) return false;
  const lower = value.toLowerCase();
  if (lower.endsWith(".codmes.json")) return true;
  if (lower.endsWith(".tmp") || lower.endsWith(".part") || lower.endsWith(".cache")) return true;
  const segments = value.split("/").filter(Boolean);
  return segments.some((segment) => INTERNAL_DIRECTORY_NAMES.has(segment));
}

function snippet(text, index, length) {
  const radius = 140;
  const start = Math.max(0, index - radius);
  const end = Math.min(text.length, index + length + radius);
  const prefix = start > 0 ? "... " : "";
  const suffix = end < text.length ? " ..." : "";
  return prefix + text.slice(start, end).replace(/\s+/g, " ").trim() + suffix;
}

function normalizeSearchText(value) {
  return String(value || "").normalize("NFC").toLocaleLowerCase();
}

function chunkText(text, options) {
  const chunks = [];
  text = String(options.text ?? text ?? "");
  const chunkChars = options.chunkChars;
  const overlap = Math.min(options.overlap, Math.max(0, chunkChars - 1));
  let start = 0;
  while (start < text.length) {
    const hardEnd = Math.min(text.length, start + chunkChars);
    const end = findChunkEnd(text, start, hardEnd);
    const body = text.slice(start, end).replace(/\s+/g, " ").trim();
    if (body) chunks.push({ start, end, text: body });
    if (end >= text.length) break;
    start = Math.max(start + 1, end - overlap);
  }
  return chunks;
}

function findChunkEnd(text, start, hardEnd) {
  if (hardEnd >= text.length) return text.length;
  const window = text.slice(start, hardEnd);
  const breakpoints = ["\n\n", "\n", ". ", " "];
  for (const mark of breakpoints) {
    const index = window.lastIndexOf(mark);
    if (index > Math.floor(window.length * 0.55)) return start + index + mark.length;
  }
  return hardEnd;
}

function scoreIndexedChunk(chunk, query) {
  const text = String(chunk.text || "").normalize("NFC");
  const lowerText = normalizeSearchText(text);
  const lowerPath = normalizeSearchText(chunk.path);
  const phrase = normalizeSearchText(query);
  const terms = queryTerms(query);
  let score = 0;
  let index = lowerText.indexOf(phrase);
  if (index >= 0) score += 5 + Math.min(2, phrase.length / 12);
  if (lowerPath.includes(phrase)) score += 3;
  for (const term of terms) {
    if (lowerPath.includes(term)) score += 1.5;
    const termIndex = lowerText.indexOf(term);
    if (termIndex >= 0) {
      score += 1;
      if (index < 0) index = termIndex;
    }
  }
  if (terms.length > 1 && terms.every((term) => lowerText.includes(term) || lowerPath.includes(term))) {
    score += 2;
  }
  if (score <= 0) return { score: 0, snippet: "" };
  return {
    score: Number((score - Math.min(0.3, text.length / 20000)).toFixed(4)),
    snippet: snippet(text, Math.max(0, index), Math.max(phrase.length, terms[0]?.length || 1))
  };
}

function queryTerms(query) {
  return Array.from(new Set(normalizeSearchText(query)
    .split(/[^\p{L}\p{N}_-]+/u)
    .map((term) => term.trim())
    .filter((term) => term.length >= 2)));
}

function inScope(filePath, scopePath) {
  if (!scopePath) return true;
  return filePath === scopePath || filePath.startsWith(`${scopePath}/`);
}

function sanitizeRoots(roots) {
  return []
    .concat(roots || [])
    .map((root) => String(root || "").trim().replace(/^\/+|\/+$/g, ""))
    .filter((root, index, array) => array.indexOf(root) === index);
}

function stableChunkId(...parts) {
  let hash = 0;
  const input = parts.join("\n");
  for (let index = 0; index < input.length; index += 1) {
    hash = Math.imul(31, hash) + input.charCodeAt(index) | 0;
  }
  return `chunk-${Math.abs(hash).toString(36)}`;
}

function stableResultId(...parts) {
  return stableChunkId(...parts).replace(/^chunk-/, "result-");
}

function readSearchIndexMetadataSync(filePath) {
  const size = statSync(filePath).size;
  if (size <= 10 * 1024 * 1024) return JSON.parse(readFileSync(filePath, "utf8"));
  const descriptor = openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(Math.min(size, 128 * 1024));
    const bytesRead = readSync(descriptor, buffer, 0, buffer.length, 0);
    const header = buffer.subarray(0, bytesRead).toString("utf8");
    return {
      builtAt: jsonHeaderString(header, "builtAt"),
      itemCount: jsonHeaderNumber(header, "itemCount"),
      chunkCount: jsonHeaderNumber(header, "chunkCount")
    };
  } finally {
    closeSync(descriptor);
  }
}

function jsonHeaderString(header, key) {
  const match = header.match(new RegExp(`"${key}"\\s*:\\s*("(?:[^"\\\\]|\\\\.)*")`));
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch { return null; }
}

function jsonHeaderNumber(header, key) {
  const match = header.match(new RegExp(`"${key}"\\s*:\\s*(\\d+)`));
  return match ? Number.parseInt(match[1], 10) : 0;
}

function scoreHit(text, query, index) {
  const basenameBoost = index < 200 ? 0.1 : 0;
  const lengthPenalty = Math.min(0.4, text.length / 100000);
  return Number((1 + basenameBoost - lengthPenalty + Math.min(0.5, query.length / 100)).toFixed(4));
}

function clampNumber(value, min, max, fallback) {
  const number = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}
