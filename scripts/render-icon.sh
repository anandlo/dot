#!/usr/bin/env bash
#
# Render the app icon, the Icon Composer document and the menu bar glyph, then
# build Resources/AppIcon.icns and the site's marks.
#
# The drawings are code (Sources/Dot/DotMark.swift, DotMarkDial.swift and
# IconGrid.swift), and `Dot --render-icon` is the only way an icon file is ever
# made: there is no hand-edited PNG in the tree.
#
# Three kinds of file come out of one render, because three consumers want
# different shapes of the same mark:
#
#   * AppIcon.icns, every slot masked into Apple's 824 of 1024 grid with a
#     transparent margin. macOS 14 and 15 draw an app icon exactly as supplied,
#     so this file is what stops Dot appearing in the Dock as a hard square.
#   * AppIcon.icon, the Icon Composer document. Its layers are unmasked and full
#     bleed because macOS 26 supplies the shape, the lighting and the shadow.
#     scripts/build.sh compiles it to Assets.car with actool.
#   * assets/*.png, the site's marks, both masked and full bleed.
#
# Usage:
#   scripts/render-icon.sh                     # install into Resources/ and assets/
#   scripts/render-icon.sh --out /tmp/icon     # write one directory, leave the site alone
#   scripts/render-icon.sh --direction ember   # pick a studied plate
#
# The mark is the one `DotMark.chosenDial` names, drawn on `DotMark.chosen`'s
# plate, so a bare run writes the shipped icon.
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PROJECT_DIR/Resources"
SITE="$PROJECT_DIR/assets"
DIRECTION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            OUT="$2"
            SITE=""
            shift 2
            ;;
        --site)
            SITE="$2"
            shift 2
            ;;
        --no-site)
            SITE=""
            shift
            ;;
        --direction)
            DIRECTION="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Build before rendering. `--show-bin-path` only reports where a binary would
# live, so a render without this line can quietly draw a mark the source no
# longer contains: the last build's, at whatever commit it was made.
log "building the renderer"
swift build >/dev/null
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

# The iconset must carry alpha. An icon master without a transparent margin is
# a square, and a square is the defect this file exists to fix: the check is
# the one that survives someone "simplifying" the renderer into an opaque
# encode later.
for png in "$ICONSET"/*.png; do
    alpha="$(sips -g hasAlpha "$png" 2>/dev/null | awk '/hasAlpha/ {print $2}')"
    if [ "$alpha" != "yes" ]; then
        printf 'render-icon: %s has no alpha channel (%s)\n' "$png" "${alpha:-unknown}" >&2
        exit 1
    fi
done

# The full-bleed marks must not carry one: iOS masks a touch icon itself, and a
# social card is cropped by the card.
for png in "$MASTERS/site/icon.png" "$MASTERS/site/icon-180.png" "$MASTERS/AppIcon-1024.png"; do
    alpha="$(sips -g hasAlpha "$png" 2>/dev/null | awk '/hasAlpha/ {print $2}')"
    if [ "$alpha" != "no" ]; then
        printf 'render-icon: %s carries an alpha channel (%s)\n' "$png" "${alpha:-unknown}" >&2
        exit 1
    fi
done

log "building $OUT/AppIcon.icns"
mkdir -p -- "$OUT"
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

cp -- "$MASTERS/AppIcon-1024.png" "$OUT/AppIcon-1024.png"
cp -- "$MASTERS/MenuGlyph.png" "$OUT/MenuGlyph.png"
cp -- "$MASTERS/MenuGlyph@2x.png" "$OUT/MenuGlyph@2x.png"
# A directory, so it is replaced rather than copied into itself.
rm -r -- "$OUT/AppIcon.icon" 2>/dev/null || true
cp -R -- "$MASTERS/AppIcon.icon" "$OUT/AppIcon.icon"

if [ -n "$SITE" ]; then
    log "installing the site's marks into $SITE"
    mkdir -p -- "$SITE"
    cp -- "$MASTERS/site/icon.png" "$SITE/icon.png"
    cp -- "$MASTERS/site/icon-180.png" "$SITE/icon-180.png"
    cp -- "$MASTERS/site/icon-rounded.png" "$SITE/icon-rounded.png"
    cp -- "$MASTERS/site/icon-512.png" "$SITE/icon-512.png"
    cp -- "$MASTERS/site/icon-32.png" "$SITE/icon-32.png"
fi

# Read the icns back so the report is about the file that exists, not the
# iconset that was handed to iconutil.
chunks="$(iconutil -c iconset "$OUT/AppIcon.icns" -o "$TMP/check.iconset" 2>/dev/null && ls "$TMP/check.iconset" | wc -l | tr -d ' ')"
log "wrote $OUT/AppIcon.icns ($(( $(stat -f%z "$OUT/AppIcon.icns") / 1024 )) KB, ${chunks:-?} sizes, masked)"
log "wrote $OUT/AppIcon.icon ($(ls "$OUT/AppIcon.icon/Assets" | wc -l | tr -d ' ') layers, for actool)"
log "wrote $OUT/AppIcon-1024.png (full bleed, for the in-app tile)"
log "wrote $OUT/MenuGlyph.png (18) and $OUT/MenuGlyph@2x.png (36), black on transparent"
if [ -n "$SITE" ]; then
    log "wrote $SITE/icon-rounded.png, icon-512.png and icon-32.png (masked)"
    log "wrote $SITE/icon.png and icon-180.png (full bleed)"
fi
