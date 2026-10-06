#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/codmes-shape-recognition"
BINARY="$BUILD_DIR/evaluate_shape_recognition"

mkdir -p "$BUILD_DIR"

swiftc \
  "$ROOT/apps/client/apple/Sources/Codmes/PDFShapeExemplarBank.swift" \
  "$ROOT/apps/client/apple/Sources/Codmes/PDFShapeRecognizer.swift" \
  "$ROOT/scripts/evaluate_shape_recognition.swift" \
  -o "$BINARY"

"$BINARY" "$@"
