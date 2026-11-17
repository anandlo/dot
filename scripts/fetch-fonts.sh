#!/usr/bin/env bash
#
# Download the Switzer typeface the app is set in.
#
# Switzer is published by the Indian Type Foundry on Fontshare under the ITF
# Free Font License: free for personal and commercial use, including embedding
# in a desktop application, but the font files may not be redistributed. They
# are therefore not in the repository, and this script is how a working copy
# gets them. Run it once; scripts/build.sh embeds whatever is in Resources/Fonts.
#
# The variable file is the one used, not the static ones. It carries the whole
# weight axis in one file, so the app can ask for the weight it drew the
# interface with instead of being limited to the instances the foundry shipped,
# and the static files register as separate families rather than as one family
# with weights.
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
FILE_NAME="Switzer-Variable.ttf"
# The exact file this build was designed against. A different hash means the
# foundry republished the family, so the app's metrics need looking at again
# rather than the new file being taken on trust.
EXPECTED_SHA256="373c2d2ad8f1f811ca58ae725e9591db2e72cf726dc6e8066cd7f64b4c283cdf"
LIST_URL="https://api.fontshare.com/v2/fonts?limit=300"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is needed to read the Fontshare API"

mkdir -p -- "$FONT_DIR"
TARGET="$FONT_DIR/$FILE_NAME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-fonts.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

log "looking Switzer up on Fontshare"
curl --fail --silent --show-error --location --max-time 90 --output "$WORK/fonts.json" "$LIST_URL" \
  || die "the font list could not be fetched"

FONT_ID="$(python3 - "$WORK/fonts.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    listing = json.load(handle)
fonts = listing.get("fonts", listing)
for font in fonts:
    if font.get("slug") == "switzer":
        print(font["id"])
        break
PY
)"
[ -n "$FONT_ID" ] || die "the Fontshare catalogue does not list a family with the slug switzer"

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
[ -n "$FONT_URL" ] || die "Switzer has no variable upright style in the Fontshare API"

log "by downloading the file you accept the ITF Free Font License: https://www.fontshare.com/licenses/itf-free-font-license"
log "downloading Switzer from $FONT_URL"
curl --fail --silent --show-error --location --max-time 120 --output "$TARGET.download" "$FONT_URL" \
  || die "the download failed"

ACTUAL_SHA256="$(shasum -a 256 "$TARGET.download" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  rm -f -- "$TARGET.download"
  die "checksum mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
fi

mv -- "$TARGET.download" "$TARGET"
log "wrote $TARGET ($(stat -f%z "$TARGET") bytes, sha256 verified)"
