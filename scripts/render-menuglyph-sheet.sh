#!/usr/bin/env bash
#
# Render the menu bar glyph comparison into docs/.
#
# The glyph ships as a template, so only its silhouette and its weight survive.
# This sheet draws each candidate at 18 and 36 beside the system's own menu bar
# symbols, on a light bar and a dark one, and follows them with the pixel
# evidence at 8x. Nothing here is installed: the glyph that is installed is the
# one `DotMenuGlyph.Kind.shipped` names.
#
# Usage: scripts/render-menuglyph-sheet.sh
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$PROJECT_DIR/docs"

cd -- "$PROJECT_DIR"
swift build >/dev/null
".build/debug/Dot" --render-menuglyph "$DOCS"

printf 'wrote %s\n' "$DOCS/dot-mark-menuglyph-clipped.png"
