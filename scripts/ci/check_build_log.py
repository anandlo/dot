#!/usr/bin/env python3
"""Fail on compiler, linker, and asset diagnostics in a build log."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DIAGNOSTIC_PATTERNS = (
    re.compile(r"^/.*\.(?:swift|m|mm|c|cc|cpp|h|metal):\d+:\d+: (?:warning|error):"),
    re.compile(r"^(?:ld|ld64): (?:warning|error):"),
    re.compile(r"^clang(?::[^:]*)?: (?:warning|error):"),
    re.compile(
        r"^/.*\.(?:xcassets|appiconset|iconset|icon|storyboard|xib): (?:warning|error):"
    ),
    re.compile(r"^/\* com\.apple\.actool.*?: (?:warning|error):"),
)
SIGNING_NOTICES = (
    "warning: no code-signing identity named",
    "warning: an ad-hoc signature is identified by this build's own hash",
    "warning: for the microphone and Accessibility again after every rebuild",
    "warning: run ./scripts/signing-identity.sh",
)
MODERN_ICON_DIAGNOSTICS = (
    "warning: actool could not compile",
    "warning: actool not found",
)


def diagnostics(path: Path, require_modern_icon: bool = False) -> list[str]:
    found: list[str] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if require_modern_icon and line.startswith(MODERN_ICON_DIAGNOSTICS):
            found.append(line)
            continue
        if line.startswith(SIGNING_NOTICES):
            continue
        if any(pattern.search(line) for pattern in DIAGNOSTIC_PATTERNS):
            found.append(line)
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--require-modern-icon", action="store_true")
    args = parser.parse_args(argv[1:])
    found = diagnostics(args.log, args.require_modern_icon)
    for line in found:
        print(f"::error::{line}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
