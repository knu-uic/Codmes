#!/usr/bin/env python3
"""Replace damaged PDF pages with rendered pages and an embedded OCR text layer."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import fitz


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: normalize_pdf.py INPUT OUTPUT DPI", file=sys.stderr)
        return 2

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    dpi = max(96, min(300, int(sys.argv[3])))
    payload = json.load(sys.stdin)
    blocks = {
        int(block["page"]): block
        for block in payload.get("blocks", [])
        if int(block.get("page") or 0) > 0 and block.get("lines")
    }
    if not blocks:
        raise ValueError("No positioned OCR blocks were supplied.")

    source = fitz.open(input_path)
    source_page_count = source.page_count
    output = fitz.open()
    matrix = fitz.Matrix(dpi / 72.0, dpi / 72.0)
    normalized_pages: list[int] = []
    try:
        for page_index in range(source.page_count):
            page_number = page_index + 1
            block = blocks.get(page_number)
            if not block:
                output.insert_pdf(source, from_page=page_index, to_page=page_index)
                emit_progress(page_index + 1, source_page_count)
                continue

            source_page = source[page_index]
            page_rect = source_page.rect
            target_page = output.new_page(width=page_rect.width, height=page_rect.height)
            pixmap = source_page.get_pixmap(matrix=matrix, alpha=False, colorspace=fitz.csRGB)
            target_page.insert_image(
                target_page.rect,
                stream=pixmap.tobytes("jpeg", jpg_quality=90),
                keep_proportion=False,
                overlay=True,
            )
            for line in block.get("lines", []):
                insert_invisible_line(target_page, line)
            normalized_pages.append(page_number)
            emit_progress(page_index + 1, source_page_count)

        output.set_metadata(source.metadata)
        output.save(output_path, garbage=4, deflate=True)
    finally:
        output.close()
        source.close()

    verified = fitz.open(output_path)
    try:
        if verified.page_count != source_page_count:
            raise ValueError(
                f"Normalized PDF page count changed from {source_page_count} to {verified.page_count}."
            )
        extracted_chars = sum(
            len(verified[page - 1].get_text())
            for page in normalized_pages
            if page <= verified.page_count
        )
        if extracted_chars <= 0:
            raise ValueError("Normalized PDF contains no extractable OCR text.")
        result = {
            "ok": True,
            "pageCount": verified.page_count,
            "normalizedPages": normalized_pages,
            "extractedChars": extracted_chars,
        }
    finally:
        verified.close()
    print(json.dumps(result, ensure_ascii=False))
    return 0


def insert_invisible_line(page: fitz.Page, line: dict) -> None:
    text = str(line.get("text") or "").strip()
    bbox = line.get("bbox") or {}
    if not text:
        return
    page_rect = page.rect
    x0 = clamp(float(bbox.get("x") or 0), 0, 1) * page_rect.width
    y0 = clamp(float(bbox.get("y") or 0), 0, 1) * page_rect.height
    width = max(1.0, clamp(float(bbox.get("width") or 0), 0, 1) * page_rect.width)
    height = max(4.0, clamp(float(bbox.get("height") or 0), 0, 1) * page_rect.height)
    rect = fitz.Rect(x0, y0, min(page_rect.width, x0 + width), min(page_rect.height, y0 + height * 1.35))
    font_size = max(4.0, min(72.0, height * 0.92))
    result = page.insert_textbox(
        rect,
        text,
        fontname="korea",
        fontsize=font_size,
        render_mode=3,
        overlay=True,
    )
    if result < 0:
        page.insert_text(
            fitz.Point(rect.x0, min(page_rect.height, rect.y1)),
            text,
            fontname="korea",
            fontsize=max(4.0, font_size * 0.75),
            render_mode=3,
            overlay=True,
        )


def clamp(value: float, minimum: float, maximum: float) -> float:
    return min(maximum, max(minimum, value))


def emit_progress(completed: int, total: int) -> None:
    print(
        json.dumps({"type": "progress", "completed": completed, "total": total}),
        file=sys.stderr,
        flush=True,
    )


if __name__ == "__main__":
    raise SystemExit(main())
