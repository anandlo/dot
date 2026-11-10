#!/usr/bin/env bash
#
# Render the HUD and build the documentation stills.
#
# Nothing is shown on screen: the card is drawn with SwiftUI's ImageRenderer,
# composited onto a generated desktop, and written to docs/. The generated
# desktop is a mock, not a capture of the user's screen.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$PROJECT_DIR/docs"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dot-hud.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

cd -- "$PROJECT_DIR"
swift build >/dev/null
".build/debug/Dot" --render-hud "$TMP"

python3 - "$TMP" "$DOCS" <<'PY'
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

render_dir, docs_dir = sys.argv[1], sys.argv[2]
os.makedirs(docs_dir, exist_ok=True)

W, H = 2880, 1800
S = 2  # everything below is written at 2x


def rounded(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def line(draw, x, y, width, color, height=10):
    draw.rounded_rectangle((x, y, x + width, y + height), radius=height / 2, fill=color)


def make_desktop():
    base = Image.new("RGB", (W, H), "#111318")
    draw = ImageDraw.Draw(base)

    # A calm graphite background with a soft light from the top left.
    for y in range(H):
        t = y / H
        r = int(30 - 14 * t)
        g = int(33 - 16 * t)
        b = int(39 - 18 * t)
        draw.line((0, y, W, y), fill=(r, g, b))
    glow = Image.new("L", (W, H), 0)
    gdraw = ImageDraw.Draw(glow)
    gdraw.ellipse((-700, -900, 1600, 900), fill=42)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    base = Image.composite(Image.new("RGB", (W, H), "#3A4050"), base, glow)
    draw = ImageDraw.Draw(base)

    # A light document on the left.
    doc = (180, 300, 1320, 1600)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    rounded(sdraw, (doc[0] + 10, doc[1] + 28, doc[2] + 10, doc[3] + 28), 28, (0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    base = Image.alpha_composite(base.convert("RGBA"), shadow).convert("RGB")
    draw = ImageDraw.Draw(base)
    rounded(draw, doc, 28, "#F4F3EF")
    line(draw, 260, 380, 360, "#23252B", 22)
    line(draw, 260, 430, 220, "#9A9A96", 10)
    for index in range(11):
        y = 520 + index * 72
        width = 820 if index % 3 else 620
        line(draw, 260, y, width, "#C9C8C2", 9)
    rounded(draw, (260, 1380, 520, 1460), 14, "#1C1E23")

    # A dark terminal on the right.
    term = (1400, 220, 2700, 1580)
    shadow2 = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    s2 = ImageDraw.Draw(shadow2)
    rounded(s2, (term[0] - 8, term[1] + 34, term[2] - 8, term[3] + 34), 30, (0, 0, 0, 140))
    shadow2 = shadow2.filter(ImageFilter.GaussianBlur(40))
    base = Image.alpha_composite(base.convert("RGBA"), shadow2).convert("RGB")
    draw = ImageDraw.Draw(base)
    rounded(draw, term, 26, "#0B0C0F", outline="#23262D", width=2)
    rounded(draw, (term[0], term[1], term[2], term[1] + 54), 26, "#16181D")
    for index, color in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
        cx = term[0] + 32 + index * 28
        draw.ellipse((cx - 8, term[1] + 19, cx + 8, term[1] + 35), fill=color)
    for index in range(14):
        y = 320 + index * 66
        width = 900 if index % 4 else 540
        line(draw, 1460, y, width, "#2B3038" if index % 3 else "#39424E", 8)
    line(draw, 1460, 320, 240, "#4FE3A1", 8)

    # A menu bar across the top.
    bar = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(bar)
    bdraw.rectangle((0, 0, W, 72), fill=(10, 11, 14, 220))
    for index, width in enumerate([64, 48, 56, 80, 40]):
        x = W - 220 - sum([64, 48, 56, 80, 40][: index + 1]) - index * 24
        line(bdraw, x, 30, width, (210, 212, 218, 170), 8)
    base = Image.alpha_composite(base.convert("RGBA"), bar).convert("RGB")
    return base


desktop = make_desktop()

for name in ["recording", "transcribing", "transcript", "message"]:
    card = Image.open(os.path.join(render_dir, f"render-{name}.png")).convert("RGBA")
    canvas = desktop.copy().convert("RGBA")
    x = (W - card.width) // 2
    y = 120 - 56  # card top 120px (60pt) below the top, in the padded image
    canvas.alpha_composite(card, (x, y))
    canvas.convert("RGB").resize((1440, 900), Image.LANCZOS).save(
        os.path.join(docs_dir, f"hud-{name}.png")
    )

# The corner, magnified on white and on grey. This is the evidence that the
# rounded rectangle is the only surface.
recording = Image.open(os.path.join(render_dir, "render-recording.png")).convert("RGBA")
corner = recording.crop((36, 36, 156, 156)).resize((720, 720), Image.NEAREST)
sheet = Image.new("RGB", (1440, 720), "#FFFFFF")
sheet.paste(corner, (0, 0), corner)
grey = Image.new("RGB", (720, 720), "#78787E")
grey.paste(corner, (0, 0), corner)
sheet.paste(grey, (720, 0))
sheet.save(os.path.join(docs_dir, "hud-corners.png"))
PY

echo "wrote $DOCS/hud-recording.png"
echo "wrote $DOCS/hud-transcribing.png"
echo "wrote $DOCS/hud-transcript.png"
echo "wrote $DOCS/hud-message.png"
echo "wrote $DOCS/hud-corners.png"
