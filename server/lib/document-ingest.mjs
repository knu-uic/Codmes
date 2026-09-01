import crypto from "node:crypto";
import { constants as fsConstants } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  buildVlmOcrPrompt,
  callOllamaNativeVlm,
  callOpenAICompatibleVlm
} from "./vlm-runtime.mjs";

const DOCUMENT_EXTENSIONS = new Set([
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

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const WORKER_PATH = path.resolve(__dirname, "..", "workers", "document-ingest", "extract_document.py");
const VISION_OCR_PATH = path.resolve(__dirname, "..", "workers", "document-ingest", "ocr_vision.swift");
const PDF_NORMALIZER_PATH = path.resolve(__dirname, "..", "workers", "document-ingest", "normalize_pdf.py");
const DOCUMENT_INGEST_CACHE_VERSION = 3;

export function isDocumentIngestFile(relativePath) {
  return DOCUMENT_EXTENSIONS.has(path.extname(String(relativePath || "")).toLowerCase());
}

export function documentStateRootDirectory(workspaceRoot) {
  return path.join(workspaceRoot, ".codmes", "documents");
}

export function documentStateDirectory(workspaceRoot, relativePath) {
  const normalized = normalizeDocumentPath(relativePath);
  const parsed = path.posix.parse(normalized);
  const readableName = sanitizeDocumentDirectoryName(parsed.name || "document");
  const pathHash = crypto.createHash("sha256").update(normalized.normalize("NFC")).digest("hex").slice(0, 8);
  return path.join(documentStateRootDirectory(workspaceRoot), `${readableName}--${pathHash}`);
}

export function documentManifestPath(workspaceRoot, relativePath) {
  return path.join(documentStateDirectory(workspaceRoot, relativePath), "manifest.json");
}

export function documentIngestCacheDirectory(workspaceRoot, relativePath) {
  return path.join(documentStateDirectory(workspaceRoot, relativePath), "index");
}

export function documentIngestCachePath(workspaceRoot, relativePath, _stat = null) {
  return path.join(documentIngestCacheDirectory(workspaceRoot, relativePath), "extraction.json");
}

export function documentIngestMarkdownPath(workspaceRoot, relativePath, _stat = null) {
  return path.join(documentIngestCacheDirectory(workspaceRoot, relativePath), "content.md");
}

export function documentOriginalBackupPath(workspaceRoot, relativePath) {
  return path.join(documentStateDirectory(workspaceRoot, relativePath), "source", "original.pdf");
}

export async function ensureDocumentStateManifest(workspaceRoot, relativePath) {
  const normalized = normalizeDocumentPath(relativePath);
  const manifestPath = documentManifestPath(workspaceRoot, normalized);
  const manifest = {
    schemaVersion: 1,
    documentId: path.basename(documentStateDirectory(workspaceRoot, normalized)).split("--").at(-1),
    sourcePath: normalized,
    displayName: path.posix.basename(normalized),
    updatedAt: new Date().toISOString()
  };
  await fs.mkdir(path.dirname(manifestPath), { recursive: true });
  let existing = null;
  try { existing = JSON.parse(await fs.readFile(manifestPath, "utf8")); } catch {}
  if (existing?.sourcePath === normalized && existing?.displayName === manifest.displayName) return existing;
  await fs.writeFile(manifestPath, JSON.stringify({ ...existing, ...manifest }, null, 2) + "\n", "utf8");
  return manifest;
}

export async function removeDocumentIngestCacheFiles(workspaceRoot, relativePaths) {
  const targets = [].concat(relativePaths || [])
    .map(normalizeDocumentPath)
    .filter(Boolean);
  if (!targets.length) return { removed: 0 };
  const documentPaths = await matchingDocumentStatePaths(workspaceRoot, targets);
  const removals = [];
  for (const documentPath of documentPaths) {
    const indexDirectory = documentIngestCacheDirectory(workspaceRoot, documentPath);
    removals.push(fs.rm(indexDirectory, { recursive: true, force: true }));
  }
  const legacyRemoved = await removeLegacyDocumentCacheFiles(workspaceRoot, targets);
  await Promise.all(removals);
  return { removed: removals.length + legacyRemoved };
}

export async function pruneDocumentIngestCacheFiles(workspaceRoot) {
  const entries = await readDocumentStateManifests(workspaceRoot);
  const removals = [];
  for (const entry of entries) {
    const relativePath = normalizeDocumentPath(entry.manifest.sourcePath);
    if (!relativePath) continue;
    const absolutePath = path.join(workspaceRoot, ...relativePath.split("/"));
    const stat = await fs.stat(absolutePath).catch(() => null);
    if (!stat) {
      removals.push(fs.rm(path.join(entry.directory, "index"), { recursive: true, force: true }));
      continue;
    }
    let cached = null;
    try { cached = JSON.parse(await fs.readFile(documentIngestCachePath(workspaceRoot, relativePath), "utf8")); } catch {}
    if (!isCurrentDocumentCache(cached, relativePath, stat)) {
      removals.push(fs.rm(path.join(entry.directory, "index"), { recursive: true, force: true }));
    }
  }
  await Promise.all(removals);
  const legacyRemoved = await pruneLegacyDocumentCacheFiles(workspaceRoot);
  return { removed: removals.length + legacyRemoved };
}

export function annotationsPathForDocument(workspaceRoot, relativePath) {
  return path.join(documentStateDirectory(workspaceRoot, relativePath), "annotations.json");
}

export function documentFolderAnnotationsPathForDocument(workspaceRoot, relativePath) {
  const normalized = String(relativePath || "").replace(/\\/g, "/").replace(/^\/+/, "");
  const parsed = path.posix.parse(normalized);
  const stateName = `${parsed.name || "document"}.codmes.json`;
  return path.join(workspaceRoot, parsed.dir, ".codmes", "annotations", stateName);
}

export function contentScopedAnnotationsPathForDocument(workspaceRoot, relativePath) {
  const normalized = String(relativePath || "").replace(/\\/g, "/").replace(/^\/+/, "");
  const encoded = Buffer.from(normalized, "utf8").toString("base64url");
  const root = normalized.split("/").filter(Boolean)[0] || "";
  const stateRoot = ["Notes", "Documents", "Code", "Attachments"].includes(root)
    ? path.join(workspaceRoot, root, ".codmes")
    : path.join(workspaceRoot, ".codmes");
  return path.join(stateRoot, "annotations", `${encoded}.json`);
}

export function legacyAnnotationsPathForDocument(workspaceRoot, relativePath) {
  const encoded = Buffer.from(String(relativePath || "").replace(/\\/g, "/"), "utf8").toString("base64url");
  return path.join(workspaceRoot, ".codmes", "annotations", `${encoded}.json`);
}

export function annotationOcrCachePath(workspaceRoot, relativePath, contentHash) {
  return path.join(
    documentIngestCacheDirectory(workspaceRoot, relativePath),
    "annotation-ocr",
    `${String(contentHash || "").replace(/^sha256-/, "")}.json`
  );
}

export async function getDocumentIngestMetadata(workspaceRoot, absolutePath, relativePath, stat = null) {
  const fileStat = stat || await fs.stat(absolutePath);
  const cachePath = documentIngestCachePath(workspaceRoot, relativePath, fileStat);
  await migrateLegacyDocumentCache(workspaceRoot, relativePath, fileStat);
  let cached = false;
  let textLength = 0;
  let blockCount = 0;
  let tableCount = 0;
  let warnings = [];
  try {
    const cachedJson = JSON.parse(await fs.readFile(cachePath, "utf8"));
    if (isCurrentDocumentCache(cachedJson, relativePath, fileStat)) {
      cached = true;
      textLength = String(cachedJson.text || "").length;
      blockCount = Array.isArray(cachedJson.blocks) ? cachedJson.blocks.length : 0;
      tableCount = Array.isArray(cachedJson.tables) ? cachedJson.tables.length : 0;
      warnings = Array.isArray(cachedJson.warnings) ? cachedJson.warnings : [];
    }
  } catch {}
  return {
    type: "document-ingest",
    cached,
    textLength,
    blockCount,
    tableCount,
    warnings,
    cachePath: path.relative(workspaceRoot, cachePath).replace(/\\/g, "/"),
    markdownPath: path.relative(workspaceRoot, documentIngestMarkdownPath(workspaceRoot, relativePath)).replace(/\\/g, "/"),
    supported: isDocumentIngestFile(relativePath)
  };
}

export async function extractAndCacheDocumentText(workspaceRoot, absolutePath, relativePath, stat = null) {
  const result = await extractAndCacheDocument(workspaceRoot, absolutePath, relativePath, stat);
  return String(result.text || "");
}

export async function extractAndCacheDocument(workspaceRoot, absolutePath, relativePath, stat = null, options = {}) {
  const fileStat = stat || await fs.stat(absolutePath);
  const cachePath = documentIngestCachePath(workspaceRoot, relativePath, fileStat);
  const markdownPath = documentIngestMarkdownPath(workspaceRoot, relativePath, fileStat);
  await ensureDocumentStateManifest(workspaceRoot, relativePath);
  await migrateLegacyDocumentCache(workspaceRoot, relativePath, fileStat);
  try {
    const cached = JSON.parse(await fs.readFile(cachePath, "utf8"));
    if (isCurrentDocumentCache(cached, relativePath, fileStat)) {
      await ensureDocumentMarkdown(markdownPath, cached);
      return cached;
    }
  } catch {}
  await fs.rm(path.dirname(cachePath), { recursive: true, force: true });

  const result = await runDocumentWorker({ absolutePath, relativePath });
  const extracted = await maybeEnhanceWithOcr(
    workspaceRoot,
    absolutePath,
    relativePath,
    normalizeWorkerResult(result, relativePath),
    options
  );
  const normalized = {
    ...extracted,
    cache: documentCacheIdentity(relativePath, fileStat)
  };
  await fs.mkdir(path.dirname(cachePath), { recursive: true });
  await fs.writeFile(cachePath, JSON.stringify(normalized, null, 2) + "\n", "utf8");
  await fs.writeFile(markdownPath, documentMarkdown(normalized), "utf8");
  return normalized;
}

export async function normalizePdfBinaryTextLayer(workspaceRoot, absolutePath, relativePath, options = {}) {
  if (path.extname(String(relativePath || "")).toLowerCase() !== ".pdf") {
    return { normalized: false, reason: "not-pdf", pages: [] };
  }
  options.onProgress?.({
    stage: "inspecting",
    stageLabel: "PDF 텍스트 검사 중",
    progress: 0.04
  });
  const document = await extractAndCacheDocument(workspaceRoot, absolutePath, relativePath, null, {
    onProgress: ({ completed, total }) => options.onProgress?.({
      stage: "ocr",
      stageLabel: "OCR 좌표 분석 중",
      progress: 0.08 + 0.57 * completed / Math.max(1, total),
      completedUnits: completed,
      totalUnits: total
    })
  });
  let positionedBlocks = (document.blocks || []).filter((block) => (
    String(block.source || "").includes("ocr")
    && Array.isArray(block.metadata?.lines)
    && block.metadata.lines.length
  ));
  const ocrPages = Array.from(new Set((document.blocks || [])
    .filter((block) => String(block.source || "").includes("ocr"))
    .map((block) => Number(block.page))
    .filter((page) => Number.isFinite(page) && page > 0)))
    .sort((a, b) => a - b);
  if (!positionedBlocks.length && ocrPages.length && process.platform === "darwin") {
    const highestKnownPage = Math.max(
      ...((document.blocks || []).map((block) => Number(block.page)).filter(Number.isFinite)),
      ...ocrPages
    );
    const requestedPages = highestKnownPage > 0 && ocrPages.length / highestKnownPage >= 0.25
      ? []
      : ocrPages;
    const native = await runNativeVisionOcr({
      absolutePath,
      relativePath,
      pages: requestedPages,
      dpi: "150",
      onProgress: ({ completed, total }) => options.onProgress?.({
        stage: "ocr",
        stageLabel: "OCR 좌표 분석 중",
        progress: 0.08 + 0.57 * completed / Math.max(1, total),
        completedUnits: completed,
        totalUnits: total
      })
    });
    positionedBlocks = native.blocks;
  }
  if (!positionedBlocks.length) {
    return {
      normalized: false,
      reason: ocrPages.length ? "ocr-has-no-coordinates" : "text-layer-ok",
      pages: []
    };
  }

  const temporaryPath = path.join(
    path.dirname(absolutePath),
    `.${path.basename(absolutePath)}.codmes-ocr-${crypto.randomUUID()}.tmp`
  );
  try {
    options.onProgress?.({
      stage: "rewriting",
      stageLabel: "PDF 텍스트 레이어 작성 중",
      progress: 0.66,
      completedUnits: 0,
      totalUnits: null
    });
    const result = await writePdfOcrTextLayer(absolutePath, temporaryPath, positionedBlocks, {
      onProgress: ({ completed, total }) => options.onProgress?.({
        stage: "rewriting",
        stageLabel: "PDF 텍스트 레이어 작성 중",
        progress: 0.66 + 0.27 * completed / Math.max(1, total),
        completedUnits: completed,
        totalUnits: total
      })
    });
    const backupPath = documentOriginalBackupPath(workspaceRoot, relativePath);
    await fs.mkdir(path.dirname(backupPath), { recursive: true });
    try {
      await fs.link(absolutePath, backupPath);
    } catch (error) {
      if (error?.code !== "EEXIST") {
        await fs.copyFile(absolutePath, backupPath, fsConstants.COPYFILE_EXCL).catch((copyError) => {
          if (copyError?.code !== "EEXIST") throw copyError;
        });
      }
    }
    await fs.rename(temporaryPath, absolutePath);
    await fs.rm(documentIngestCacheDirectory(workspaceRoot, relativePath), { recursive: true, force: true });
    await ensureDocumentStateManifest(workspaceRoot, relativePath);
    options.onProgress?.({
      stage: "verifying",
      stageLabel: "PDF 검증 중",
      progress: 0.94,
      completedUnits: result.pageCount || null,
      totalUnits: result.pageCount || null
    });
    return {
      normalized: true,
      reason: "embedded-ocr-text-layer",
      pages: result.normalizedPages || [],
      pageCount: result.pageCount || null,
      extractedChars: result.extractedChars || 0,
      backupPath: path.relative(workspaceRoot, backupPath).replace(/\\/g, "/")
    };
  } catch (error) {
    await fs.rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function ensureDocumentMarkdown(markdownPath, document) {
  try {
    await fs.access(markdownPath);
  } catch {
    await fs.writeFile(markdownPath, documentMarkdown(document), "utf8");
  }
}

function documentMarkdown(document = {}) {
  const markdown = String(document.markdown || document.text || "").trim();
  return markdown ? `${markdown}\n` : "";
}

export async function extractDocumentAnnotationBlocks(workspaceRoot, relativePath) {
  const config = await readVlmSearchConfig(workspaceRoot);
  const annotations = await readAnnotationsForDocument(workspaceRoot, relativePath);
  if (!annotations) return [];
  const blocks = [];
  const allObjects = collectAnnotationObjects(annotations);
  for (const object of allObjects) {
    const type = String(object.type || "").toLowerCase();
    if (type === "text" || type === "textbox" || type === "text-box") {
      const text = String(object.text || "").trim();
      if (text) {
        blocks.push(annotationBlock(relativePath, object, text, "annotation-text"));
      }
      continue;
    }
    if (!["image", "sticker", "photo", "attachment-image"].includes(type)) continue;
    const existingText = String(object.text || object.metadata?.ocrText || "").trim();
    if (existingText) {
      blocks.push(annotationBlock(relativePath, object, existingText, "annotation-image-ocr"));
      continue;
    }
    if (!config.enabled || !object.dataBase64) continue;
    try {
      const mime = object.metadata?.mime || object.metadata?.contentType || "image/png";
      const dataBase64 = String(object.dataBase64).replace(/^data:[^,]+,/, "");
      const contentHash = annotationImageContentHash(object, dataBase64);
      const ocr = await readOrCreateAnnotationImageOcr(workspaceRoot, relativePath, config, {
        contentHash,
        mime,
        dataBase64
      });
      const text = ocr.text || "";
      if (text.trim()) {
        blocks.push(annotationBlock(relativePath, object, text.trim(), "annotation-image-ocr", {
          contentHash,
          provider: ocr.provider || config.provider,
          model: ocr.model || config.model,
          deterministic: true,
          temperature: 0,
          thinking: "off",
          cached: Boolean(ocr.cached)
        }));
      }
    } catch {
      // Annotation OCR is opportunistic. The main document text should remain searchable.
    }
  }
  return blocks;
}

async function readOrCreateAnnotationImageOcr(workspaceRoot, relativePath, config, { contentHash, mime, dataBase64 }) {
  const cachePath = annotationOcrCachePath(workspaceRoot, relativePath, contentHash);
  try {
    const cached = JSON.parse(await fs.readFile(cachePath, "utf8"));
    if (String(cached.text || "").trim()) {
      return { ...cached, cached: true };
    }
  } catch {}
  const legacyPath = path.join(
    workspaceRoot,
    ".codmes",
    "index",
    "annotation-ocr",
    `${String(contentHash || "").replace(/^sha256-/, "")}.json`
  );
  try {
    const cached = JSON.parse(await fs.readFile(legacyPath, "utf8"));
    if (String(cached.text || "").trim()) {
      await ensureDocumentStateManifest(workspaceRoot, relativePath);
      await fs.mkdir(path.dirname(cachePath), { recursive: true });
      await fs.writeFile(cachePath, JSON.stringify(cached, null, 2) + "\n", "utf8");
      await fs.rm(legacyPath, { force: true });
      return { ...cached, cached: true };
    }
  } catch {}
  const text = await callConfiguredVlm(config, {
    prompt: buildVlmOcrPrompt({
      language: config.language || "auto",
      output: "markdown"
    }),
    imageBase64: dataBase64,
    imageUrl: `data:${mime};base64,${dataBase64}`
  });
  const result = {
    schemaVersion: 1,
    contentHash,
    text: String(text || "").trim(),
    provider: config.provider,
    model: config.model,
    mime,
    updatedAt: new Date().toISOString(),
    deterministic: true,
    temperature: 0,
    thinking: "off"
  };
  await fs.mkdir(path.dirname(cachePath), { recursive: true });
  await fs.writeFile(cachePath, JSON.stringify(result, null, 2) + "\n", "utf8");
  return { ...result, cached: false };
}

function annotationImageContentHash(object, dataBase64) {
  const existing = object.metadata?.contentHash || object.contentHash;
  if (existing) return String(existing);
  return `sha256-${crypto.createHash("sha256").update(String(dataBase64 || "")).digest("hex")}`;
}

async function runDocumentWorker({ absolutePath, relativePath }) {
  const python = await documentWorkerPython();
  const stdout = [];
  const stderr = [];
  const child = spawn(python, [
    WORKER_PATH,
    "--input",
    absolutePath,
    "--relative",
    relativePath
  ], {
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env
  });
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });
  const out = Buffer.concat(stdout).toString("utf8").trim();
  const err = Buffer.concat(stderr).toString("utf8").trim();
  if (code !== 0 && !out) {
    throw Object.assign(new Error(`Document worker failed: ${err || `exit ${code}`}`), { status: 500 });
  }
  try {
    return parseDocumentWorkerOutput(out);
  } catch (error) {
    throw Object.assign(new Error(`Document worker returned invalid JSON: ${error.message}${err ? `; stderr=${err}` : ""}`), { status: 500 });
  }
}

export function parseDocumentWorkerOutput(output) {
  const text = String(output || "").trim();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch (wholeOutputError) {
    // Some optional native extractors print one-line startup warnings to stdout.
    // The worker contract remains the final JSON line; never treat warning text as
    // document data and still reject output that has no valid JSON result.
    const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      try {
        return JSON.parse(lines[index]);
      } catch {
        // Continue looking for the worker's final structured result.
      }
    }
    throw wholeOutputError;
  }
}

async function documentWorkerPython() {
  if (process.env.CODMES_PYTHON) return process.env.CODMES_PYTHON;
  if (process.env.PYTHON) return process.env.PYTHON;
  const bundledCandidates = process.platform === "win32"
    ? ["python.exe", "Scripts/python.exe"]
    : ["bin/python"];
  for (const relativePath of bundledCandidates) {
    const bundled = path.join(REPO_ROOT, ".codmes-runtime", relativePath);
    try {
      await fs.access(bundled);
      return bundled;
    } catch {}
  }
  return "python3";
}

async function maybeEnhanceWithOcr(workspaceRoot, absolutePath, relativePath, document, options = {}) {
  const config = await readVlmSearchConfig(workspaceRoot);
  const ocrPages = pagesNeedingOcr(relativePath, document, config);
  if (ocrPages === null) return document;

  const warnings = [...(document.warnings || [])];
  if (!config.enabled && config.nativeEnabled && process.platform === "darwin") {
    try {
      const native = await runNativeVisionOcr({
        absolutePath,
        relativePath,
        pages: ocrPages,
        dpi: config.dpi,
        onProgress: options.onProgress
      });
      warnings.push(...native.warnings);
      if (native.blocks.length) {
        return mergeOcrBlocks(document, native.blocks, ocrPages, warnings, "vision-ocr");
      }
      warnings.push("Native Vision OCR returned no text.");
    } catch (error) {
      warnings.push(`Native Vision OCR skipped: ${error.message}`);
    }
    return { ...document, warnings };
  }
  if (!config.enabled) {
    warnings.push("OCR is required for this PDF, but no local or VLM OCR engine is available.");
    return { ...document, warnings };
  }

  const vlmBlocks = [];
  try {
    const inputs = await buildVlmInputs(workspaceRoot, absolutePath, relativePath, config, ocrPages);
    const prompt = buildVlmOcrPrompt({
      language: config.language || "auto",
      output: "markdown"
    });
    for (const [inputIndex, input] of inputs.entries()) {
      const text = await callConfiguredVlm(config, {
        prompt,
        imageBase64: input.base64,
        imageUrl: input.dataUrl
      });
      if (!text.trim()) continue;
      vlmBlocks.push({
        id: `vlm-page-${input.page || 1}`,
        path: relativePath,
        kind: kindForRelativePath(relativePath),
        source: "vlm-ocr",
        page: input.page,
        text: text.trim(),
        bbox: null,
        confidence: null,
        metadata: {
          provider: config.provider,
          model: config.model,
          imageMime: input.mime,
          deterministic: true,
          temperature: 0,
          thinking: "off"
        }
      });
      options.onProgress?.({
        completed: inputIndex + 1,
        total: inputs.length,
        page: input.page
      });
    }
  } catch (error) {
    warnings.push(`VLM OCR skipped: ${error.message}`);
  }

  if (!vlmBlocks.length) {
    return { ...document, warnings };
  }
  return mergeOcrBlocks(document, vlmBlocks, ocrPages, warnings, "vlm-ocr");
}

async function readAnnotationsForDocument(workspaceRoot, relativePath) {
  const primaryPath = annotationsPathForDocument(workspaceRoot, relativePath);
  try {
    const annotations = JSON.parse(await fs.readFile(primaryPath, "utf8"));
    await ensureDocumentStateManifest(workspaceRoot, relativePath);
    return annotations;
  } catch (error) {
    if (error?.code !== "ENOENT") return null;
  }

  for (const legacyPath of [
    documentFolderAnnotationsPathForDocument(workspaceRoot, relativePath),
    contentScopedAnnotationsPathForDocument(workspaceRoot, relativePath),
    legacyAnnotationsPathForDocument(workspaceRoot, relativePath)
  ]) {
    if (legacyPath === primaryPath) continue;
    try {
      const raw = await fs.readFile(legacyPath, "utf8");
      const parsed = JSON.parse(raw);
      await fs.mkdir(path.dirname(primaryPath), { recursive: true });
      await fs.writeFile(primaryPath, raw, { flag: "wx" }).catch((error) => {
        if (error?.code !== "EEXIST") throw error;
      });
      await ensureDocumentStateManifest(workspaceRoot, relativePath);
      const persisted = JSON.parse(await fs.readFile(primaryPath, "utf8"));
      await fs.rm(legacyPath, { force: true });
      return persisted || parsed;
    } catch (error) {
      if (error?.code !== "ENOENT") return null;
    }
  }
  return null;
}

function collectAnnotationObjects(annotations = {}) {
  const rootObjects = Array.isArray(annotations.objects) ? annotations.objects : [];
  const seenIds = new Set(rootObjects.map((object) => object?.id).filter(Boolean));
  const pageObjects = [];
  for (const page of Array.isArray(annotations.pages) ? annotations.pages : []) {
    for (const object of Array.isArray(page.objects) ? page.objects : []) {
      if (object?.id) seenIds.add(object.id);
      pageObjects.push({
        ...object,
        pageIndex: object.pageIndex ?? page.pageIndex
      });
    }
    for (const element of Array.isArray(page.elements) ? page.elements : []) {
      if (typeof element.text === "string" && element.text.trim() && !seenIds.has(element.id)) {
        if (element.id) seenIds.add(element.id);
        pageObjects.push({
          ...element,
          pageIndex: element.pageIndex ?? page.pageIndex,
          type: element.type || "text"
        });
      }
    }
  }
  const rootElements = [];
  for (const element of Array.isArray(annotations.elements) ? annotations.elements : []) {
    if (typeof element.text === "string" && element.text.trim() && !seenIds.has(element.id)) {
      if (element.id) seenIds.add(element.id);
      rootElements.push({
        ...element,
        type: element.type || "text"
      });
    }
  }
  return [...rootObjects, ...rootElements, ...pageObjects];
}

function annotationBlock(relativePath, object, text, source, metadata = {}) {
  return {
    id: object.id || `${source}-${Math.random().toString(36).slice(2)}`,
    path: relativePath,
    kind: "pdf",
    source,
    page: Number.isFinite(Number(object.pageIndex)) ? Number(object.pageIndex) + 1 : null,
    text: String(text || "").trim(),
    bbox: object.bbox || null,
    confidence: null,
    metadata: {
      annotationId: object.id || "",
      annotationType: object.type || "",
      ...(object.metadata || {}),
      ...metadata
    }
  };
}

function pagesNeedingOcr(relativePath, document, config) {
  const kind = kindForRelativePath(relativePath);
  if (kind === "image") return [];
  if (kind !== "pdf") return null;
  const minTextChars = Number.parseInt(String(config.minTextChars || "80"), 10);
  const text = stripPdfLayoutMarkers(document.text).trim();
  if (!text) return [];
  if (config.enabled && text.length < Math.max(0, minTextChars)) return [];
  const pageText = new Map();
  for (const block of document.blocks || []) {
    const page = Number(block.page);
    if (!Number.isFinite(page) || page < 1) continue;
    pageText.set(page, [pageText.get(page), stripPdfLayoutMarkers(block.text)].filter(Boolean).join("\n"));
  }
  if (!pageText.size) return pdfTextNeedsOcr(text) ? [] : null;
  const pages = Array.from(pageText)
    .filter(([, value]) => pdfTextNeedsOcr(value))
    .map(([page]) => page)
    .sort((a, b) => a - b);
  if (pages.length / pageText.size >= 0.25) {
    return Array.from(pageText.keys()).sort((a, b) => a - b);
  }
  return pages.length ? pages : null;
}

export function pdfTextNeedsOcr(value) {
  const text = stripPdfLayoutMarkers(value).normalize("NFC");
  const characters = Array.from(text).filter((character) => !/\s/u.test(character));
  if (characters.length < 20) return false;
  let cjkIdeographs = 0;
  let privateOrInvalid = 0;
  for (const character of characters) {
    const code = character.codePointAt(0);
    if (
      (code >= 0x3400 && code <= 0x4dbf)
      || (code >= 0x4e00 && code <= 0x9fff)
      || (code >= 0xf900 && code <= 0xfaff)
    ) cjkIdeographs += 1;
    if (
      character === "\uFFFD"
      || (code >= 0xe000 && code <= 0xf8ff)
      || (code < 0x20 && !["\n", "\r", "\t"].includes(character))
    ) privateOrInvalid += 1;
  }
  const suspiciousFSeparators = (text.match(/[\p{Script=Hangul}\p{Script=Han}]f(?=[\p{Script=Hangul}\p{Script=Han}\s])/gu) || []).length;
  const length = characters.length;
  return privateOrInvalid / length >= 0.005
    || cjkIdeographs / length >= 0.08
    || suspiciousFSeparators / length >= 0.025;
}

function stripPdfLayoutMarkers(value) {
  return String(value || "").replace(
    /^\s*---\s*(?:end|start) of page\.page_number=\d+\s*---\s*$/gim,
    ""
  );
}

async function buildVlmInputs(workspaceRoot, absolutePath, relativePath, config, pages = []) {
  const kind = kindForRelativePath(relativePath);
  if (kind === "image") {
    const data = await fs.readFile(absolutePath);
    const mime = imageMimeForPath(relativePath);
    return [{
      page: null,
      mime,
      base64: data.toString("base64"),
      dataUrl: `data:${mime};base64,${data.toString("base64")}`
    }];
  }
  if (kind === "pdf") {
    return await renderPdfPageImagesForVlm(workspaceRoot, absolutePath, relativePath, config, pages);
  }
  return [];
}

async function renderPdfPageImagesForVlm(workspaceRoot, absolutePath, relativePath, config, pages = []) {
  const python = await documentWorkerPython();
  const maxPages = clampNumber(config.maxPages, 1, 200, 40);
  const dpi = clampNumber(config.dpi, 96, 240, 150);
  const renderDir = documentVlmRenderDirectory(workspaceRoot, relativePath);
  await fs.rm(renderDir, { recursive: true, force: true });
  await fs.mkdir(renderDir, { recursive: true });
  const script = `
import fitz, json, os, sys
pdf_path, out_dir, max_pages, dpi, requested = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
doc = fitz.open(pdf_path)
items = []
matrix = fitz.Matrix(dpi / 72, dpi / 72)
requested_pages = {int(value) for value in requested.split(",") if value}
for index, page in enumerate(doc, start=1):
    if requested_pages and index not in requested_pages:
        continue
    if len(items) >= max_pages:
        break
    pix = page.get_pixmap(matrix=matrix, alpha=False)
    out = os.path.join(out_dir, f"page-{index:04d}.png")
    pix.save(out)
    items.append({"page": index, "path": out, "width": pix.width, "height": pix.height})
doc.close()
print(json.dumps(items))
`;
  const stdout = [];
  const stderr = [];
  const child = spawn(python, ["-c", script, absolutePath, renderDir, String(maxPages), String(dpi), pages.join(",")], {
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env
  });
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });
  if (code !== 0) {
    throw new Error(`PDF page rendering failed: ${Buffer.concat(stderr).toString("utf8").trim() || `exit ${code}`}`);
  }
  const items = parseDocumentWorkerOutput(Buffer.concat(stdout).toString("utf8") || "[]");
  const inputs = [];
  for (const item of items) {
    const data = await fs.readFile(item.path);
    const base64 = data.toString("base64");
    inputs.push({
      page: item.page,
      mime: "image/png",
      base64,
      dataUrl: `data:image/png;base64,${base64}`
    });
  }
  return inputs;
}

async function runNativeVisionOcr({ absolutePath, relativePath, pages, dpi, onProgress }) {
  const kind = kindForRelativePath(relativePath);
  const stdout = [];
  const stderr = progressLineCollector(onProgress);
  const child = spawn("/usr/bin/swift", [
    VISION_OCR_PATH,
    absolutePath,
    pages.join(","),
    String(clampNumber(dpi, 96, 240, 150))
  ], {
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env
  });
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.write(chunk));
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });
  const err = stderr.end();
  if (code !== 0) throw new Error(err || `Vision OCR exited with ${code}.`);
  const result = parseDocumentWorkerOutput(Buffer.concat(stdout).toString("utf8") || "{}");
  return {
    blocks: (Array.isArray(result.blocks) ? result.blocks : [])
      .map((block, index) => ({
        id: `vision-ocr-page-${Number(block.page) || index + 1}`,
        path: relativePath,
        kind,
        source: "vision-ocr",
        page: Number(block.page) || null,
        text: String(block.text || "").normalize("NFC").trim(),
        bbox: null,
        confidence: null,
        metadata: {
          engine: "apple-vision",
          deterministic: true,
          languages: ["ko-KR", "en-US"],
          lines: (Array.isArray(block.lines) ? block.lines : [])
            .map((line) => ({
              text: String(line.text || "").normalize("NFC").trim(),
              bbox: normalizeOcrBox(line.bbox)
            }))
            .filter((line) => line.text && line.bbox)
        }
      }))
      .filter((block) => block.text),
    warnings: (Array.isArray(result.warnings) ? result.warnings : []).map(String)
  };
}

export function normalizeOcrBox(value) {
  const numbers = ["x", "y", "width", "height"].map((key) => Number(value?.[key]));
  if (!numbers.every(Number.isFinite)) return null;
  return {
    x: clampDecimal(numbers[0], 0, 1, 0),
    y: clampDecimal(numbers[1], 0, 1, 0),
    width: clampDecimal(numbers[2], 0, 1, 0),
    height: clampDecimal(numbers[3], 0, 1, 0)
  };
}

export async function writePdfOcrTextLayer(inputPath, outputPath, blocks, options = {}) {
  const python = await documentWorkerPython();
  const stdout = [];
  const stderr = progressLineCollector(options.onProgress);
  const child = spawn(python, [PDF_NORMALIZER_PATH, inputPath, outputPath, "150"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env
  });
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.write(chunk));
  child.stdin.end(JSON.stringify({
    blocks: blocks.map((block) => ({
      page: block.page,
      text: block.text,
      lines: block.metadata?.lines || []
    }))
  }));
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });
  const err = stderr.end();
  if (code !== 0) throw new Error(err || `PDF OCR normalization exited with ${code}.`);
  return parseDocumentWorkerOutput(Buffer.concat(stdout).toString("utf8") || "{}");
}

function progressLineCollector(onProgress) {
  let pending = "";
  const messages = [];
  const consume = (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const value = JSON.parse(trimmed);
      if (value?.type === "progress") {
        onProgress?.({
          completed: Number(value.completed) || 0,
          total: Number(value.total) || 0,
          page: Number(value.page) || null
        });
        return;
      }
    } catch {}
    messages.push(trimmed);
  };
  return {
    write(chunk) {
      pending += chunk.toString("utf8");
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() || "";
      lines.forEach(consume);
    },
    end() {
      consume(pending);
      pending = "";
      return messages.join("\n");
    }
  };
}

function mergeOcrBlocks(document, ocrBlocks, pages, warnings, engine) {
  const selectedPages = new Set(pages);
  const replaceAllPdfText = pages.length === 0;
  const retained = (document.blocks || []).filter((block) => {
    if (document.kind === "image" && replaceAllPdfText) return false;
    if (!String(block.source || "").startsWith("pdf-")) return true;
    if (replaceAllPdfText) return false;
    return !selectedPages.has(Number(block.page));
  });
  const blocks = [...retained, ...ocrBlocks].sort((a, b) => (
    (Number(a.page) || Number.MAX_SAFE_INTEGER) - (Number(b.page) || Number.MAX_SAFE_INTEGER)
    || String(a.id || "").localeCompare(String(b.id || ""))
  ));
  const text = blocks.map((block) => String(block.text || "").trim()).filter(Boolean).join("\n\n").trim();
  return {
    ...document,
    text,
    markdown: text,
    blocks,
    warnings,
    extractor: `${document.extractor || "codmes-document-worker"}+${engine}`
  };
}

function documentVlmRenderDirectory(workspaceRoot, relativePath) {
  return path.join(documentIngestCacheDirectory(workspaceRoot, relativePath), "vlm-pages");
}

function normalizeDocumentPath(value) {
  return String(value || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
}

function sanitizeDocumentDirectoryName(value) {
  const normalized = String(value || "document").normalize("NFC")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
    .replace(/\s+/g, " ")
    .replace(/[. ]+$/g, "")
    .trim();
  return Array.from(normalized || "document").slice(0, 80).join("");
}

function documentCacheIdentity(relativePath, stat) {
  return {
    version: DOCUMENT_INGEST_CACHE_VERSION,
    sourcePath: normalizeDocumentPath(relativePath),
    size: Number(stat?.size || 0),
    mtimeMs: Number(stat?.mtimeMs || 0)
  };
}

function isCurrentDocumentCache(cached, relativePath, stat) {
  const expected = documentCacheIdentity(relativePath, stat);
  return Number(cached?.schemaVersion) === DOCUMENT_INGEST_CACHE_VERSION
    && Number(cached?.cache?.version) === expected.version
    && normalizeDocumentPath(cached?.cache?.sourcePath || cached?.path) === expected.sourcePath
    && Number(cached?.cache?.size) === expected.size
    && Number(cached?.cache?.mtimeMs) === expected.mtimeMs;
}

function legacyDocumentIngestCacheDirectory(workspaceRoot) {
  return path.join(workspaceRoot, ".codmes", "index", "documents");
}

function legacyDocumentIngestCachePath(workspaceRoot, relativePath, stat, version = DOCUMENT_INGEST_CACHE_VERSION) {
  const stamp = stat ? `${stat.size}:${stat.mtimeMs}` : "";
  const normalized = normalizeDocumentPath(relativePath);
  const input = version === 1 ? `${normalized}\n${stamp}` : `v${version}\n${normalized}\n${stamp}`;
  const key = crypto.createHash("sha256").update(input).digest("hex");
  return path.join(legacyDocumentIngestCacheDirectory(workspaceRoot), `${key}.json`);
}

async function migrateLegacyDocumentCache(workspaceRoot, relativePath, stat) {
  const targetPath = documentIngestCachePath(workspaceRoot, relativePath);
  try {
    const current = JSON.parse(await fs.readFile(targetPath, "utf8"));
    if (isCurrentDocumentCache(current, relativePath, stat)) return current;
  } catch {}

  const legacyPath = legacyDocumentIngestCachePath(workspaceRoot, relativePath, stat);
  let legacy = null;
  try { legacy = JSON.parse(await fs.readFile(legacyPath, "utf8")); } catch {}
  if (!legacy || Number(legacy.schemaVersion) !== DOCUMENT_INGEST_CACHE_VERSION) return null;

  const migrated = { ...legacy, cache: documentCacheIdentity(relativePath, stat) };
  const markdownPath = documentIngestMarkdownPath(workspaceRoot, relativePath);
  await ensureDocumentStateManifest(workspaceRoot, relativePath);
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, JSON.stringify(migrated, null, 2) + "\n", "utf8");
  const legacyMarkdownPath = legacyPath.replace(/\.json$/, ".md");
  const markdown = await fs.readFile(legacyMarkdownPath, "utf8").catch(() => documentMarkdown(migrated));
  await fs.writeFile(markdownPath, markdown, "utf8");
  await removeLegacyDocumentCacheFiles(workspaceRoot, [relativePath]);
  return migrated;
}

async function readDocumentStateManifests(workspaceRoot) {
  const root = documentStateRootDirectory(workspaceRoot);
  const entries = await fs.readdir(root, { withFileTypes: true }).catch(() => []);
  const results = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const directory = path.join(root, entry.name);
    try {
      const manifest = JSON.parse(await fs.readFile(path.join(directory, "manifest.json"), "utf8"));
      results.push({ directory, manifest });
    } catch {}
  }
  return results;
}

async function matchingDocumentStatePaths(workspaceRoot, targets) {
  const paths = new Set();
  for (const target of targets) {
    if (path.posix.extname(target)) paths.add(target);
  }
  for (const entry of await readDocumentStateManifests(workspaceRoot)) {
    const sourcePath = normalizeDocumentPath(entry.manifest.sourcePath);
    if (targets.some((target) => sourcePath === target || sourcePath.startsWith(`${target}/`))) paths.add(sourcePath);
  }
  return paths;
}

async function removeLegacyDocumentCacheFiles(workspaceRoot, targets) {
  const directory = legacyDocumentIngestCacheDirectory(workspaceRoot);
  const entries = await fs.readdir(directory, { withFileTypes: true }).catch(() => []);
  const removals = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    const jsonPath = path.join(directory, entry.name);
    let cached = null;
    try { cached = JSON.parse(await fs.readFile(jsonPath, "utf8")); } catch {}
    const sourcePath = normalizeDocumentPath(cached?.path);
    if (!sourcePath || !targets.some((target) => sourcePath === target || sourcePath.startsWith(`${target}/`))) continue;
    removals.push(fs.rm(jsonPath, { force: true }));
    removals.push(fs.rm(jsonPath.replace(/\.json$/, ".md"), { force: true }));
  }
  await Promise.all(removals);
  return removals.length;
}

async function pruneLegacyDocumentCacheFiles(workspaceRoot) {
  const directory = legacyDocumentIngestCacheDirectory(workspaceRoot);
  const entries = await fs.readdir(directory, { withFileTypes: true }).catch(() => []);
  const removals = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    const jsonPath = path.join(directory, entry.name);
    let cached = null;
    try { cached = JSON.parse(await fs.readFile(jsonPath, "utf8")); } catch {}
    const sourcePath = normalizeDocumentPath(cached?.path);
    if (!sourcePath) continue;
    const absolutePath = path.join(workspaceRoot, ...sourcePath.split("/"));
    const sourceExists = await fs.stat(absolutePath).then(() => true).catch(() => false);
    const migratedExists = await fs.stat(documentIngestCachePath(workspaceRoot, sourcePath)).then(() => true).catch(() => false);
    if (sourceExists && !migratedExists) continue;
    removals.push(fs.rm(jsonPath, { force: true }));
    removals.push(fs.rm(jsonPath.replace(/\.json$/, ".md"), { force: true }));
  }
  await Promise.all(removals);
  return removals.length;
}

async function callConfiguredVlm(config, input) {
  const provider = String(config.provider || "").toLowerCase();
  if (provider.includes("ollama") && config.useOllamaNative) {
    return await callOllamaNativeVlm({
      baseUrl: config.baseUrl,
      model: config.model,
      prompt: input.prompt,
      imageBase64: input.imageBase64,
      maxTokens: config.maxTokens
    });
  }
  return await callOpenAICompatibleVlm({
    baseUrl: config.baseUrl,
    apiKey: config.apiKey,
    model: config.model,
    prompt: input.prompt,
    imageUrl: input.imageUrl,
    maxTokens: config.maxTokens
  });
}

async function readVlmSearchConfig(workspaceRoot) {
  const env = await readEnvFile(path.join(workspaceRoot, ".codmes", "config", "search.env"));
  const provider = env.VLM_PROVIDER || process.env.CODMES_VLM_PROVIDER || "";
  const model = env.VLM_MODEL || process.env.CODMES_VLM_MODEL || "";
  const baseUrl = env.VLM_BASE_URL || process.env.CODMES_VLM_BASE_URL || "";
  return {
    enabled: Boolean(model && baseUrl),
    provider,
    model,
    baseUrl,
    apiKey: env.VLM_API_KEY || process.env.CODMES_VLM_API_KEY || "",
    maxTokens: env.VLM_MAX_TOKENS || process.env.CODMES_VLM_MAX_TOKENS || "800",
    maxPages: env.VLM_MAX_PAGES || process.env.CODMES_VLM_MAX_PAGES || "40",
    dpi: env.VLM_RENDER_DPI || process.env.CODMES_VLM_RENDER_DPI || "150",
    minTextChars: env.VLM_MIN_TEXT_CHARS || process.env.CODMES_VLM_MIN_TEXT_CHARS || "80",
    language: env.VLM_LANGUAGE || process.env.CODMES_VLM_LANGUAGE || "auto",
    nativeEnabled: !["false", "0", "no", "off"].includes(
      String(env.NATIVE_OCR_ENABLED || process.env.CODMES_NATIVE_OCR_ENABLED || "true").toLowerCase()
    ),
    useOllamaNative: ["true", "1", "yes", "on"].includes(String(env.VLM_OLLAMA_NATIVE || process.env.CODMES_VLM_OLLAMA_NATIVE || "").toLowerCase())
  };
}

async function readEnvFile(filePath) {
  try {
    const content = await fs.readFile(filePath, "utf8");
    const result = {};
    for (const line of content.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const index = trimmed.indexOf("=");
      if (index === -1) continue;
      result[trimmed.slice(0, index)] = trimmed.slice(index + 1);
    }
    return result;
  } catch {
    return {};
  }
}

function kindForRelativePath(relativePath) {
  const ext = path.extname(String(relativePath || "").toLowerCase());
  if (ext === ".pdf") return "pdf";
  if ([".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic"].includes(ext)) return "image";
  if ([".xlsx", ".xls"].includes(ext)) return "spreadsheet";
  if ([".doc", ".docx", ".ppt", ".pptx", ".hwp", ".hwpx", ".odt", ".odp"].includes(ext)) return "document";
  return "file";
}

function imageMimeForPath(relativePath) {
  const ext = path.extname(String(relativePath || "").toLowerCase());
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".webp") return "image/webp";
  if (ext === ".gif") return "image/gif";
  if (ext === ".bmp") return "image/bmp";
  if (ext === ".tif" || ext === ".tiff") return "image/tiff";
  return "image/png";
}

function clampNumber(value, min, max, fallback) {
  const number = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

function clampDecimal(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

function normalizeWorkerResult(result = {}, relativePath) {
  const blocks = Array.isArray(result.blocks)
    ? result.blocks.map((block, index) => ({
      id: block.id || `block-${index + 1}`,
      path: String(block.path || relativePath),
      kind: String(block.kind || result.kind || "file"),
      source: String(block.source || "document"),
      page: Number.isFinite(Number(block.page)) ? Number(block.page) : null,
      text: String(block.text || ""),
      bbox: block.bbox || null,
      confidence: block.confidence ?? null,
      metadata: block.metadata && typeof block.metadata === "object" ? block.metadata : {}
    })).filter((block) => block.text.trim())
    : [];
  const tables = Array.isArray(result.tables)
    ? result.tables.map((table, index) => ({
      id: String(table.id || `table-${index + 1}`),
      path: String(table.path || relativePath),
      source: String(table.source || "document-table"),
      page: Number.isFinite(Number(table.page)) ? Number(table.page) : null,
      headers: Array.isArray(table.headers) ? table.headers.map((value) => String(value || "")) : [],
      rows: Array.isArray(table.rows)
        ? table.rows.map((row) => Array.isArray(row) ? row.map((value) => String(value || "")) : [])
        : [],
      markdown: String(table.markdown || ""),
      bbox: table.bbox || null,
      metadata: table.metadata && typeof table.metadata === "object" ? table.metadata : {}
    })).filter((table) => table.headers.length > 1 && table.rows.length > 0)
    : [];
  return {
    schemaVersion: DOCUMENT_INGEST_CACHE_VERSION,
    path: String(result.path || relativePath),
    kind: String(result.kind || "file"),
    text: String(result.text || blocks.map((block) => block.text).join("\n\n")).trim(),
    markdown: String(result.markdown || result.text || "").trim(),
    tables,
    blocks,
    warnings: Array.isArray(result.warnings) ? result.warnings.map(String) : [],
    extractor: String(result.extractor || "codmes-document-worker")
  };
}
