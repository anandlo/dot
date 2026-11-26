#!/usr/bin/env python3
"""Verify the built Dot.app against the repository's bundle requirements."""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENTITLEMENTS = ROOT / "scripts/Dot.entitlements"
VERSION = ROOT / "VERSION"
FONT_SCRIPT = ROOT / "scripts/fetch-fonts.sh"


def fail(message: str) -> int:
    print(f"::error::{message}", file=sys.stderr)
    return 1


def run(command: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, capture_output=True, check=False)


def require_nonempty(path: Path) -> str | None:
    if not path.is_file():
        return f"{path} is missing"
    if path.stat().st_size == 0:
        return f"{path} is empty"
    return None


def verify(app: Path, require_modern_icon: bool = False) -> int:
    if not app.exists():
        return fail(f"{app} does not exist")

    result = run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if result.returncode != 0:
        print(result.stderr.decode(errors="replace"), file=sys.stderr)
        return fail(f"{app} failed the strict signature check")

    result = run(["codesign", "-d", "--entitlements", ":-", str(app)])
    if result.returncode != 0:
        print(result.stderr.decode(errors="replace"), file=sys.stderr)
        return fail(f"the entitlements of {app} could not be read")
    expected = plistlib.loads(ENTITLEMENTS.read_bytes())
    actual = plistlib.loads(result.stdout)
    if actual != expected:
        return fail(f"the entitlements of {app} do not match scripts/Dot.entitlements")

    expected_version = "".join(VERSION.read_text(encoding="utf-8").split())
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    actual_version = info.get("CFBundleShortVersionString")
    if actual_version != expected_version:
        return fail(
            f"bundle version {actual_version} does not match VERSION {expected_version}"
        )

    font = app / "Contents/Resources/Fonts/Satoshi-Variable.ttf"
    if not font.is_file():
        return fail(f"{font} is missing")
    script = FONT_SCRIPT.read_text(encoding="utf-8")
    match = re.search(r'^EXPECTED_SHA256="([0-9a-f]{64})"', script, re.MULTILINE)
    if match is None:
        return fail("the font pin could not be read from scripts/fetch-fonts.sh")
    actual_sha = hashlib.sha256(font.read_bytes()).hexdigest()
    if actual_sha != match.group(1):
        return fail(f"the embedded font sha256 {actual_sha} does not match the pin")

    resources = app / "Contents/Resources"
    for name in ("AppIcon.icns", "MenuGlyph.png", "MenuGlyph@2x.png"):
        problem = require_nonempty(resources / name)
        if problem is not None:
            return fail(problem)

    if require_modern_icon:
        problem = require_nonempty(resources / "Assets.car")
        if problem is not None:
            return fail(problem)
        if info.get("CFBundleIconName") != "AppIcon":
            return fail(
                f"CFBundleIconName is {info.get('CFBundleIconName')}, expected AppIcon"
            )

    print(f"verified {app}")
    print(f"version {actual_version}")
    print("entitlements match scripts/Dot.entitlements")
    print("font sha256", actual_sha)
    print("classic icons present")
    if require_modern_icon:
        print("modern icon present")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--require-modern-icon", action="store_true")
    args = parser.parse_args(argv[1:])
    return verify(args.app, args.require_modern_icon)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
