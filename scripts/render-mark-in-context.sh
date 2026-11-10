#!/usr/bin/env bash
#
# Composite the chosen mark against the real icons on this Mac, at real size.
#
# The study sheets answer "which direction is the argument". This answers the
# next question: "does the winner sit next to real icons". It draws the mark in
# the Dock it would live in, at 128 and 64 points, dark and light, beside the
# icons IconServices resolves for this machine, then beside Apple's own 1024
# masters, then at 16 px.
#
# The composite draws one of the four studied plates. The mark that ships is a
# dial on Porcelain's plate, so a bare run shows Porcelain's plate with its own
# dot; the dials are compared in docs/dot-mark-differentiation-sheet.png.
#
# Nothing is installed. The icon set is rendered into a scratch directory and
# thrown away; only the composite is kept.
#
# Usage:
#   scripts/render-mark-in-context.sh                    # Direction from DotMark.chosen
#   scripts/render-mark-in-context.sh --direction ember  # a studied direction
#   scripts/render-mark-in-context.sh --out /tmp/dot     # write somewhere else
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PROJECT_DIR/docs"
DIRECTION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            OUT="$2"
            shift 2
            ;;
        --direction)
            DIRECTION="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'render-mark-in-context: unknown argument %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

log() { printf '%s\n' "$*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dot-in-context.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

cd -- "$PROJECT_DIR"
swiftc -O -parse-as-library \
    scripts/render-in-context.swift \
    Sources/Dot/DotMark.swift \
    Sources/Dot/DotMarkDial.swift \
    -o "$TMP/render-in-context"

# The 1024 master has to come from the same renderer the icns is built from, so
# this stays a real comparison and not a second drawing of the mark.
ICON_ARGS=(--out "$TMP/icons")
if [ -n "$DIRECTION" ]; then
    ICON_ARGS+=(--direction "$DIRECTION")
fi
"$PROJECT_DIR/scripts/render-icon.sh" "${ICON_ARGS[@]}" >/dev/null

CONTEXT_ARGS=(--out "$OUT" --masters "$TMP/icons")
if [ -n "$DIRECTION" ]; then
    CONTEXT_ARGS+=(--direction "$DIRECTION")
fi
"$TMP/render-in-context" "${CONTEXT_ARGS[@]}"
