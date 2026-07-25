import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  annotationsPathForDocument,
  annotationOcrCachePath,
  contentScopedAnnotationsPathForDocument,
  documentFolderAnnotationsPathForDocument,
  extractAndCacheDocument,
  extractDocumentAnnotationBlocks,
  documentIngestCacheDirectory,
  documentIngestCachePath,
  documentIngestMarkdownPath,
  documentManifestPath,
  documentStateDirectory,
  getDocumentIngestMetadata,
  isDocumentIngestFile,
  legacyAnnotationsPathForDocument,
  normalizeOcrBox,
  pdfTextNeedsOcr,
  pruneDocumentIngestCacheFiles,
  removeDocumentIngestCacheFiles,
  writePdfOcrTextLayer
} from "./document-ingest.mjs";

const execFileAsync = promisify(execFile);

test("document ingest extracts and caches PDF text through the worker", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  const pdfPath = path.join(root, "Documents", "manual.pdf");
  await createMinimalPdf(pdfPath, "codmes document ingest marker");

  assert.equal(isDocumentIngestFile("Documents/manual.pdf"), true);

  const first = await extractAndCacheDocument(root, pdfPath, "Documents/manual.pdf");
  assert.equal(first.kind, "pdf");
  assert.match(first.text, /codmes document ingest marker/i);
  assert.ok(first.blocks.length >= 1);
  assert.equal(first.blocks[0].source, "pdf-text");

  const metadata = await getDocumentIngestMetadata(root, pdfPath, "Documents/manual.pdf");
  assert.equal(metadata.cached, true);
  assert.equal(metadata.blockCount, 1);
  assert.ok(metadata.textLength > 0);

  const second = await extractAndCacheDocument(root, pdfPath, "Documents/manual.pdf");
  assert.deepEqual(second.text, first.text);
  const manifest = JSON.parse(await fs.readFile(documentManifestPath(root, "Documents/manual.pdf"), "utf8"));
  assert.equal(manifest.sourcePath, "Documents/manual.pdf");
  assert.match(documentStateDirectory(root, "Documents/manual.pdf"), /manual--[a-f0-9]{8}$/);
});

test("document ingest stores structured PDF tables and a Markdown sidecar", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-table-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  const relativePath = "Documents/schedule.pdf";
  const pdfPath = path.join(root, relativePath);
  await createTablePdf(pdfPath);

  const result = await extractAndCacheDocument(root, pdfPath, relativePath);
  assert.equal(result.schemaVersion, 3);
  assert.ok(result.tables.length >= 1);
  const table = result.tables.find((item) => item.headers.includes("Event"));
  assert.ok(table);
  assert.deepEqual(table.headers.slice(0, 3), ["Month", "Event", "Place"]);
  assert.deepEqual(table.rows[0].slice(0, 3), ["March", "GTC", "San Jose"]);
  assert.equal(table.page, 1);
  assert.ok(table.bbox?.normalized);

  const stat = await fs.stat(pdfPath);
  const markdownPath = documentIngestMarkdownPath(root, relativePath, stat);
  const markdown = await fs.readFile(markdownPath, "utf8");
  assert.match(markdown, /\|\s*Month\s*\|\s*Event\s*\|\s*Place\s*\|/);

  const metadata = await getDocumentIngestMetadata(root, pdfPath, relativePath, stat);
  assert.ok(metadata.tableCount >= 1);
  assert.match(metadata.markdownPath, /\.md$/);
});

test("document folders remain readable and distinct for duplicate filenames", () => {
  const root = "/workspace";
  const notesPath = documentStateDirectory(root, "Notes/manual.pdf");
  const documentsPath = documentStateDirectory(root, "Documents/manual.pdf");
  assert.match(notesPath, /manual--[a-f0-9]{8}$/);
  assert.match(documentsPath, /manual--[a-f0-9]{8}$/);
  assert.notEqual(notesPath, documentsPath);
});

test("document ingest migrates the current legacy hash cache into its document folder", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-cache-migration-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  const relativePath = "Documents/manual.pdf";
  const pdfPath = path.join(root, relativePath);
  await createMinimalPdf(pdfPath, "legacy cache migration marker");

  const extracted = await extractAndCacheDocument(root, pdfPath, relativePath);
  const markdown = await fs.readFile(documentIngestMarkdownPath(root, relativePath), "utf8");
  const stat = await fs.stat(pdfPath);
  const oldKey = crypto.createHash("sha256")
    .update(`v3\n${relativePath}\n${stat.size}:${stat.mtimeMs}`)
    .digest("hex");
  const oldDirectory = path.join(root, ".codmes", "index", "documents");
  const oldJsonPath = path.join(oldDirectory, `${oldKey}.json`);
  await fs.mkdir(oldDirectory, { recursive: true });
  const { cache: _cache, ...legacy } = extracted;
  await fs.writeFile(oldJsonPath, JSON.stringify(legacy), "utf8");
  await fs.writeFile(oldJsonPath.replace(/\.json$/, ".md"), markdown, "utf8");
  await fs.rm(documentStateDirectory(root, relativePath), { recursive: true, force: true });

  const migrated = await extractAndCacheDocument(root, pdfPath, relativePath, stat);
  assert.match(migrated.text, /legacy cache migration marker/i);
  await fs.access(documentIngestCachePath(root, relativePath));
  await fs.access(documentManifestPath(root, relativePath));
  await assert.rejects(fs.access(oldJsonPath), { code: "ENOENT" });
});

test("document ingest removes stale and deleted document cache files", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-cleanup-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  const relativePath = "Documents/manual.pdf";
  const pdfPath = path.join(root, relativePath);

  await createMinimalPdf(pdfPath, "first cache version");
  await extractAndCacheDocument(root, pdfPath, relativePath);
  assert.equal((await cacheFileNames(root, relativePath)).length, 2);
  const annotationPath = annotationsPathForDocument(root, relativePath);
  await fs.writeFile(annotationPath, JSON.stringify({
    schemaVersion: 2,
    documentPath: relativePath,
    pages: [{ pageIndex: 0, objects: [{ id: "kept-note", type: "text", text: "keep me" }] }]
  }), "utf8");

  await fs.rm(pdfPath);
  await createMultiPagePdf(pdfPath, ["first page after insert", "inserted second page"]);
  const refreshed = await extractAndCacheDocument(root, pdfPath, relativePath);
  const refreshedEntries = await cacheFileNames(root, relativePath);
  assert.equal(refreshedEntries.length, 2);
  assert.equal(refreshedEntries.filter((entry) => entry.endsWith(".json")).length, 1);
  assert.equal(refreshedEntries.filter((entry) => entry.endsWith(".md")).length, 1);
  assert.equal(refreshed.blocks.some((block) => block.page === 2 && /inserted second page/i.test(block.text)), true);
  const preservedAnnotations = JSON.parse(await fs.readFile(annotationPath, "utf8"));
  assert.equal(preservedAnnotations.pages[0].objects[0].text, "keep me");

  await removeDocumentIngestCacheFiles(root, [relativePath]);
  assert.deepEqual(await cacheFileNames(root, relativePath), []);
});

test("document ingest prunes orphaned cache files", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-prune-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  const relativePath = "Documents/deleted.pdf";
  const pdfPath = path.join(root, relativePath);

  await createMinimalPdf(pdfPath, "orphaned cache marker");
  await extractAndCacheDocument(root, pdfPath, relativePath);
  await fs.rm(pdfPath);
  assert.equal((await cacheFileNames(root, relativePath)).length, 2);

  await pruneDocumentIngestCacheFiles(root);
  assert.deepEqual(await cacheFileNames(root, relativePath), []);
});

test("document ingest extracts DOCX text without LibreOffice through OpenXML", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-docx-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  const docxPath = path.join(root, "Documents", "sample.docx");
  await createMinimalDocx(docxPath, "codmes openxml marker");

  const result = await extractAndCacheDocument(root, docxPath, "Documents/sample.docx");
  assert.equal(result.kind, "document");
  assert.match(result.text, /codmes openxml marker/i);
  assert.equal(result.blocks[0].source, "openxml");
});

test("document ingest adds VLM OCR blocks for image-only PDF pages", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-vlm-pdf-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  await fs.mkdir(path.join(root, ".codmes", "config"), { recursive: true });
  await fs.writeFile(path.join(root, ".codmes", "config", "search.env"), [
    "VLM_PROVIDER=lmstudio",
    "VLM_MODEL=gemma-4-12b-it-mlx",
    "VLM_BASE_URL=http://vlm.test/v1",
    "VLM_API_KEY=test-key",
    "VLM_MAX_PAGES=2",
    ""
  ].join("\n"), "utf8");
  const pdfPath = path.join(root, "Documents", "scan.pdf");
  await createImageOnlyPdf(pdfPath);

  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({
      choices: [{ message: { content: "VLM PAGE TEXT" } }]
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const result = await extractAndCacheDocument(root, pdfPath, "Documents/scan.pdf");
    assert.match(result.text, /VLM PAGE TEXT/);
    assert.equal(result.extractor.endsWith("+vlm-ocr"), true);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "http://vlm.test/v1/chat/completions");
    assert.equal(calls[0].body.temperature, 0);
    assert.equal(calls[0].body.stream, false);
    assert.equal(calls[0].body.max_tokens, 800);
    assert.equal(calls[0].body.messages[0].content[1].type, "image_url");
    const vlmBlock = result.blocks.find((item) => item.source === "vlm-ocr");
    assert.equal(vlmBlock.page, 1);
    assert.equal(vlmBlock.metadata.temperature, 0);
    assert.equal(vlmBlock.metadata.thinking, "off");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("detects corrupted Korean PDF character maps without flagging normal Korean", () => {
  assert.equal(pdfTextNeedsOcr("컴퓨터구조론 저자 김종현 연세대학교 전기공학과에서 연구했습니다."), false);
  assert.equal(pdfTextNeedsOcr("킚s 퍟D 좷둄 젨잂f뾥慧 䞲E 젮잂퐉셊씏D 뾥f킚s 퍟f씏D 괱"), true);
});

test("preserves fractional Vision OCR coordinates", () => {
  assert.deepEqual(
    normalizeOcrBox({ x: 0.127, y: 0.234, width: 0.456, height: 0.078 }),
    { x: 0.127, y: 0.234, width: 0.456, height: 0.078 }
  );
});

test("writes positioned Korean OCR text into the PDF binary", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-pdf-layer-"));
  const inputPath = path.join(root, "input.pdf");
  const outputPath = path.join(root, "output.pdf");
  await createMinimalPdf(inputPath, "visible source page");
  await writePdfOcrTextLayer(inputPath, outputPath, [{
    page: 1,
    text: "김종현",
    metadata: {
      lines: [{
        text: "김종현",
        bbox: { x: 0.1, y: 0.1, width: 0.25, height: 0.05 }
      }]
    }
  }]);
  const { stdout } = await execFileAsync(
    process.env.CODMES_PYTHON || ".codmes-runtime/bin/python",
    ["-c", "import fitz,sys; d=fitz.open(sys.argv[1]); print(d[0].get_text())", outputPath]
  );
  assert.match(stdout, /김종현/);
});

test("document ingest sends image files through configured VLM OCR", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-vlm-image-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  await fs.mkdir(path.join(root, ".codmes", "config"), { recursive: true });
  await fs.writeFile(path.join(root, ".codmes", "config", "search.env"), [
    "VLM_PROVIDER=lmstudio",
    "VLM_MODEL=vision-model",
    "VLM_BASE_URL=http://vlm.test/v1",
    ""
  ].join("\n"), "utf8");
  const imagePath = path.join(root, "Documents", "scan.png");
  await fs.writeFile(imagePath, Buffer.from(MINIMAL_PNG_BASE64, "base64"));

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, init) => {
    const body = JSON.parse(init.body);
    assert.equal(body.temperature, 0);
    assert.equal(body.messages[0].content[1].image_url.url.startsWith("data:image/png;base64,"), true);
    return new Response(JSON.stringify({
      choices: [{ message: { content: "IMAGE OCR TEXT" } }]
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const result = await extractAndCacheDocument(root, imagePath, "Documents/scan.png");
    assert.match(result.text, /IMAGE OCR TEXT/);
    assert.equal(result.blocks.some((item) => item.source === "vlm-ocr"), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("document ingest extracts PDF annotation text and image OCR blocks", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-annotations-"));
  await fs.mkdir(path.join(root, "Documents"), { recursive: true });
  await fs.mkdir(path.join(root, ".codmes", "config"), { recursive: true });
  await fs.writeFile(path.join(root, ".codmes", "config", "search.env"), [
    "VLM_PROVIDER=lmstudio",
    "VLM_MODEL=vision-model",
    "VLM_BASE_URL=http://vlm.test/v1",
    ""
  ].join("\n"), "utf8");
  const pdfPath = path.join(root, "Documents", "annotated.pdf");
  await createMinimalPdf(pdfPath, "base pdf text");
  await fs.mkdir(path.dirname(annotationsPathForDocument(root, "Documents/annotated.pdf")), { recursive: true });
  await fs.writeFile(annotationsPathForDocument(root, "Documents/annotated.pdf"), JSON.stringify({
    schemaVersion: 1,
    documentPath: "Documents/annotated.pdf",
    pages: [
      {
        pageIndex: 0,
        objects: [
          {
            id: "text-1",
            type: "text",
            text: "사용자 텍스트 박스",
            bbox: { x: 0.1, y: 0.2, width: 0.3, height: 0.1 }
          },
          {
            id: "image-1",
            type: "image",
            dataBase64: MINIMAL_PNG_BASE64,
            metadata: { mime: "image/png" },
            bbox: { x: 0.2, y: 0.3, width: 0.4, height: 0.2 }
          }
        ]
      }
    ],
    objects: []
  }, null, 2), "utf8");

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, init) => {
    const body = JSON.parse(init.body);
    assert.equal(body.temperature, 0);
    assert.equal(body.messages[0].content[1].type, "image_url");
    return new Response(JSON.stringify({
      choices: [{ message: { content: "첨부 이미지 OCR 텍스트" } }]
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const blocks = await extractDocumentAnnotationBlocks(root, "Documents/annotated.pdf");
    assert.equal(blocks.length, 2);
    assert.equal(blocks[0].source, "annotation-text");
    assert.equal(blocks[0].page, 1);
    assert.equal(blocks[1].source, "annotation-image-ocr");
    assert.equal(blocks[1].text, "첨부 이미지 OCR 텍스트");
    assert.equal(blocks[1].metadata.temperature, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("document ingest migrates legacy annotations into document-folder state", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-annotation-migration-"));
  const relativePath = "Notes/paper.pdf";
  const legacyPath = legacyAnnotationsPathForDocument(root, relativePath);
  const primaryPath = annotationsPathForDocument(root, relativePath);
  assert.match(primaryPath, /\.codmes\/documents\/paper--[a-f0-9]{8}\/annotations\.json$/);
  assert.notEqual(primaryPath, legacyPath);
  await fs.mkdir(path.dirname(legacyPath), { recursive: true });
  await fs.writeFile(legacyPath, JSON.stringify({
    schemaVersion: 1,
    documentPath: relativePath,
    pages: [{
      pageIndex: 0,
      objects: [{
        id: "legacy-text",
        type: "text",
        text: "legacy annotation migrated",
        bbox: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 }
      }]
    }],
    objects: []
  }), "utf8");

  const blocks = await extractDocumentAnnotationBlocks(root, relativePath);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].text, "legacy annotation migrated");
  await fs.access(primaryPath);
  await fs.access(documentManifestPath(root, relativePath));
  await assert.rejects(fs.access(legacyPath), { code: "ENOENT" });
});

test("document ingest migrates content-scoped hidden annotations into document-folder state", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-content-state-migration-"));
  const relativePath = "Documents/lecture.pdf";
  const contentScopedPath = contentScopedAnnotationsPathForDocument(root, relativePath);
  const primaryPath = annotationsPathForDocument(root, relativePath);
  assert.match(primaryPath, /\.codmes\/documents\/lecture--[a-f0-9]{8}\/annotations\.json$/);
  assert.match(contentScopedPath, /Documents\/\.codmes\/annotations/);
  await fs.mkdir(path.dirname(contentScopedPath), { recursive: true });
  await fs.writeFile(contentScopedPath, JSON.stringify({
    schemaVersion: 1,
    documentPath: relativePath,
    pages: [{
      pageIndex: 0,
      objects: [{
        id: "content-state-text",
        type: "text",
        text: "content state migrated",
        bbox: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 }
      }]
    }],
    objects: []
  }), "utf8");

  const blocks = await extractDocumentAnnotationBlocks(root, relativePath);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].text, "content state migrated");
  await fs.access(primaryPath);
  await assert.rejects(fs.access(contentScopedPath), { code: "ENOENT" });
});

test("document ingest migrates annotations previously stored beside the document folder", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-folder-state-migration-"));
  const relativePath = "Notes/legacy-paper.pdf";
  const previousPath = documentFolderAnnotationsPathForDocument(root, relativePath);
  await fs.mkdir(path.dirname(previousPath), { recursive: true });
  await fs.writeFile(previousPath, JSON.stringify({
    schemaVersion: 2,
    documentPath: relativePath,
    pages: [{ pageIndex: 0, objects: [{ id: "old-text", type: "text", text: "old folder annotation" }] }]
  }), "utf8");

  const blocks = await extractDocumentAnnotationBlocks(root, relativePath);
  assert.equal(blocks[0].text, "old folder annotation");
  await fs.access(annotationsPathForDocument(root, relativePath));
  await assert.rejects(fs.access(previousPath), { code: "ENOENT" });
});

test("PDF annotation image OCR is cached by content hash while bbox stays live", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "document-ingest-annotation-cache-"));
  await fs.mkdir(path.join(root, ".codmes", "config"), { recursive: true });
  await fs.writeFile(path.join(root, ".codmes", "config", "search.env"), [
    "VLM_PROVIDER=lmstudio",
    "VLM_MODEL=vision-model",
    "VLM_BASE_URL=http://vlm.test/v1",
    ""
  ].join("\n"), "utf8");
  const annotationFile = annotationsPathForDocument(root, "Documents/live-bbox.pdf");
  await fs.mkdir(path.dirname(annotationFile), { recursive: true });
  const writeAnnotation = async (bbox) => {
    await fs.writeFile(annotationFile, JSON.stringify({
      schemaVersion: 1,
      documentPath: "Documents/live-bbox.pdf",
      pages: [{
        pageIndex: 2,
        objects: [{
          id: "image-live",
          type: "image",
          dataBase64: MINIMAL_PNG_BASE64,
          metadata: { mime: "image/png" },
          bbox
        }]
      }],
      objects: []
    }, null, 2), "utf8");
  };

  let calls = 0;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    calls += 1;
    return new Response(JSON.stringify({
      choices: [{ message: { content: "cached annotation OCR" } }]
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    await writeAnnotation({ x: 0.1, y: 0.2, width: 0.3, height: 0.4 });
    const first = await extractDocumentAnnotationBlocks(root, "Documents/live-bbox.pdf");
    assert.equal(calls, 1);
    assert.equal(first[0].bbox.x, 0.1);
    assert.equal(first[0].metadata.cached, false);
    assert.ok(first[0].metadata.contentHash.startsWith("sha256-"));
    await fs.access(annotationOcrCachePath(root, "Documents/live-bbox.pdf", first[0].metadata.contentHash));

    await writeAnnotation({ x: 0.55, y: 0.22, width: 0.18, height: 0.19 });
    const second = await extractDocumentAnnotationBlocks(root, "Documents/live-bbox.pdf");
    assert.equal(calls, 1);
    assert.equal(second[0].text, "cached annotation OCR");
    assert.equal(second[0].bbox.x, 0.55);
    assert.equal(second[0].bbox.width, 0.18);
    assert.equal(second[0].metadata.cached, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

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

async function createMultiPagePdf(filePath, pageTexts) {
  const script = `
import fitz, json, sys
path, texts = sys.argv[1], json.loads(sys.argv[2])
doc = fitz.open()
for text in texts:
    page = doc.new_page()
    page.insert_text((72, 72), text, fontsize=14)
doc.save(path)
`;
  await execFileAsync(
    process.env.CODMES_PYTHON || ".codmes-runtime/bin/python",
    ["-c", script, filePath, JSON.stringify(pageTexts)]
  );
}

async function cacheFileNames(root, relativePath) {
  return await fs.readdir(documentIngestCacheDirectory(root, relativePath)).catch(() => []);
}

async function createTablePdf(filePath) {
  const script = `
import fitz, sys
path = sys.argv[1]
doc = fitz.open()
page = doc.new_page(width=500, height=400)
xs = [60, 150, 300, 440]
ys = [70, 105, 140, 175]
for x in xs:
    page.draw_line((x, ys[0]), (x, ys[-1]), color=(0, 0, 0), width=1)
for y in ys:
    page.draw_line((xs[0], y), (xs[-1], y), color=(0, 0, 0), width=1)
rows = [
    ["Month", "Event", "Place"],
    ["March", "GTC", "San Jose"],
    ["April", "ICLR", "Rio"]
]
for row_index, row in enumerate(rows):
    for column_index, value in enumerate(row):
        page.insert_text((xs[column_index] + 6, ys[row_index] + 22), value, fontsize=11)
doc.save(path)
`;
  await execFileAsync(process.env.CODMES_PYTHON || ".codmes-runtime/bin/python", ["-c", script, filePath]);
}

async function createImageOnlyPdf(filePath) {
  const script = `
import fitz, sys
path = sys.argv[1]
doc = fitz.open()
page = doc.new_page(width=360, height=180)
shape = page.new_shape()
shape.draw_rect(fitz.Rect(40, 40, 320, 140))
shape.finish(color=(0, 0, 0), fill=(0.95, 0.95, 0.95))
shape.commit()
doc.save(path)
`;
  await execFileAsync(process.env.CODMES_PYTHON || ".codmes-runtime/bin/python", ["-c", script, filePath]);
}

async function createMinimalDocx(filePath, text) {
  const script = `
import zipfile, sys
path, text = sys.argv[1], sys.argv[2]
xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>''' + text + '''</w:t></w:r></w:p></w:body>
</w:document>'''
with zipfile.ZipFile(path, "w") as z:
    z.writestr("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"></Types>')
    z.writestr("word/document.xml", xml)
`;
  await execFileAsync("python3", ["-c", script, filePath, text]);
}

const MINIMAL_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lxWvWQAAAABJRU5ErkJggg==";
