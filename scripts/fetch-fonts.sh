#!/usr/bin/env bash
#
# Download the Satoshi typeface the app is set in.
#
# Satoshi is published by the Indian Type Foundry on Fontshare under the ITF
# Free Font License (FFL), version 2.0. The licence grants free personal and
# commercial use and allows the face to be embedded in a desktop application,
# which is how the app ships it: scripts/build.sh copies the file into
# Dot.app/Contents/Resources/Fonts and declares that directory as
# ATSApplicationFontsPath. What the licence forbids is the reason the file is
# fetched rather than committed: distributing the font software, which section
# 02 spells out as including a repository and a publicly accessible server, and
# modifying it, which the same section and section 05 define as including
# subsetting, format conversion and any change to its metadata. The file is
# therefore not in the repository, and this script is how a working copy gets it.
#
# The variable upright file is the one used, not the static ones. It carries the
# whole weight axis (300 to 900) in one file, so the app can write the weight it
# drew the interface with instead of being limited to the five instances the
# foundry shipped, and the static files register as separate families rather than
# as one family with weights. Its default instance is Black, so every resolution
# sets the axis explicitly; see Sources/Dot/DotType.swift.
#
# The file is found through the Fontshare API rather than by a hard-coded CDN
# path: the path is an opaque content hash, and a hard-coded one rots silently
# the day the foundry republishes the family. The list endpoint answers the
# family's UUID, the detail endpoint answers each style's file, and the variable
# style is the one flagged `is_variable` without `is_italic`.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FONT_DIR="$PROJECT_DIR/Resources/Fonts"
FILE_NAME="Satoshi-Variable.ttf"
# The exact file this build was designed against. A different hash means the
# foundry republished the family, so the app's metrics need looking at again
# rather than the new file being taken on trust.
EXPECTED_SHA256="02ad131926aa46d282b6af73ad2bcaecb0ec6ef3b830a2f08dcabef44f1140ff"
LIST_URL="https://api.fontshare.com/v2/fonts?limit=300"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p -- "$FONT_DIR"
TARGET="$FONT_DIR/$FILE_NAME"

# A second run over an intact file is a no-op: the pin is the check, so there is
# nothing for the network to answer.
if [ -f "$TARGET" ]; then
  PRESENT_SHA256="$(shasum -a 256 "$TARGET" | cut -d' ' -f1)"
  if [ "$PRESENT_SHA256" = "$EXPECTED_SHA256" ]; then
    log "$TARGET is already the pinned file ($PRESENT_SHA256); nothing to do"
    exit 0
  fi
  log "replacing $TARGET: sha256 is $PRESENT_SHA256, not the pinned $EXPECTED_SHA256"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is needed to read the Fontshare API"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-fonts.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

log "looking Satoshi up on Fontshare"
curl --fail --silent --show-error --location --max-time 90 --output "$WORK/fonts.json" "$LIST_URL" \
  || die "the font list could not be fetched"

FONT_ID="$(python3 - "$WORK/fonts.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    listing = json.load(handle)
fonts = listing.get("fonts", listing)
for font in fonts:
    if font.get("slug") == "satoshi":
        print(font["id"])
        break
PY
)"
[ -n "$FONT_ID" ] || die "the Fontshare catalogue does not list a family with the slug satoshi"

curl --fail --silent --show-error --location --max-time 90 \
  --output "$WORK/font.json" "https://api.fontshare.com/v2/fonts/$FONT_ID" \
  || die "the font detail could not be fetched for $FONT_ID"

FONT_URL="$(python3 - "$WORK/font.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    payload = json.load(handle)
font = payload.get("font", payload)
for style in font.get("styles", []):
    if style.get("is_variable") and not style.get("is_italic"):
        path = style["file"]
        if path.startswith("//"):
            path = "https:" + path
        print(path if path.endswith(".ttf") else path + ".ttf")
        break
PY
)"
[ -n "$FONT_URL" ] || die "Satoshi has no variable upright style in the Fontshare API"

log "by downloading the file you accept the ITF Free Font License: https://www.fontshare.com/licenses/itf-free-font-license"
log "downloading Satoshi from $FONT_URL"
curl --fail --silent --show-error --location --max-time 120 --output "$TARGET.download" "$FONT_URL" \
  || die "the download failed"

ACTUAL_SHA256="$(shasum -a 256 "$TARGET.download" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  rm -f -- "$TARGET.download"
  die "checksum mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
fi

mv -- "$TARGET.download" "$TARGET"
log "wrote $TARGET ($(stat -f%z "$TARGET") bytes, sha256 verified)"
