#!/usr/bin/env bash
#
# Render the mark study into docs/.
#
# Nothing here is installed: a sheet is evidence for a decision, not an asset.
# The four directions are drawn from Sources/Dot/DotMark.swift, at scale 1, so
# a 16 point sheet tile is sixteen pixels and not a downscale.
#
# Usage: scripts/render-mark-study.sh
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$PROJECT_DIR/docs"

cd -- "$PROJECT_DIR"
swift build >/dev/null
".build/debug/Dot" --render-study "$DOCS"

printf 'wrote %s\n' \
    "$DOCS/dot-mark-contact-sheet.png" \
    "$DOCS/dot-mark-ink.png" \
    "$DOCS/dot-mark-lacquer.png" \
    "$DOCS/dot-mark-porcelain.png" \
    "$DOCS/dot-mark-ember.png" \
    "$DOCS/dot-mark-menuglyph.png"
