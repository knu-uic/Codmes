#!/usr/bin/env python3
"""Codmes document extraction worker.

This worker uses explicit, format-specific extractors installed by Codmes
runtime bootstrap:

- PyMuPDF4LLM: PDF to Markdown/table-oriented extraction
- PyMuPDF: PDF text extraction and PDF block coordinates
- MarkItDown/python-docx/python-pptx/openpyxl/xlrd: document/table extraction
- openpyxl/xlrd: spreadsheet extraction

Codmes intentionally does not depend on native OCR or office-conversion
binaries such as tesseract, pdftoppm, LibreOffice, or soffice. MarkItDown is
used through its default local/free converter path.

The Node server owns scheduling, caching, and indexing. This script only turns
one workspace file into normalized JSON text blocks.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import re
import sys
import tempfile
import zipfile
from collections import deque
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

import numpy as np
from PIL import Image, ImageFilter

try:
    import fitz  # PyMuPDF
except Exception:  # pragma: no cover - optional dependency
    fitz = None

try:
    import pymupdf4llm
except Exception:  # pragma: no cover - optional dependency
    pymupdf4llm = None

try:
    import pdfplumber
except Exception:  # pragma: no cover - optional dependency
    pdfplumber = None


IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic"}
OFFICE_EXTS = {".doc", ".docx", ".ppt", ".pptx", ".hwp", ".hwpx", ".odt", ".odp"}
SHEET_EXTS = {".xlsx", ".xls"}
SUPPORTED_ZIP_EXTS = {".zip", ".pdf", ".hwpx", ".hwp", ".xlsx", ".xls", ".ppt", ".pptx", ".doc", ".docx", *IMAGE_EXTS}
HWPX_PARA_NS = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract text for Codmes Search.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--relative", default="")
    parser.add_argument("--assets-dir", default="")
    parser.add_argument("--max-zip-members", type=int, default=int(os.getenv("CODMES_EXTRACT_MAX_ZIP_MEMBERS", "40")))
    parser.add_argument("--max-zip-depth", type=int, default=int(os.getenv("CODMES_EXTRACT_MAX_ZIP_DEPTH", "2")))
    args = parser.parse_args()

    input_path = Path(args.input)
    relative = args.relative or input_path.name
    try:
        result = extract_path(input_path, relative, args)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as exc:  # Keep stdout valid JSON for Node callers.
        print(json.dumps({
            "schemaVersion": 1,
            "path": relative,
            "kind": kind_for_path(relative),
            "text": "",
            "blocks": [],
            "warnings": [f"{type(exc).__name__}: {exc}"],
            "extractor": "codmes-document-worker",
        }, ensure_ascii=False))
        return 0


def extract_path(path: Path, relative: str, args: argparse.Namespace) -> dict[str, Any]:
    data = path.read_bytes()
    return extract_bytes(data, relative, args, depth=0)


def extract_bytes(data: bytes, name: str, args: argparse.Namespace, depth: int) -> dict[str, Any]:
    ext = Path(name.lower()).suffix
    warnings: list[str] = []
    blocks: list[dict[str, Any]] = []
    markdown = ""
    tables: list[dict[str, Any]] = []
    figures: list[dict[str, Any]] = []
    metadata: dict[str, Any] = {}

    if ext == ".pdf":
        metadata = analyze_pdf_structure(data)
        text, markdown, tables, figures, pdf_blocks, pdf_warnings = extract_pdf(
            data,
            name,
            Path(args.assets_dir) if args.assets_dir else None,
            metadata,
        )
        blocks.extend(pdf_blocks)
        warnings.extend(pdf_warnings)
    elif ext in IMAGE_EXTS:
        text, warning = markitdown_to_text(data, name)
        if warning:
            warnings.append(warning)
        if text:
            blocks.append(block(name, text, source="markitdown", page=None, kind="image"))
    elif ext == ".hwpx":
        text = hwpx_to_text(data)
        if text:
            blocks.append(block(name, text, source="hwpx", page=None, kind="document"))
    elif ext == ".hwp":
        text, warning = office_or_hwp_to_text(data, name)
        if warning:
            warnings.append(warning)
        if text:
            blocks.append(block(name, text, source="office", page=None, kind="document"))
    elif ext in {".docx", ".pptx"}:
        text = openxml_to_text(data, name)
        warning = None
        if not text:
            text, warning = office_to_text(data, name)
        if warning:
            warnings.append(warning)
        if text:
            blocks.append(block(name, text, source="openxml" if warning is None else "office", page=None, kind="document"))
    elif ext in {".doc", ".ppt", ".odt", ".odp"}:
        text, warning = office_to_text(data, name)
        if warning:
            warnings.append(warning)
        if text:
            blocks.append(block(name, text, source="office", page=None, kind="document"))
    elif ext == ".xlsx":
        text, warning = xlsx_to_text(data)
        if warning:
            warnings.append(warning)
        if text:
            blocks.append(block(name, text, source="spreadsheet", page=None, kind="spreadsheet"))
    elif ext == ".xls":
        text, warning = xls_to_text(data)
        if warning:
            warnings.append(warning)
        if text:
            blocks.append(block(name, text, source="spreadsheet", page=None, kind="spreadsheet"))
    elif ext == ".zip":
        text, zip_blocks, zip_warnings = zip_to_text(data, name, args, depth)
        blocks.extend(zip_blocks)
        warnings.extend(zip_warnings)
    else:
        text = data.decode("utf-8", "ignore")
        if text.strip():
            blocks.append(block(name, text, source="text", page=None, kind="file"))

    normalized = normalize_text(text)
    if not blocks and normalized:
        blocks.append(block(name, normalized, source="text", page=None, kind=kind_for_path(name)))

    return {
        "schemaVersion": 2,
        "path": name,
        "kind": kind_for_path(name),
        "text": normalized,
        "markdown": markdown or normalized,
        "tables": tables,
        "figures": figures,
        "blocks": blocks,
        "metadata": metadata,
        "warnings": warnings,
        "extractor": "codmes-document-worker",
    }


def analyze_pdf_structure(data: bytes) -> dict[str, Any]:
    """Classify the PDF once while retaining page signals for routing.

    A scanner OCR text layer does not make a page digital when a full-page
    raster is still the visible source. The document-level label is exposed to
    callers; page signals remain internal metadata for mixed processing.
    """

    if fitz is None:
        return {"pdfType": "mixed", "classificationVersion": 1, "pageSignals": []}
    try:
        document = fitz.open(stream=data, filetype="pdf")
    except Exception:
        return {"pdfType": "mixed", "classificationVersion": 1, "pageSignals": []}
    signals: list[dict[str, Any]] = []
    try:
        for page_number, page in enumerate(document, start=1):
            page_area = max(1.0, float(page.rect.width * page.rect.height))
            text = normalize_text(page.get_text("text") or "")
            character_count = len(re.sub(r"\s+", "", text))
            image_ratios = []
            for raw_bbox in pdf_image_bboxes(page):
                rect = fitz.Rect(raw_bbox) & page.rect
                image_ratios.append(max(0.0, rect.get_area()) / page_area)
            full_page_raster = max(image_ratios, default=0.0) >= 0.80
            suspicious_ratio = suspicious_text_ratio(text)
            native_text = character_count >= 40 and not full_page_raster and suspicious_ratio < 0.20
            signals.append({
                "page": page_number,
                "characterCount": character_count,
                "imageCount": len(image_ratios),
                "maxImageAreaRatio": round(max(image_ratios, default=0.0), 4),
                "fullPageRaster": full_page_raster,
                "nativeText": native_text,
                "suspiciousTextRatio": round(suspicious_ratio, 4),
            })
    finally:
        document.close()
    page_count = len(signals)
    if not page_count:
        pdf_type = "mixed"
    else:
        raster_ratio = sum(1 for signal in signals if signal["fullPageRaster"]) / page_count
        digital_ratio = sum(1 for signal in signals if signal["nativeText"]) / page_count
        if raster_ratio >= 0.80 and digital_ratio <= 0.20:
            pdf_type = "scanned"
        elif digital_ratio >= 0.80 and raster_ratio <= 0.20:
            pdf_type = "digital"
        else:
            pdf_type = "mixed"
    return {
        "pdfType": pdf_type,
        "classificationVersion": 1,
        "pageCount": page_count,
        "digitalPageCount": sum(1 for signal in signals if signal["nativeText"]),
        "fullPageRasterCount": sum(1 for signal in signals if signal["fullPageRaster"]),
        "pageSignals": signals,
    }


def suspicious_text_ratio(text: str) -> float:
    visible = [character for character in text if not character.isspace()]
    if not visible:
        return 0.0
    suspicious = sum(
        1 for character in visible
        if character == "\ufffd" or ord(character) < 32 or 0xE000 <= ord(character) <= 0xF8FF
    )
    return suspicious / len(visible)


def extract_pdf(
    data: bytes,
    name: str,
    assets_dir: Path | None = None,
    pdf_structure: dict[str, Any] | None = None,
) -> tuple[str, str, list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[str]]:
    warnings: list[str] = []
    blocks: list[dict[str, Any]] = []
    pymupdf_text, pymupdf_blocks, pymupdf_warning = pymupdf_pdf_to_blocks(data, name)
    if pymupdf_warning:
        warnings.append(pymupdf_warning)
    structure = pdf_structure or {}
    page_count = int(structure.get("pageCount") or 0)
    structured_page_limit = int(os.getenv("CODMES_PDF_STRUCTURED_MAX_PAGES", "160"))
    use_structured_extraction = (
        structure.get("pdfType") != "scanned"
        and (page_count == 0 or page_count <= structured_page_limit)
    )
    structured_text = ""
    tables: list[dict[str, Any]] = []
    if use_structured_extraction:
        structured_text, tables, structured_warning = pymupdf4llm_pdf_to_markdown(data, name)
        if structured_warning:
            warnings.append(structured_warning)

        fallback_tables, fallback_warning = pdfplumber_fallback_tables(data, name, tables)
        tables.extend(fallback_tables)
        if fallback_warning:
            warnings.append(fallback_warning)
    else:
        reason = "scanner raster" if structure.get("pdfType") == "scanned" else f"{page_count} pages"
        warnings.append(
            f"PDF fast path used for {reason}; page text and figures were indexed, "
            "while full-document table reconstruction was deferred."
        )

    figures, figure_warning = extract_pdf_figures(data, name, assets_dir, pdf_structure or {})
    if figure_warning:
        warnings.append(figure_warning)
    if structured_text:
        if pymupdf_blocks:
            blocks.extend(pymupdf_blocks)
        else:
            blocks.append(block(name, structured_text, source="pdf-markdown", page=None, kind="pdf", metadata={"pdfEngine": "pymupdf4llm"}))
        markdown = append_recovered_tables(structured_text, fallback_tables)
        return structured_text, markdown, tables, figures, blocks, warnings

    if pymupdf_text:
        blocks.extend(pymupdf_blocks)
        return pymupdf_text, pymupdf_text, tables, figures, blocks, warnings

    return "", "", tables, figures, blocks, warnings or ["PDF extraction produced no text."]


def extract_pdf_figures(
    data: bytes,
    name: str,
    assets_dir: Path | None,
    pdf_structure: dict[str, Any],
) -> tuple[list[dict[str, Any]], str | None]:
    """Render meaningful embedded-image placements as complete page crops.

    Scan PDFs often contain a full-page raster plus smaller repair/overlay image
    objects. Extracting the smaller object directly produces transparent or
    incomplete files, so its placement is used only as a crop seed and the
    composed PDF page is rendered instead. A full-page scan is never emitted as
    a figure by itself.
    """

    if fitz is None or assets_dir is None:
        return [], None
    try:
        document = fitz.open(stream=data, filetype="pdf")
    except Exception as exc:
        return [], f"PDF figure extraction could not open PDF: {exc}"

    figures: list[dict[str, Any]] = []
    try:
        for page_number, page in enumerate(document, start=1):
            page_rect = page.rect
            page_area = max(1.0, float(page_rect.width * page_rect.height))
            candidates: list[Any] = []
            image_bboxes = pdf_image_bboxes(page)
            has_full_page_raster = any(
                fitz.Rect(raw_bbox).get_area() / page_area >= 0.80
                for raw_bbox in image_bboxes
            )
            for raw_bbox in image_bboxes:
                bbox = fitz.Rect(raw_bbox) & page_rect
                area = max(0.0, float(bbox.width * bbox.height))
                ratio = area / page_area
                if bbox.width < 48 or bbox.height < 48 or ratio < 0.015:
                    continue
                if ratio >= 0.80:
                    continue
                # Scanner software often stores a full-page raster and then
                # dozens of narrow repair glyph strips on top. Those strips
                # are OCR/rendering evidence, not standalone figures. Keep a
                # reasonably self-contained visual region (for example the
                # diagram embedded in a scanned textbook page), but reject
                # near-page tiles and narrow text/table repair bands.
                if has_full_page_raster and (
                    ratio > 0.50
                    or bbox.width < page_rect.width * 0.20
                    or bbox.height < page_rect.height * 0.10
                ):
                    continue
                if any(rect_iou(bbox, existing) >= 0.90 for existing in candidates):
                    continue
                candidates.append(bbox)

            for bbox in candidates:
                selected_bbox, png, pixel_size = render_composed_figure_crop(
                    page,
                    bbox,
                    expand_visual_block=has_full_page_raster,
                    detect_complete_block=has_full_page_raster and len(document) <= 160,
                )
                digest = hashlib.sha256(png).hexdigest()
                filename = f"figure-p{page_number:04d}-{digest[:16]}.png"
                assets_dir.mkdir(parents=True, exist_ok=True)
                (assets_dir / filename).write_bytes(png)
                figures.append({
                    "id": f"figure-{digest[:24]}",
                    "number": len(figures) + 1,
                    "path": name,
                    "page": page_number,
                    "source": "pdf-image-placement",
                    "assetFile": filename,
                    "mime": "image/png",
                    "width": pixel_size[0],
                    "height": pixel_size[1],
                    "bbox": pdf_bbox(selected_bbox, page_rect),
                    "nearbyText": normalize_text(page.get_textbox(selected_bbox) or "")[:1200],
                })
        continuation_limit = int(os.getenv("CODMES_PDF_CONTINUATION_MAX_PAGES", "160"))
        if len(document) <= continuation_limit:
            figures.extend(extract_pdf_continuations(document, name, assets_dir, pdf_structure, len(figures)))
            warning = None
        else:
            warning = (
                f"Adjacent-page continuation detection skipped for {len(document)} pages "
                f"(limit: {continuation_limit})."
            )
        return figures, warning
    except Exception as exc:
        return figures, f"PDF figure extraction failed: {exc}"
    finally:
        document.close()


def pdf_image_bboxes(page: Any) -> list[tuple[float, float, float, float]]:
    """Return placed-image rectangles without hashing or decoding image streams.

    ``get_image_info(xrefs=True)`` computes digests while resolving xrefs. On a
    600-page scanned book this alone can take several minutes because every
    full-page raster is decoded. TextPage image blocks expose the same placed
    rectangles and keep classification / crop discovery proportional to page
    layout complexity instead of source-image size.
    """

    flags = fitz.TEXTFLAGS_BLOCKS | fitz.TEXT_PRESERVE_IMAGES
    return [
        (float(item[0]), float(item[1]), float(item[2]), float(item[3]))
        for item in page.get_text("blocks", flags=flags)
        if len(item) > 6 and item[6] == 1
    ]


def render_composed_figure_crop(
    page: Any,
    seed_bbox: Any,
    *,
    expand_visual_block: bool,
    detect_complete_block: bool = True,
) -> tuple[Any, bytes, tuple[int, int]]:
    if not expand_visual_block:
        matrix = fitz.Matrix(2.5, 2.5)
        pixmap = page.get_pixmap(matrix=matrix, clip=seed_bbox, alpha=False)
        return seed_bbox, pixmap.tobytes("png"), (pixmap.width, pixmap.height)

    padding_x = max(18.0, float(seed_bbox.width) * 0.12)
    padding_y = max(18.0, float(seed_bbox.height) * 0.12)
    render_bbox = fitz.Rect(
        seed_bbox.x0 - padding_x,
        seed_bbox.y0 - padding_y,
        seed_bbox.x1 + padding_x,
        seed_bbox.y1 + padding_y,
    ) & page.rect
    if detect_complete_block:
        detect_matrix = fitz.Matrix(1.0, 1.0)
        detected_pixmap = page.get_pixmap(matrix=detect_matrix, alpha=False)
        detected_page = Image.open(io.BytesIO(detected_pixmap.tobytes("png"))).convert("RGB")
        scale_x = detected_page.width / float(page.rect.width)
        scale_y = detected_page.height / float(page.rect.height)
        seed = (
            round(seed_bbox.x0 * scale_x),
            round(seed_bbox.y0 * scale_y),
            round(seed_bbox.x1 * scale_x),
            round(seed_bbox.y1 * scale_y),
        )
        candidates = []
        for visual in visual_blocks(detected_page):
            overlap_width = max(0, min(seed[2], visual[2]) - max(seed[0], visual[0]))
            overlap_height = max(0, min(seed[3], visual[3]) - max(seed[1], visual[1]))
            overlap_ratio = overlap_width * overlap_height / max(
                1, (seed[2] - seed[0]) * (seed[3] - seed[1])
            )
            block_ratio = (
                (visual[2] - visual[0]) * (visual[3] - visual[1])
                / max(1, detected_page.width * detected_page.height)
            )
            if overlap_ratio >= 0.45 and block_ratio <= 0.65:
                candidates.append((overlap_ratio, block_ratio, visual))
        if candidates:
            visual = max(candidates)[2]
            render_bbox = fitz.Rect(
                visual[0] / scale_x,
                visual[1] / scale_y,
                visual[2] / scale_x,
                visual[3] / scale_y,
            ) & page.rect

    # The PDF compositor already knows the exact image placement. Rendering a
    # detected visual block preserves scanner overlays and nearby labels. Large
    # books use the padded fallback so hundreds of figures remain fast.
    matrix = fitz.Matrix(1.8, 1.8)
    pixmap = page.get_pixmap(matrix=matrix, clip=render_bbox, alpha=False)
    return render_bbox, pixmap.tobytes("png"), (pixmap.width, pixmap.height)


def visual_blocks(image: Image.Image) -> list[tuple[int, int, int, int]]:
    """Dependency-light equivalent of the KNU visual block detector."""

    rgb = np.asarray(image.convert("RGB"))
    height, width = rgb.shape[:2]
    gray_image = Image.fromarray(np.asarray(image.convert("L")))
    blur = np.asarray(gray_image.filter(ImageFilter.GaussianBlur(radius=max(3.0, width / 180))))
    paper = float(np.percentile(blur, 90))
    mask_image = Image.fromarray(((blur < paper - 7).astype("uint8") * 255))
    close_size = odd_filter_size(max(5, width // 80), 31)
    open_size = odd_filter_size(max(3, width // 150), 15)
    mask_image = mask_image.filter(ImageFilter.MaxFilter(close_size)).filter(ImageFilter.MinFilter(close_size))
    mask_image = mask_image.filter(ImageFilter.MinFilter(open_size)).filter(ImageFilter.MaxFilter(open_size))
    mask = np.asarray(mask_image) > 0
    visited = np.zeros(mask.shape, dtype=bool)
    boxes = []
    for y, x in zip(*np.nonzero(mask & ~visited)):
        if visited[y, x]:
            continue
        queue = deque([(int(x), int(y))])
        visited[y, x] = True
        min_x = max_x = int(x)
        min_y = max_y = int(y)
        while queue:
            current_x, current_y = queue.popleft()
            min_x = min(min_x, current_x)
            max_x = max(max_x, current_x)
            min_y = min(min_y, current_y)
            max_y = max(max_y, current_y)
            for next_y in range(max(0, current_y - 1), min(height, current_y + 2)):
                for next_x in range(max(0, current_x - 1), min(width, current_x + 2)):
                    if mask[next_y, next_x] and not visited[next_y, next_x]:
                        visited[next_y, next_x] = True
                        queue.append((next_x, next_y))
        box_width = max_x - min_x + 1
        box_height = max_y - min_y + 1
        area_ratio = box_width * box_height / max(1, width * height)
        if area_ratio >= 0.01 and box_width >= width * 0.25 and box_height >= height * 0.04:
            boxes.append((min_x, min_y, max_x + 1, max_y + 1))
    return sorted(boxes, key=lambda box: (box[1], box[0]))


def extract_pdf_continuations(
    document: Any,
    name: str,
    assets_dir: Path,
    pdf_structure: dict[str, Any],
    figure_offset: int,
) -> list[dict[str, Any]]:
    """Detect high-confidence tables/code that continue over adjacent scan pages."""

    signals = {
        int(signal.get("page") or 0): signal
        for signal in pdf_structure.get("pageSignals") or []
    }
    results: list[dict[str, Any]] = []
    detect_matrix = fitz.Matrix(54 / 72, 54 / 72)
    stitch_matrix = fitz.Matrix(150 / 72, 150 / 72)
    previous: tuple[int, Any, Image.Image] | None = None
    for page_index in range(len(document)):
        page_number = page_index + 1
        if not signals.get(page_number, {}).get("fullPageRaster"):
            previous = None
            continue
        page = document[page_index]
        pixmap = page.get_pixmap(matrix=detect_matrix, alpha=False)
        image = Image.open(io.BytesIO(pixmap.tobytes("png"))).convert("RGB")
        if previous is not None:
            previous_number, previous_page, previous_image = previous
            candidate = continuation_candidate(previous_image, image, previous_page, page)
            if candidate:
                high_previous = Image.open(io.BytesIO(
                    previous_page.get_pixmap(matrix=stitch_matrix, alpha=False).tobytes("png")
                )).convert("RGB")
                high_next = Image.open(io.BytesIO(
                    page.get_pixmap(matrix=stitch_matrix, alpha=False).tobytes("png")
                )).convert("RGB")
                png = stitched_continuation_image(
                    high_previous, high_next,
                    candidate["previousBox"], candidate["nextBox"],
                )
                digest = hashlib.sha256(png).hexdigest()
                filename = f"continuation-p{previous_number:04d}-p{page_number:04d}-{digest[:16]}.png"
                assets_dir.mkdir(parents=True, exist_ok=True)
                (assets_dir / filename).write_bytes(png)
                with Image.open(io.BytesIO(png)) as stitched:
                    width, height = stitched.size
                results.append({
                    "id": f"figure-{digest[:24]}",
                    "number": figure_offset + len(results) + 1,
                    "path": name,
                    "page": previous_number,
                    "pageSpan": [previous_number, page_number],
                    "source": "pdf-page-continuation",
                    "assetFile": filename,
                    "mime": "image/png",
                    "width": width,
                    "height": height,
                    "bbox": None,
                    "nearbyText": normalize_text(
                        f"{candidate['previousText']}\n{candidate['nextText']}"
                    )[:2400],
                    "continuationKind": candidate["kind"],
                    "segments": [
                        {"pageNumber": previous_number, "bboxNormalized": candidate["previousBox"]},
                        {"pageNumber": page_number, "bboxNormalized": candidate["nextBox"]},
                    ],
                    "continuationEvidence": candidate["evidence"],
                    "confidence": candidate["confidence"],
                })
        previous = (page_number, page, image)
    return results


def continuation_candidate(
    previous_image: Image.Image,
    next_image: Image.Image,
    previous_page: Any,
    next_page: Any,
) -> dict[str, Any] | None:
    previous_blocks = [box for box in visual_blocks(previous_image) if box[3] >= previous_image.height * 0.76]
    next_blocks = [box for box in visual_blocks(next_image) if box[1] <= next_image.height * 0.24]
    if not previous_blocks or not next_blocks:
        return None
    previous_box = max(previous_blocks, key=lambda box: box[3])
    next_box = min(next_blocks, key=lambda box: box[1])
    previous_normalized = normalized_pixel_box(previous_box, previous_image.size)
    next_normalized = normalized_pixel_box(next_box, next_image.size)
    previous_width = previous_normalized[2] - previous_normalized[0]
    next_width = next_normalized[2] - next_normalized[0]
    overlap = max(
        0.0,
        min(previous_normalized[2], next_normalized[2])
        - max(previous_normalized[0], next_normalized[0]),
    )
    overlap_ratio = overlap / max(0.001, min(previous_width, next_width))
    width_ratio = previous_width / max(0.001, next_width)
    if overlap_ratio < 0.72 or not 0.72 <= width_ratio <= 1.38:
        return None
    previous_text = previous_page.get_textbox(pixel_box_to_page(previous_box, previous_image, previous_page)).strip()
    next_text = next_page.get_textbox(pixel_box_to_page(next_box, next_image, next_page)).strip()
    previous_numbers = leading_line_numbers(previous_text)
    next_numbers = leading_line_numbers(next_text)
    sequential = bool(previous_numbers and next_numbers and previous_numbers[-1] + 1 == next_numbers[0])
    shared = shared_identifiers(previous_text, next_text)
    vertical_matches = matching_vertical_rules(
        vertical_signature(previous_image, previous_box),
        vertical_signature(next_image, next_box),
    )
    sequential_confirmed = sequential and bool(shared)
    grid_confirmed = vertical_matches >= 3 and len(shared) >= 3
    if not sequential_confirmed and not grid_confirmed:
        return None
    return {
        "kind": "code" if sequential_confirmed else "table",
        "confidence": 0.98 if sequential_confirmed else 0.92,
        "previousBox": previous_normalized,
        "nextBox": next_normalized,
        "previousText": previous_text,
        "nextText": next_text,
        "evidence": {
            "sequentialLineNumbers": sequential,
            "sharedIdentifiers": shared[:12],
            "matchingVerticalRules": vertical_matches,
            "horizontalOverlapRatio": round(overlap_ratio, 4),
            "widthRatio": round(width_ratio, 4),
        },
    }


def normalized_pixel_box(box: tuple[int, int, int, int], size: tuple[int, int]) -> list[float]:
    width, height = size
    return [
        round(box[0] / width, 5), round(box[1] / height, 5),
        round(box[2] / width, 5), round(box[3] / height, 5),
    ]


def pixel_box_to_page(box: tuple[int, int, int, int], image: Image.Image, page: Any) -> Any:
    return fitz.Rect(
        box[0] * page.rect.width / image.width,
        box[1] * page.rect.height / image.height,
        box[2] * page.rect.width / image.width,
        box[3] * page.rect.height / image.height,
    )


def leading_line_numbers(text: str) -> list[int]:
    return [int(value) for value in re.findall(r"(?m)^\s*(\d{1,4})(?=\s|$)", text or "")]


def shared_identifiers(left: str, right: str) -> list[str]:
    pattern = r"[A-Za-z_][A-Za-z0-9_]{4,}"
    return sorted(
        {value.lower() for value in re.findall(pattern, left or "")}
        & {value.lower() for value in re.findall(pattern, right or "")}
    )


def vertical_signature(image: Image.Image, box: tuple[int, int, int, int]) -> list[float]:
    crop = np.asarray(image.crop(box).convert("L"))
    height, width = crop.shape
    threshold = float(np.percentile(crop, 45))
    dark = crop <= threshold
    counts = np.count_nonzero(dark, axis=0)
    indices = np.flatnonzero(counts >= max(8, int(height * 0.35))).tolist()
    groups: list[list[int]] = []
    for value in indices:
        if not groups or value - groups[-1][-1] > 1:
            groups.append([value])
        else:
            groups[-1].append(value)
    return [round(sum(group) / len(group) / max(1, width), 3) for group in groups]


def matching_vertical_rules(left: list[float], right: list[float]) -> int:
    used: set[int] = set()
    matches = 0
    for value in left:
        choices = [
            (abs(value - other), index)
            for index, other in enumerate(right)
            if index not in used and abs(value - other) <= 0.035
        ]
        if choices:
            _distance, index = min(choices)
            used.add(index)
            matches += 1
    return matches


def stitched_continuation_image(
    previous: Image.Image,
    next_image: Image.Image,
    previous_box: list[float],
    next_box: list[float],
) -> bytes:
    def pixels(normalized: list[float], image: Image.Image) -> tuple[int, int, int, int]:
        return (
            max(0, round(normalized[0] * image.width)),
            max(0, round(normalized[1] * image.height)),
            min(image.width, round(normalized[2] * image.width)),
            min(image.height, round(normalized[3] * image.height)),
        )
    first = previous.crop(pixels(previous_box, previous)).convert("RGB")
    second = next_image.crop(pixels(next_box, next_image)).convert("RGB")
    target_width = max(first.width, second.width)
    separator = 18
    canvas = Image.new("RGB", (target_width, first.height + separator + second.height), "white")
    canvas.paste(first, ((target_width - first.width) // 2, 0))
    canvas.paste(second, ((target_width - second.width) // 2, first.height + separator))
    output = io.BytesIO()
    canvas.save(output, "PNG", optimize=True)
    return output.getvalue()


def odd_filter_size(value: int, maximum: int) -> int:
    size = min(maximum, max(3, int(value)))
    return size if size % 2 else size + 1


def rect_iou(left: Any, right: Any) -> float:
    overlap = left & right
    intersection = max(0.0, float(overlap.width * overlap.height))
    union = max(0.0, float(left.width * left.height + right.width * right.height - intersection))
    return intersection / union if union else 0.0


def pdf_bbox(rect: Any, page_rect: Any) -> dict[str, Any]:
    width = float(page_rect.width or 0)
    height = float(page_rect.height or 0)
    return {
        "unit": "pdf-point",
        "x": float(rect.x0),
        "y": float(rect.y0),
        "width": float(rect.width),
        "height": float(rect.height),
        "pageWidth": width,
        "pageHeight": height,
        "normalized": {
            "x": float(rect.x0) / width if width else 0,
            "y": float(rect.y0) / height if height else 0,
            "width": float(rect.width) / width if width else 0,
            "height": float(rect.height) / height if height else 0,
        },
    }


def pymupdf4llm_pdf_to_markdown(data: bytes, name: str) -> tuple[str, list[dict[str, Any]], str | None]:
    if pymupdf4llm is None:
        return "", [], "PyMuPDF4LLM not installed; PDF Markdown/table extraction unavailable."
    if fitz is None:
        return "", [], "PyMuPDF not installed; PyMuPDF4LLM unavailable."
    try:
        doc = fitz.open(stream=data, filetype="pdf")
    except Exception as exc:
        return "", [], f"PyMuPDF4LLM could not open PDF: {exc}"
    try:
        page_chunks = pymupdf4llm.to_markdown(
            doc,
            page_chunks=True,
            write_images=False,
            embed_images=False,
            ignore_images=True,
            page_separators=True,
            table_strategy=os.getenv("CODMES_PDF_TABLE_STRATEGY", "lines_strict"),
            show_progress=False,
        )
        markdown = "\n\n".join(str(page.get("text") or "").strip() for page in page_chunks).strip()
        tables = markdown_tables_from_page_chunks(page_chunks, doc, name)
        text = normalize_text(markdown)
        return text, tables, None if text else "PyMuPDF4LLM returned no text."
    except Exception as exc:
        return "", [], f"PyMuPDF4LLM failed: {exc}"
    finally:
        doc.close()


def markdown_tables_from_page_chunks(page_chunks: list[dict[str, Any]], doc: Any, name: str) -> list[dict[str, Any]]:
    tables: list[dict[str, Any]] = []
    for page_chunk in page_chunks:
        page_number = int((page_chunk.get("metadata") or {}).get("page_number") or len(tables) + 1)
        page_text = str(page_chunk.get("text") or "")
        page = doc[page_number - 1]
        for box in page_chunk.get("page_boxes") or []:
            if box.get("class") != "table":
                continue
            start, end = (box.get("pos") or [0, 0])[:2]
            table_markdown = page_text[int(start):int(end)].strip()
            parsed = parse_markdown_table(table_markdown)
            if not parsed:
                continue
            tables.append(table_record(
                name,
                page_number,
                len(tables) + 1,
                parsed[0],
                parsed[1],
                table_markdown,
                box.get("bbox"),
                float(page.rect.width),
                float(page.rect.height),
                "pymupdf4llm",
            ))
    return tables


def parse_markdown_table(markdown: str) -> tuple[list[str], list[list[str]]] | None:
    lines = [line.strip() for line in str(markdown or "").splitlines() if line.strip().startswith("|")]
    parsed = [split_markdown_row(line) for line in lines]
    parsed = [row for row in parsed if row and not all(re.fullmatch(r":?-{3,}:?", cell.replace(" ", "")) for cell in row)]
    if len(parsed) < 2 or len(parsed[0]) < 2:
        return None
    width = max(len(row) for row in parsed)
    normalized = [row + [""] * (width - len(row)) for row in parsed]
    return normalize_table_headers(normalized[0]), normalized[1:]


def split_markdown_row(line: str) -> list[str]:
    value = line.strip().strip("|")
    cells = re.split(r"(?<!\\)\|", value)
    return [clean_table_cell(cell) for cell in cells]


def clean_table_cell(value: Any) -> str:
    text = "" if value is None else str(value)
    text = re.sub(r"<br\s*/?>", " ", text, flags=re.IGNORECASE)
    text = text.replace("**", "").replace("__", "").replace("\\|", "|")
    return re.sub(r"\s+", " ", text).strip()


def normalize_table_headers(headers: list[str]) -> list[str]:
    normalized = [clean_table_cell(header) for header in headers]
    for index in range(len(normalized) - 1):
        left = normalized[index]
        right = normalized[index + 1]
        if not re.match(r"^Pri\b", left, flags=re.IGNORECASE) or not re.match(r"^ce\b", right, flags=re.IGNORECASE):
            continue
        left_body = re.sub(r"^Pri\b", "", left, flags=re.IGNORECASE).strip()
        right_body = re.sub(r"^ce\b", "", right, flags=re.IGNORECASE).strip()
        left_body = re.sub(r"\bInput$", "", left_body, flags=re.IGNORECASE).strip()
        right_body = re.sub(r"\bOutput$", "", right_body, flags=re.IGNORECASE).strip()
        shared = re.sub(r"\s+", " ", f"Price {left_body} {right_body}").strip()
        normalized[index] = f"{shared} Input"
        normalized[index + 1] = f"{shared} Output"
    return normalized


def table_record(
    name: str,
    page: int,
    index: int,
    headers: list[str],
    rows: list[list[str]],
    markdown: str,
    bbox_values: Any,
    page_width: float,
    page_height: float,
    engine: str,
) -> dict[str, Any]:
    bbox = None
    if bbox_values and len(bbox_values) >= 4:
        x0, y0, x1, y1 = map(float, bbox_values[:4])
        bbox = {
            "unit": "pdf-point",
            "x": x0,
            "y": y0,
            "width": max(0.0, x1 - x0),
            "height": max(0.0, y1 - y0),
            "pageWidth": page_width,
            "pageHeight": page_height,
            "normalized": {
                "x": x0 / page_width if page_width else 0,
                "y": y0 / page_height if page_height else 0,
                "width": max(0.0, x1 - x0) / page_width if page_width else 0,
                "height": max(0.0, y1 - y0) / page_height if page_height else 0,
            },
        }
    return {
        "id": f"table-page-{page}-{index}",
        "path": name,
        "page": page,
        "source": "pdf-table",
        "headers": headers,
        "rows": rows,
        "markdown": markdown.strip() or markdown_table(headers, rows),
        "bbox": bbox,
        "metadata": {"tableEngine": engine, "rowCount": len(rows), "columnCount": len(headers)},
    }


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    def row(values: list[str]) -> str:
        return "| " + " | ".join(str(value or "").replace("\n", "<br>").replace("|", "\\|") for value in values) + " |"
    return "\n".join([row(headers), row(["---"] * len(headers)), *(row(item) for item in rows)])


def append_recovered_tables(markdown: str, tables: list[dict[str, Any]]) -> str:
    if not tables:
        return markdown
    sections = [markdown.rstrip(), "", "## Recovered tables"]
    for table in tables:
        sections.extend([
            "",
            f"### Page {int(table.get('page') or 0)}",
            "",
            str(table.get("markdown") or "").strip(),
        ])
    return "\n".join(sections).strip()


def pdfplumber_fallback_tables(
    data: bytes,
    name: str,
    existing: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], str | None]:
    if pdfplumber is None:
        return [], "pdfplumber not installed; fallback table extraction unavailable."
    existing_pages = {int(table.get("page") or 0) for table in existing}
    results: list[dict[str, Any]] = []
    try:
        with pdfplumber.open(io.BytesIO(data)) as document:
            for page_number, page in enumerate(document.pages, start=1):
                if page_number in existing_pages:
                    continue
                for candidate in page.find_tables():
                    extracted = candidate.extract() or []
                    headers = normalize_table_headers(list(extracted[0] if extracted else []))
                    if sum(bool(value) for value in headers) < 2:
                        continue
                    rows = [[clean_table_cell(value) for value in row] for row in extracted[1:]]
                    bbox = list(candidate.bbox)
                    if not rows:
                        expanded = expand_header_table(page, candidate)
                        if expanded:
                            headers, rows, bbox = expanded
                    rows = [row for row in rows if any(row)]
                    if not rows:
                        continue
                    width = max(len(headers), *(len(row) for row in rows))
                    headers += [""] * (width - len(headers))
                    rows = [row + [""] * (width - len(row)) for row in rows]
                    results.append(table_record(
                        name,
                        page_number,
                        len(existing) + len(results) + 1,
                        headers,
                        rows,
                        markdown_table(headers, rows),
                        bbox,
                        float(page.width),
                        float(page.height),
                        "pdfplumber",
                    ))
        return results, None
    except Exception as exc:
        return results, f"pdfplumber table extraction failed: {exc}"


def expand_header_table(page: Any, candidate: Any) -> tuple[list[str], list[list[str]], list[float]] | None:
    x0, top, x1, bottom = map(float, candidate.bbox)
    boundaries = sorted({round(float(cell[0]), 3) for cell in candidate.cells} | {round(float(cell[2]), 3) for cell in candidate.cells})
    if len(boundaries) < 3:
        return None
    horizontal_edges = [
        edge for edge in page.horizontal_edges
        if float(edge.get("top", -1)) >= top - 2
        and min(float(edge.get("x1", 0)), x1) - max(float(edge.get("x0", 0)), x0) >= (x1 - x0) * 0.65
    ]
    if len(horizontal_edges) < 3:
        return None
    extended_bottom = max(float(edge["top"]) for edge in horizontal_edges)
    cropped = page.crop((x0, top, x1, min(float(page.height), extended_bottom + 1)))
    extracted = cropped.extract_table({
        "vertical_strategy": "explicit",
        "explicit_vertical_lines": boundaries,
        "horizontal_strategy": "lines",
        "snap_tolerance": 4,
        "join_tolerance": 4,
        "intersection_tolerance": 5,
    }) or []
    if len(extracted) < 2:
        return None
    headers = normalize_table_headers(list(extracted[0]))
    rows = [[clean_table_cell(value) for value in row] for row in extracted[1:]]
    return headers, rows, [x0, top, x1, extended_bottom]


def pymupdf_pdf_to_blocks(data: bytes, name: str) -> tuple[str, list[dict[str, Any]], str | None]:
    if fitz is None:
        return "", [], "PyMuPDF not installed; PDF coordinates unavailable."
    try:
        doc = fitz.open(stream=data, filetype="pdf")
    except Exception as exc:
        return "", [], f"PyMuPDF could not open PDF: {exc}"
    blocks: list[dict[str, Any]] = []
    page_texts: list[str] = []
    try:
        for page_index, page in enumerate(doc, start=1):
            page_text = normalize_text(page.get_text("text") or "")
            if page_text:
                page_texts.append(page_text)
            rect = page.rect
            page_width = float(rect.width or 0)
            page_height = float(rect.height or 0)
            for block_index, item in enumerate(page.get_text("blocks") or [], start=1):
                if len(item) < 5:
                    continue
                x0, y0, x1, y1, text = item[:5]
                text = normalize_text(text)
                if not text:
                    continue
                bbox = {
                    "unit": "pdf-point",
                    "x": float(x0),
                    "y": float(y0),
                    "width": max(0.0, float(x1) - float(x0)),
                    "height": max(0.0, float(y1) - float(y0)),
                    "pageWidth": page_width,
                    "pageHeight": page_height,
                }
                if page_width > 0 and page_height > 0:
                    bbox["normalized"] = {
                        "x": float(x0) / page_width,
                        "y": float(y0) / page_height,
                        "width": max(0.0, float(x1) - float(x0)) / page_width,
                        "height": max(0.0, float(y1) - float(y0)) / page_height,
                    }
                blocks.append(block(
                    name,
                    text,
                    source="pdf-text",
                    page=page_index,
                    kind="pdf",
                    metadata={
                        "pdfEngine": "pymupdf",
                        "pageCount": doc.page_count,
                        "blockIndex": block_index,
                    },
                    bbox=bbox,
                ))
    finally:
        doc.close()
    return normalize_text("\n\n".join(page_texts)), blocks, None


def hwpx_to_text(data: bytes) -> str:
    parts: list[str] = []
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        names = sorted(name for name in zf.namelist() if name.startswith("Contents/section") and name.endswith(".xml"))
        for name in names:
            root = ET.fromstring(zf.read(name))
            for item in root.iter(f"{HWPX_PARA_NS}t"):
                if item.text:
                    parts.append(item.text)
    return normalize_text("\n".join(parts))


def office_or_hwp_to_text(data: bytes, filename: str) -> tuple[str, str | None]:
    text, warning = office_to_text(data, filename)
    if text:
        return text, warning
    ole_text = hwp_ole_strings_to_text(data)
    if ole_text:
        return ole_text, warning
    return "", warning or "HWP extraction failed."


def openxml_to_text(data: bytes, filename: str) -> str:
    ext = Path(filename.lower()).suffix
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            if ext == ".docx":
                names = ["word/document.xml"]
            elif ext == ".pptx":
                names = sorted(name for name in zf.namelist() if name.startswith("ppt/slides/slide") and name.endswith(".xml"))
            else:
                return ""
            parts: list[str] = []
            for name in names:
                if name not in zf.namelist():
                    continue
                root = ET.fromstring(zf.read(name))
                texts = [
                    node.text or ""
                    for node in root.iter()
                    if (node.tag.endswith("}t") or node.tag == "t") and node.text
                ]
                if texts:
                    if ext == ".pptx":
                        parts.append(f"[Slide: {Path(name).stem}]\n" + "\n".join(texts))
                    else:
                        parts.append("\n".join(texts))
            return normalize_text("\n\n".join(parts))
    except Exception:
        return ""


def office_to_text(data: bytes, filename: str) -> tuple[str, str | None]:
    markitdown_text, markitdown_warning = markitdown_to_text(data, filename)
    if markitdown_text:
        return markitdown_text, markitdown_warning
    return "", markitdown_warning or "No library extractor available for this document."


def markitdown_to_text(data: bytes, filename: str) -> tuple[str, str | None]:
    try:
        from markitdown import MarkItDown  # type: ignore
    except Exception:
        return "", "MarkItDown not installed."
    suffix = Path(filename).suffix or ".bin"
    with tempfile.TemporaryDirectory(prefix="codmes-markitdown-") as tmp:
        input_path = Path(tmp) / f"input{suffix}"
        input_path.write_bytes(data)
        try:
            result = MarkItDown().convert(str(input_path))
            text = normalize_text(getattr(result, "text_content", "") or "")
            return text, None if text else "MarkItDown returned no text."
        except Exception as exc:
            return "", f"MarkItDown failed: {exc}"


def hwp_ole_strings_to_text(data: bytes) -> str:
    decoded = data.decode("utf-16le", "ignore")
    runs: list[str] = []
    pattern = r"[\uAC00-\uD7A3A-Za-z0-9\s().,/%·\\-:]{3,}"
    for match in re.finditer(pattern, decoded):
        text = " ".join(match.group(0).split())
        if any("가" <= ch <= "힣" for ch in text):
            runs.append(text)
    return normalize_text("\n".join(dict.fromkeys(runs)))


def xlsx_to_text(data: bytes) -> tuple[str, str | None]:
    try:
        import openpyxl  # type: ignore
    except Exception:
        return xlsx_to_text_minimal(data), "openpyxl not found; used minimal XLSX XML extractor."
    workbook = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)
    out: list[str] = []
    for sheet in workbook.worksheets:
        out.append(f"[Sheet: {sheet.title}]")
        headers: list[str] | None = None
        rows: list[list[str]] = []
        for row in sheet.iter_rows(values_only=True):
            cells = trim_empty_tail(["" if value is None else str(value).strip() for value in row])
            if any(cell.strip() for cell in cells):
                rows.append(cells)
        for index, row in enumerate(rows):
            if headers is None and looks_like_header(row, rows[index + 1:index + 4]):
                headers = dedupe_headers(row)
                out.append("[표 헤더] " + " | ".join(headers))
                continue
            row_text = " | ".join(cell for cell in row if cell)
            if row_text:
                out.append(("[행] " if headers else "") + row_text)
        out.append(f"[End Sheet: {sheet.title}]")
    return normalize_text("\n".join(out)), None


def xlsx_to_text_minimal(data: bytes) -> str:
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        shared: list[str] = []
        if "xl/sharedStrings.xml" in zf.namelist():
            root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
            for si in root.iter():
                if si.tag.endswith("}si") or si.tag == "si":
                    text = "".join(t.text or "" for t in si.iter() if t.tag.endswith("}t") or t.tag == "t")
                    shared.append(text)
        parts: list[str] = []
        for name in sorted(n for n in zf.namelist() if n.startswith("xl/worksheets/sheet") and n.endswith(".xml")):
            parts.append(f"[Sheet: {Path(name).stem}]")
            root = ET.fromstring(zf.read(name))
            for row in root.iter():
                if not (row.tag.endswith("}row") or row.tag == "row"):
                    continue
                values: list[str] = []
                for cell in row:
                    if not (cell.tag.endswith("}c") or cell.tag == "c"):
                        continue
                    cell_type = cell.attrib.get("t")
                    value = ""
                    for child in cell:
                        if child.tag.endswith("}v") or child.tag == "v":
                            value = child.text or ""
                    if cell_type == "s" and value.isdigit() and int(value) < len(shared):
                        value = shared[int(value)]
                    if value:
                        values.append(value)
                if values:
                    parts.append(" | ".join(values))
        return normalize_text("\n".join(parts))


def xls_to_text(data: bytes) -> tuple[str, str | None]:
    try:
        import xlrd  # type: ignore
    except Exception:
        return "", "xlrd not found; XLS extraction skipped."
    book = xlrd.open_workbook(file_contents=data)
    out: list[str] = []
    for sheet in book.sheets():
        out.append(f"[Sheet: {sheet.name}]")
        headers: list[str] | None = None
        rows: list[list[str]] = []
        for row_index in range(sheet.nrows):
            cells = trim_empty_tail([
                "" if sheet.cell_value(row_index, col) is None else str(sheet.cell_value(row_index, col)).strip()
                for col in range(sheet.ncols)
            ])
            if any(cell.strip() for cell in cells):
                rows.append(cells)
        for index, row in enumerate(rows):
            if headers is None and looks_like_header(row, rows[index + 1:index + 4]):
                headers = dedupe_headers(row)
                out.append("[표 헤더] " + " | ".join(headers))
                continue
            row_text = " | ".join(cell for cell in row if cell)
            if row_text:
                out.append(("[행] " if headers else "") + row_text)
        out.append(f"[End Sheet: {sheet.name}]")
    return normalize_text("\n".join(out)), None


def zip_to_text(data: bytes, name: str, args: argparse.Namespace, depth: int) -> tuple[str, list[dict[str, Any]], list[str]]:
    if depth > args.max_zip_depth:
        return "", [], ["ZIP depth limit reached."]
    texts: list[str] = []
    blocks: list[dict[str, Any]] = []
    warnings: list[str] = []
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        members = [item for item in zf.infolist() if not item.is_dir() and "__MACOSX/" not in item.filename and not Path(item.filename).name.startswith(".")]
        handled = 0
        for item in members:
            if handled >= args.max_zip_members:
                warnings.append(f"ZIP member limit reached: {args.max_zip_members}/{len(members)}")
                break
            ext = Path(item.filename.lower()).suffix
            if ext not in SUPPORTED_ZIP_EXTS:
                continue
            handled += 1
            child_name = f"{name}/{item.filename}"
            try:
                extracted = extract_bytes(zf.read(item), child_name, args, depth + 1)
                child_text = extracted.get("text") or ""
                if child_text:
                    labelled = f"[압축 내부 파일: {item.filename}]\n{child_text}"
                    texts.append(labelled)
                    blocks.extend(extracted.get("blocks") or [block(child_name, labelled, source="zip", page=None, kind=kind_for_path(child_name))])
                warnings.extend(extracted.get("warnings") or [])
            except Exception as exc:
                warnings.append(f"{item.filename}: {type(exc).__name__}: {exc}")
    return normalize_text("\n\n".join(texts)), blocks, warnings


def block(
    path: str,
    text: str,
    *,
    source: str,
    page: int | None,
    kind: str,
    metadata: dict[str, Any] | None = None,
    bbox: dict[str, Any] | None = None,
    confidence: float | None = None,
) -> dict[str, Any]:
    return {
        "path": path,
        "kind": kind,
        "source": source,
        "page": page,
        "text": normalize_text(text),
        "bbox": bbox,
        "confidence": confidence,
        "metadata": metadata or {},
    }


def trim_empty_tail(cells: list[str]) -> list[str]:
    end = len(cells)
    while end > 0 and not cells[end - 1].strip():
        end -= 1
    return cells[:end]


def looks_like_header(row: list[str], following: list[list[str]]) -> bool:
    if len([cell for cell in row if cell.strip()]) < 2:
        return False
    if not following:
        return True
    numeric_below = 0
    checked = 0
    for next_row in following:
        for cell in next_row:
            if not cell:
                continue
            checked += 1
            if re.fullmatch(r"[-+]?\d+(?:\.\d+)?", cell.replace(",", "")):
                numeric_below += 1
    return checked == 0 or numeric_below >= max(1, checked // 4)


def dedupe_headers(row: list[str]) -> list[str]:
    seen: dict[str, int] = {}
    headers: list[str] = []
    for index, cell in enumerate(row):
        base = cell.strip() or f"열{index + 1}"
        seen[base] = seen.get(base, 0) + 1
        headers.append(base if seen[base] == 1 else f"{base}_{seen[base]}")
    return headers


def kind_for_path(path: str) -> str:
    ext = Path(path.lower()).suffix
    if ext == ".pdf":
        return "pdf"
    if ext in IMAGE_EXTS:
        return "image"
    if ext in SHEET_EXTS:
        return "spreadsheet"
    if ext in OFFICE_EXTS:
        return "document"
    if ext == ".zip":
        return "archive"
    return "file"


def normalize_text(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+\n", "\n", str(text or ""))).strip()


if __name__ == "__main__":
    raise SystemExit(main())
