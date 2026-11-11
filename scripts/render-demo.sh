#!/usr/bin/env bash
#
# Render the recording card as a film and encode the hero loop.
#
# The frames come from the app itself, through `--render-demo`: nothing here
# draws a card, and no screen recording is taken, so the film is the same on a
# locked screen as on an unlocked one. The frames are drawn at two pixels per
# point; the loop is encoded at one, so the encoder resamples rather than
# upscales, and the still stays at two for a retina page.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$PROJECT_DIR/assets"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dot-demo.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"
[ -n "$FFMPEG" ] || FFMPEG=/opt/homebrew/bin/ffmpeg
[ -x "$FFMPEG" ] || {
  printf 'error: ffmpeg not found; set FFMPEG to its path\n' >&2
  exit 1
}

cd -- "$PROJECT_DIR"
swift build >/dev/null
BIN="$(swift build --show-bin-path)/Dot"

printf 'rendering the film\n'
"$BIN" --render-demo "$TMP"

FRAMES="$(find "$TMP" -name 'frame-*.png' | wc -l | tr -d ' ')"
[ "$FRAMES" = "360" ] || {
  printf 'error: expected 360 frames, got %s\n' "$FRAMES" >&2
  exit 1
}

# H.264: the universal file. Fast start, so the browser can begin playing
# before the whole file has arrived.
printf 'encoding recording.mp4\n'
"$FFMPEG" -hide_banner -loglevel error -y -framerate 60 -i "$TMP/frame-%04d.png" \
  -vf "scale=1120:560:flags=lanczos" \
  -c:v libx264 -preset veryslow -crf 20 -pix_fmt yuv420p -profile:v high \
  -movflags +faststart -an "$ASSETS/recording.mp4"

# VP9: the smaller file, for the browsers that take it first.
printf 'encoding recording.webm\n'
"$FFMPEG" -hide_banner -loglevel error -y -framerate 60 -i "$TMP/frame-%04d.png" \
  -vf "scale=1120:560:flags=lanczos" \
  -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -cpu-used 2 -deadline good \
  -pix_fmt yuv420p -an "$ASSETS/recording.webm"

# The poster is the last frame: the committed card, at rest, at two pixels per
# point. It is the video's poster and the still the page falls back to.
printf 'writing recording-poster.png\n'
cp "$TMP/frame-0359.png" "$ASSETS/recording-poster.png"

printf '\n'
ls -lh "$ASSETS/recording.mp4" "$ASSETS/recording.webm" "$ASSETS/recording-poster.png"
