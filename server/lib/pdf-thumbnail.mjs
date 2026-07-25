import { createHash } from "node:crypto";

export function pdfThumbnailCacheFileName({
  relativePath,
  size,
  mtimeMs,
  page,
  crop,
  highlightQuery,
  scale
}) {
  const cropKey = crop ? `${crop.x}:${crop.y}:${crop.width}:${crop.height}` : "cover";
  const identity = [
    "pdf-preview-v9",
    relativePath,
    `${size}:${mtimeMs}`,
    page,
    cropKey,
    String(highlightQuery || "").toLocaleLowerCase(),
    scale
  ].join("\n");
  return `${createHash("sha256").update(identity, "utf8").digest("hex")}.png`;
}
