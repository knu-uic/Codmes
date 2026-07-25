import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  buildSearchIndex,
  globalSearch,
  readSearchIndex,
  searchStatus,
  searchWorkspace,
  updateSearchIndex
} from "./search-service.mjs";
import {
  annotationsPathForDocument,
  documentIngestCacheDirectory,
  documentOriginalBackupPath
} from "./document-ingest.mjs";

const execFileAsync = promisify(execFile);

test("searches workspace text files within scope", async () => {
  const root = await fixtureWorkspace();
  const result = await searchWorkspace(root, {
    query: "scheduler",
    scopePath: "Notes",
    maxResults: 5
  });
  assert.equal(result.provider, "workspace-scan");
  assert.equal(result.resultCount, 1);
  assert.equal(result.results[0].path, "Notes/os.md");
  assert.match(result.results[0].snippet, /scheduler/i);
});

test("does not search outside the requested scope", async () => {
  const root = await fixtureWorkspace();
  const result = await searchWorkspace(root, {
    query: "scheduler",
    scopePath: "Code"
  });
  assert.equal(result.resultCount, 0);
});

test("search supports filename hits and kind filters", async () => {
  const root = await fixtureWorkspace();
  const filenameHit = await searchWorkspace(root, {
    query: "main",
    scopePath: "",
    kind: "code"
  });
  assert.equal(filenameHit.resultCount, 1);
  assert.equal(filenameHit.results[0].path, "Code/main.js");

  const filteredOut = await searchWorkspace(root, {
    query: "main",
    scopePath: "",
    kind: "markdown"
  });
  assert.equal(filteredOut.resultCount, 0);
});

test("reports secondary workspace scan search status", async () => {
  const status = searchStatus("/tmp/workspace");
  assert.equal(status.provider, "workspace-scan");
  assert.equal(status.available, true);
  assert.equal(status.indexed, false);
  assert.equal(status.maxFileBytes, 1024 * 1024 * 1024);
  assert.ok(status.searchableExtensions.includes(".md"));
  assert.ok(status.searchableExtensions.includes(".pdf"));
});

test("reports metadata for search indexes larger than the status parse limit", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "search-status-large-"));
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: "2026-07-25T00:00:00.000Z",
    itemCount: 42,
    chunkCount: 50598,
    padding: "x".repeat(10 * 1024 * 1024)
  }), "utf8");

  const status = searchStatus(root);
  assert.equal(status.itemCount, 42);
  assert.equal(status.chunkCount, 50598);
  assert.equal(status.builtAt, "2026-07-25T00:00:00.000Z");
});

test("builds and searches the native Codmes search index", async () => {
  const root = await fixtureWorkspace();
  const index = await buildSearchIndex(root, {
    roots: ["Notes"],
    embeddingsProvider: "ollama",
    openaiBaseUrl: "http://127.0.0.1:11434/v1",
    openaiEmbedModel: "bge-m3",
    openaiEmbedDim: 1024
  });
  assert.equal(index.provider, "codmes-search-index");
  assert.equal(index.roots[0], "Notes");
  assert.equal(index.embeddings.provider, "ollama");
  assert.equal(index.embeddings.model, "bge-m3");
  assert.equal(index.embeddings.dimensions, 1024);
  assert.equal(index.itemCount, 1);
  assert.equal(index.chunkCount, 1);

  const status = searchStatus(root);
  assert.equal(status.provider, "codmes-search-index");
  assert.equal(status.indexed, true);
  assert.equal(status.itemCount, 1);

  const result = await searchWorkspace(root, {
    query: "scheduler",
    scopePath: "Notes",
    maxResults: 5
  });
  assert.equal(result.provider, "codmes-search-index");
  assert.equal(result.resultCount, 1);
  assert.equal(result.results[0].path, "Notes/os.md");
});

test("partially updates the native search index when files change", async () => {
  const root = await fixtureWorkspace();
  await buildSearchIndex(root, {
    roots: ["Notes"],
    embeddingsProvider: "ollama",
    openaiEmbedModel: "bge-m3"
  });

  await fs.writeFile(path.join(root, "Notes", "os.md"), "# OS\n\nA kernel tracks run queues.", "utf8");
  const updated = await updateSearchIndex(root, ["Notes/os.md"]);
  assert.equal(updated.provider, "codmes-search-index");
  assert.equal(updated.embeddings.provider, "ollama");
  assert.equal(updated.embeddings.model, "bge-m3");

  const oldTerm = await searchWorkspace(root, { query: "scheduler", scopePath: "Notes" });
  assert.equal(oldTerm.resultCount, 0);

  const newTerm = await searchWorkspace(root, { query: "run queues", scopePath: "Notes" });
  assert.equal(newTerm.provider, "codmes-search-index");
  assert.equal(newTerm.resultCount, 1);
  assert.equal(newTerm.results[0].path, "Notes/os.md");
});

test("partially removes deleted files from the native search index", async () => {
  const root = await fixtureWorkspace();
  await buildSearchIndex(root, { roots: ["Notes"] });

  await fs.rm(path.join(root, "Notes", "os.md"));
  await updateSearchIndex(root, ["Notes/os.md"]);

  const index = await readSearchIndex(root);
  assert.equal(index.itemCount, 0);
  assert.equal(index.chunkCount, 0);

  const result = await searchWorkspace(root, { query: "scheduler", scopePath: "Notes" });
  assert.equal(result.provider, "codmes-search-index");
  assert.equal(result.resultCount, 0);
});

test("full workspace indexing skips private Codmes config state", async () => {
  const root = await fixtureWorkspace();
  await fs.mkdir(path.join(root, ".codmes", "config"), { recursive: true });
  await fs.writeFile(path.join(root, ".codmes", "config", "auth.json"), "{\"secret\":\"leak-marker\"}", "utf8");
  await fs.mkdir(path.join(root, "Documents", ".codmes", "annotations"), { recursive: true });
  await fs.writeFile(path.join(root, "Documents", ".codmes", "annotations", "manual.codmes.json"), "{\"secret\":\"annotation-state-leak-marker\"}", "utf8");

  await buildSearchIndex(root, { roots: [""] });
  const result = await searchWorkspace(root, { query: "leak-marker", scopePath: "" });
  assert.equal(result.provider, "codmes-search-index");
  assert.equal(result.resultCount, 0);
  const annotationStateResult = await searchWorkspace(root, { query: "annotation-state-leak-marker", scopePath: "Documents" });
  assert.equal(annotationStateResult.resultCount, 0);
});

test("global search returns public common results and hides internal files", async () => {
  const root = await fixtureWorkspace();
  await fs.mkdir(path.join(root, "Notes", ".codmes", "cache"), { recursive: true });
  await fs.writeFile(path.join(root, "Notes", ".codmes", "cache", "hidden.md"), "scheduler leak", "utf8");
  await buildSearchIndex(root, { roots: [""] });

  const result = await globalSearch(root, { query: "scheduler", surface: "all" });
  assert.equal(result.provider, "codmes-global-search");
  assert.equal(result.results.length, 1);
  assert.equal(result.results[0].surface, "notes");
  assert.equal(result.results[0].kind, "markdown_chunk");
  assert.equal(result.results[0].target.path, "Notes/os.md");
  assert.equal(result.results.some((hit) => String(hit.target.path || "").includes(".codmes")), false);
});

test("global search keeps PDF filename matches and separate content occurrences", async () => {
  const root = await fixtureWorkspace();
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: new Date(0).toISOString(),
    items: [
      { path: "Notes/workbook_sw.pdf", kind: "pdf", modifiedAt: new Date(0).toISOString() }
    ],
    chunks: [
      { id: "page-1-a", path: "Notes/workbook_sw.pdf", kind: "pdf", page: 1, chunkIndex: 0, text: "Oracle database" },
      { id: "page-1-b", path: "Notes/workbook_sw.pdf", kind: "pdf", page: 1, chunkIndex: 1, text: "Oracle client" },
      { id: "page-2", path: "Notes/workbook_sw.pdf", kind: "pdf", page: 2, chunkIndex: 2, text: "Oracle cloud" }
    ]
  }), "utf8");

  const contentResult = await globalSearch(root, { query: "oracle", surface: "notes" });
  assert.deepEqual(contentResult.results.map((hit) => hit.target.page), [1, 1, 2]);

  const filenameResult = await globalSearch(root, { query: "work", surface: "notes" });
  assert.equal(filenameResult.results.length, 1);
  assert.equal(filenameResult.results[0].kind, "note_file");
  assert.equal(filenameResult.results[0].target.path, "Notes/workbook_sw.pdf");
  assert.equal(filenameResult.results[0].target.page, null);
});

test("global search returns a visual keyword box for OCR-normalized PDFs", async () => {
  const root = await fixtureWorkspace();
  const relativePath = "Notes/ocr-book.pdf";
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: new Date(0).toISOString(),
    items: [{ path: relativePath, kind: "pdf", modifiedAt: new Date(0).toISOString() }],
    chunks: [{
      id: "ocr-title",
      path: relativePath,
      kind: "pdf",
      page: 1,
      chunkIndex: 0,
      text: "김종현 지음",
      bbox: {
        unit: "pdf-point",
        x: 400,
        y: 607,
        width: 66,
        height: 13,
        pageWidth: 530,
        pageHeight: 738,
        normalized: { x: 0.75, y: 0.82, width: 0.12, height: 0.018 }
      }
    }]
  }), "utf8");
  const backupPath = documentOriginalBackupPath(root, relativePath);
  await fs.mkdir(path.dirname(backupPath), { recursive: true });
  await fs.writeFile(backupPath, "original", "utf8");

  const result = await globalSearch(root, { query: "김종현", surface: "notes" });
  const box = result.results[0].target.bbox;
  assert.equal(box.x, 400);
  assert.equal(box.width, 33);
  assert.equal(box.y, 596.34);
  assert.equal(box.height, 15.86);
  assert.equal(box.normalized.x, 0.75);
  assert.equal(box.normalized.width, 0.06);
  assert.equal(box.normalized.y, 0.80524);
  assert.ok(Math.abs(box.normalized.height - 0.02196) < 1e-10);
});

test("search normalizes composed Korean queries against decomposed PDF paths and text", async () => {
  const root = await fixtureWorkspace();
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  const decomposedPath = "Notes/AI브리프_3월_260303.pdf".normalize("NFD");
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: new Date(0).toISOString(),
    items: [{ path: decomposedPath, kind: "pdf", modifiedAt: new Date(0).toISOString() }],
    chunks: [{
      id: "korean-page",
      path: decomposedPath,
      kind: "pdf",
      page: 3,
      chunkIndex: 0,
      text: "3월 주요 일정".normalize("NFD")
    }]
  }), "utf8");

  const filenameResult = await globalSearch(root, { query: "AI브리프", surface: "notes" });
  assert.equal(filenameResult.documents[0].path, decomposedPath);
  assert.equal(filenameResult.documents[0].titleMatch, "prefix");

  const monthResult = await searchWorkspace(root, { query: "3월", scopePath: "Notes" });
  assert.equal(monthResult.resultCount, 1);
  assert.equal(monthResult.results[0].path, decomposedPath);
  assert.match(monthResult.results[0].snippet, /3월 주요 일정/);
});

test("global search ranks documents by filename match and document match counts", async () => {
  const root = await fixtureWorkspace();
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: new Date(0).toISOString(),
    items: [
      { path: "Notes/oracle.pdf", kind: "pdf", modifiedAt: new Date(0).toISOString() },
      { path: "Notes/database-a.pdf", kind: "pdf", modifiedAt: new Date(0).toISOString() },
      { path: "Notes/database-b.pdf", kind: "pdf", modifiedAt: new Date(0).toISOString() }
    ],
    chunks: [
      { id: "title-doc", path: "Notes/oracle.pdf", kind: "pdf", page: 9, chunkIndex: 0, text: "Oracle once" },
      { id: "a-page-3", path: "Notes/database-a.pdf", kind: "pdf", page: 3, chunkIndex: 0, text: "Oracle A3" },
      { id: "a-page-1", path: "Notes/database-a.pdf", kind: "pdf", page: 1, chunkIndex: 1, text: "Oracle A1" },
      { id: "a-page-2", path: "Notes/database-a.pdf", kind: "pdf", page: 2, chunkIndex: 2, text: "Oracle A2" },
      { id: "b-page-2-a", path: "Notes/database-b.pdf", kind: "pdf", page: 2, chunkIndex: 0, text: "Oracle B2 first" },
      { id: "b-page-2-b", path: "Notes/database-b.pdf", kind: "pdf", page: 2, chunkIndex: 1, text: "Oracle B2 second" }
    ]
  }), "utf8");

  const result = await globalSearch(root, { query: "oracle", surface: "notes" });
  assert.deepEqual(result.documents.map((document) => document.path), [
    "Notes/oracle.pdf",
    "Notes/database-a.pdf",
    "Notes/database-b.pdf"
  ]);
  assert.deepEqual(result.documents.map((document) => document.titleMatch), ["exact", "none", "none"]);
  assert.deepEqual(result.documents.map((document) => document.matchedPageCount), [1, 3, 1]);
  assert.deepEqual(result.documents.map((document) => document.occurrenceCount), [1, 3, 2]);
  assert.deepEqual(
    result.results.filter((hit) => hit.target.path === "Notes/database-a.pdf").map((hit) => hit.target.page),
    [1, 2, 3]
  );
  assert.equal(result.results.filter((hit) => hit.target.path).every((hit) => hit.score === 0), true);
});

test("global search returns PDF occurrences beyond the former 40-result limit", async () => {
  const root = await fixtureWorkspace();
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  const chunks = Array.from({ length: 56 }, (_, index) => ({
    id: `oracle-${index}`,
    path: "Notes/database.pdf",
    kind: "pdf",
    page: index + 1,
    chunkIndex: index,
    text: `Oracle result ${index + 1}`
  }));
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: new Date(0).toISOString(),
    items: [{ path: "Notes/database.pdf", kind: "pdf", modifiedAt: new Date(0).toISOString() }],
    chunks
  }), "utf8");

  const result = await globalSearch(root, { query: "oracle", surface: "notes" });
  assert.equal(result.resultCount, 56);
  assert.equal(result.results.at(-1).target.page, 56);
});

test("global search paginates without truncating the total result set", async () => {
  const root = await fixtureWorkspace();
  const indexPath = path.join(root, ".codmes", "index", "search.json");
  const chunks = Array.from({ length: 205 }, (_, index) => ({
    id: `oracle-page-${index}`,
    path: "Notes/large-database.pdf",
    kind: "pdf",
    page: index + 1,
    chunkIndex: index,
    text: `Oracle result ${index + 1}`
  }));
  await fs.mkdir(path.dirname(indexPath), { recursive: true });
  await fs.writeFile(indexPath, JSON.stringify({
    builtAt: new Date(0).toISOString(),
    items: [{ path: "Notes/large-database.pdf", kind: "pdf", modifiedAt: new Date(0).toISOString() }],
    chunks
  }), "utf8");

  const first = await globalSearch(root, { query: "oracle", surface: "notes", limit: 100 });
  const second = await globalSearch(root, {
    query: "oracle",
    surface: "notes",
    limit: 100,
    cursor: first.nextCursor
  });
  const third = await globalSearch(root, {
    query: "oracle",
    surface: "notes",
    limit: 100,
    cursor: second.nextCursor
  });

  assert.equal(first.resultCount, 205);
  assert.equal(first.results.length, 100);
  assert.equal(first.hasMore, true);
  assert.equal(second.results.length, 100);
  assert.equal(second.hasMore, true);
  assert.equal(third.results.length, 5);
  assert.equal(third.hasMore, false);
  assert.equal(third.nextCursor, null);
  assert.equal(new Set([...first.results, ...second.results, ...third.results].map((hit) => hit.id)).size, 205);
});

test("searches extracted PDF text and caches it", async () => {
  const root = await fixtureWorkspace();
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  await createMinimalPdf(path.join(root, "Documents", "manual.pdf"), "semantic workspace manual");

  const result = await searchWorkspace(root, {
    query: "semantic workspace",
    scopePath: "Documents"
  });
  assert.equal(result.resultCount, 1);
  assert.equal(result.results[0].path, "Documents/manual.pdf");
  assert.match(result.results[0].snippet, /semantic workspace/i);

  const cacheDirectory = documentIngestCacheDirectory(root, "Documents/manual.pdf");
  const cacheEntries = await fs.readdir(cacheDirectory);
  assert.equal(cacheEntries.length, 2);
  assert.equal(cacheEntries.filter((entry) => entry.endsWith(".json")).length, 1);
  assert.equal(cacheEntries.filter((entry) => entry.endsWith(".md")).length, 1);

  await fs.rm(path.join(root, "Documents", "manual.pdf"));
  const updated = await updateSearchIndex(root, ["Documents/manual.pdf"]);
  assert.equal(updated.items.some((item) => item.path === "Documents/manual.pdf"), false);
  assert.deepEqual(await fs.readdir(cacheDirectory).catch(() => []), []);
});

test("indexes searchable PDF annotation text and image OCR blocks", async () => {
  const root = await fixtureWorkspace();
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  await fs.mkdir(path.join(root, ".codmes", "config"), { recursive: true });
  await fs.writeFile(path.join(root, ".codmes", "config", "search.env"), [
    "VLM_PROVIDER=lmstudio",
    "VLM_MODEL=vision-model",
    "VLM_BASE_URL=http://vlm.test/v1",
    "VLM_MIN_TEXT_CHARS=0",
    ""
  ].join("\n"), "utf8");
  const pdfPath = path.join(root, "Documents", "annotated.pdf");
  await createMinimalPdf(pdfPath, "base pdf text");
  await fs.mkdir(path.dirname(annotationsPathForDocument(root, "Documents/annotated.pdf")), { recursive: true });
  await fs.writeFile(annotationsPathForDocument(root, "Documents/annotated.pdf"), JSON.stringify({
    schemaVersion: 1,
    documentPath: "Documents/annotated.pdf",
    pages: [{
      pageIndex: 0,
      objects: [
        { id: "box-1", type: "text", text: "회의 액션 아이템", bbox: { x: 0.1, y: 0.1, width: 0.4, height: 0.1 } },
        { id: "img-1", type: "image", dataBase64: MINIMAL_PNG_BASE64, metadata: { mime: "image/png" } }
      ]
    }],
    objects: []
  }), "utf8");

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({
    choices: [{ message: { content: "첨부 도표 OCR" } }]
  }), { status: 200, headers: { "content-type": "application/json" } });
  try {
    await buildSearchIndex(root, { roots: ["Documents"] });
    const textBox = await searchWorkspace(root, { query: "액션 아이템", scopePath: "Documents" });
    assert.equal(textBox.results.some((result) => result.source === "annotation-text"), true);

    const imageOcr = await searchWorkspace(root, { query: "첨부 도표", scopePath: "Documents" });
    assert.equal(imageOcr.results.some((result) => result.source === "annotation-image-ocr"), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

async function fixtureWorkspace() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "search-service-"));
  await fs.mkdir(path.join(root, "Notes"), { recursive: true });
  await fs.mkdir(path.join(root, "Code"), { recursive: true });
  await fs.writeFile(path.join(root, "Notes", "os.md"), "# OS\n\nA scheduler chooses a process.", "utf8");
  await fs.writeFile(path.join(root, "Code", "main.js"), "console.log('hello')", "utf8");
  return root;
}

async function createMinimalPdf(filePath, text) {
  const script = `
import fitz, sys
path, text = sys.argv[1], sys.argv[2]
doc = fitz.open()
page = doc.new_page()
page.insert_text((72, 72), text, fontsize=14)
doc.save(path)
`;
  await execFileAsync(process.env.CODMES_PYTHON || ".codmes-runtime/bin/python", ["-c", script, filePath, text]);
}

const MINIMAL_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lxWvWQAAAABJRU5ErkJggg==";
