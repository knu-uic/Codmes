import assert from "node:assert/strict";
import test from "node:test";

import { pdfThumbnailCacheFileName } from "./pdf-thumbnail.mjs";

test("PDF thumbnail cache names stay short for long Korean paths and queries", () => {
  const input = {
    relativePath: `Notes/${"아주 긴 한글 PDF 파일명 ".repeat(30)}.pdf`,
    size: 123456789,
    mtimeMs: 1784976301486.254,
    page: 42,
    crop: { x: 0.10141988046013495, y: 0.1278383988508932, width: 0.0379185080341617, height: 0.010854819036893396 },
    highlightQuery: "김종현".repeat(30),
    scale: 0.45
  };

  const fileName = pdfThumbnailCacheFileName(input);
  assert.match(fileName, /^[a-f0-9]{64}\.png$/);
  assert.ok(Buffer.byteLength(fileName) < 255);
  assert.notEqual(
    fileName,
    pdfThumbnailCacheFileName({ ...input, page: input.page + 1 })
  );
});
