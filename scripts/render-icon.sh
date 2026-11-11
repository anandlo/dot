#!/usr/bin/env bash
#
# Render the app icon and the menu bar glyph, then build Resources/AppIcon.icns.
#
# The drawings are code (Sources/Dot/DotMark.swift and DotMarkDial.swift), and
# `Dot --render-icon` is the only way an icon file is ever made: there is no
# hand-edited PNG in the tree.
#
# Usage:
#   scripts/render-icon.sh                     # install into Resources/
#   scripts/render-icon.sh --out /tmp/icon     # write somewhere else
#   scripts/render-icon.sh --direction ember   # pick a studied plate
#
# The mark is the one `DotMark.chosenDial` names, drawn on `DotMark.chosen`'s
# plate, so a bare run writes the shipped icon. An explicit `--direction` draws
# one of the four studied plates instead, which is how a review is reproduced.
#
# Every master is written without an alpha channel: a PNG that carries alpha is
# a transparency declaration whatever its values are, and macOS masks an app
# icon to the system corner itself.
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PROJECT_DIR/Resources"
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
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'render-icon: unknown argument %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

log() { printf '%s\n' "$*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dot-icon.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

cd -- "$PROJECT_DIR"
BIN="$(swift build --show-bin-path)/Dot"

ARGS=(--render-icon "$TMP/masters")
if [ -n "$DIRECTION" ]; then
    ARGS+=(--direction "$DIRECTION")
fi
"$BIN" "${ARGS[@]}"

MASTERS="$TMP/masters"
ICONSET="$MASTERS/AppIcon.iconset"

# The ten slots an icns needs. A missing one is not a warning: iconutil would
# silently produce an icon that is blurry at the size that is missing.
SLOTS=(
    icon_16x16.png icon_16x16@2x.png
    icon_32x32.png icon_32x32@2x.png
    icon_128x128.png icon_128x128@2x.png
    icon_256x256.png icon_256x256@2x.png
    icon_512x512.png icon_512x512@2x.png
)
for slot in "${SLOTS[@]}"; do
    if [ ! -s "$ICONSET/$slot" ]; then
        printf 'render-icon: the iconset is missing %s\n' "$slot" >&2
        exit 1
    fi
done

# The masters must be opaque. `sips` is the check that survives someone
# "fixing" the renderer later with a transparency-preserving encode.
for png in "$MASTERS"/AppIcon-*.png "$ICONSET"/*.png; do
    alpha="$(sips -g hasAlpha "$png" 2>/dev/null | awk '/hasAlpha/ {print $2}')"
    if [ "$alpha" != "no" ]; then
        printf 'render-icon: %s carries an alpha channel (%s)\n' "$png" "${alpha:-unknown}" >&2
        exit 1
    fi
done

log "building $OUT/AppIcon.icns"
mkdir -p -- "$OUT"
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

# Only the 1024 master is installed besides the icns: the icon is resolved from
# the icns, and the flat copies of the smaller sizes were files nothing read.
cp -- "$MASTERS/AppIcon-1024.png" "$OUT/AppIcon-1024.png"
cp -- "$MASTERS/MenuGlyph.png" "$OUT/MenuGlyph.png"
cp -- "$MASTERS/MenuGlyph@2x.png" "$OUT/MenuGlyph@2x.png"

# Read the icns back so the report is about the file that exists, not the
# iconset that was handed to iconutil.
chunks="$(iconutil -c iconset "$OUT/AppIcon.icns" -o "$TMP/check.iconset" 2>/dev/null && ls "$TMP/check.iconset" | wc -l | tr -d ' ')"
log "wrote $OUT/AppIcon.icns ($(( $(stat -f%z "$OUT/AppIcon.icns") / 1024 )) KB, ${chunks:-?} sizes)"
log "wrote $OUT/AppIcon-1024.png (opaque, no alpha channel)"
log "wrote $OUT/MenuGlyph.png (18) and $OUT/MenuGlyph@2x.png (36), black on transparent"
