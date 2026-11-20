#!/usr/bin/env python3
"""Check a serial SwiftPM XCTest log for complete bundles and allowed skips."""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

FLOORS = {"DotTests": 894, "DotCoreTests": 1300}
# A deliberate test deletion lowers the affected floor in the same PR.

SUMMARY_RE = re.compile(
    r"Executed\s+(?P<executed>\d+)\s+tests?"
    r"(?:,\s*with\s+(?P<skipped>\d+)\s+tests?\s+skipped)?"
    r"(?:\s+and\s+(?P<and_failures>\d+)\s+failures?"
    r"|,\s*with\s+(?P<with_failures>\d+)\s+failures?)?"
)
BUNDLE_START_RE = re.compile(r"Test Suite '(?P<name>[^']+)\.xctest' started")
BUNDLE_END_RE = re.compile(
    r"Test Suite '(?P<name>[^']+)\.xctest' (?P<status>passed|failed)"
)
CASE_RE = re.compile(r"Test Case '-\[(?P<identifier>[^\]]+)\]'\s+(?P<action>\w+)")
SKIP_WORD_RE = re.compile(r": Test skipped - ")


@dataclass
class BundleResult:
    name: str
    executed: int = 0
    skipped: int = 0
    failures: int = 0
    finished: bool = False
    errors: list[str] = field(default_factory=list)


def parse_identifier(identifier: str) -> tuple[str, str, str] | None:
    bundle, separator, rest = identifier.partition(".")
    class_name, gap, test_name = rest.partition(" ")
    if not separator or not gap or not class_name or not test_name:
        return None
    return bundle, class_name, test_name.strip()


def summary(line: str) -> tuple[int, int, int] | None:
    match = SUMMARY_RE.search(line)
    if match is None:
        return None
    failures = match.group("and_failures") or match.group("with_failures") or "0"
    return int(match.group("executed")), int(match.group("skipped") or 0), int(failures)


def load_allowlist(path: Path) -> set[tuple[str, str]]:
    entries: set[tuple[str, str]] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "/" in line:
            class_name, test_name = line.split("/", 1)
        else:
            class_name, _, test_name = line.rpartition(".")
        entries.add((class_name.strip(), test_name.strip()))
    return entries


def read_cases(lines: list[str], bundles: list[str]) -> tuple[dict, dict, dict, list[str]]:
    started: dict[str, set[tuple[str, str, str]]] = {name: set() for name in bundles}
    skipped: dict[str, set[tuple[str, str, str]]] = {name: set() for name in bundles}
    failed: dict[str, set[tuple[str, str, str]]] = {name: set() for name in bundles}
    failure_lines: list[str] = []
    for line in lines:
        match = CASE_RE.search(line)
        if match is None:
            continue
        parsed = parse_identifier(match.group("identifier"))
        if parsed is None or parsed[0] not in started:
            continue
        action = match.group("action")
        if action == "started":
            started[parsed[0]].add(parsed)
        elif action == "skipped":
            skipped[parsed[0]].add(parsed)
        elif action == "failed":
            failed[parsed[0]].add(parsed)
            failure_lines.append(line.strip())
    return started, skipped, failed, failure_lines


def find_summary(lines: list[str], after: int) -> tuple[int, int, int] | None:
    for line in lines[after : after + 4]:
        parsed = summary(line)
        if parsed is not None:
            return parsed
    return None


def parse_combined(lines: list[str], bundles: list[str]) -> tuple[int, int, int] | None:
    for index, line in enumerate(lines):
        if "Test Suite 'dotPackageTests.xctest' started" not in line:
            continue
        for end_index in range(index + 1, len(lines)):
            if "Test Suite 'dotPackageTests.xctest' " not in lines[end_index]:
                continue
            if " passed" not in lines[end_index] and " failed" not in lines[end_index]:
                continue
            result = find_summary(lines, end_index)
            if result is not None:
                return result
    return None


def check_log(
    log_path: Path,
    allowlist_path: Path,
    bundles: list[str],
    floors: dict[str, int] | None = None,
) -> tuple[list[str], list[str], list[tuple[str, int, int, int, int]]]:
    floors = dict(FLOORS if floors is None else floors)
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    allowlist = load_allowlist(allowlist_path)
    started, skipped, failed, failure_lines = read_cases(lines, bundles)
    combined = parse_combined(lines, bundles)
    errors: list[str] = []
    notices: list[str] = []
    rows: list[tuple[str, int, int, int, int]] = []

    for name in bundles:
        result = BundleResult(name=name)
        starts = [
            index
            for index, line in enumerate(lines)
            if f"Test Suite '{name}.xctest' started" in line
        ]
        ends = [
            (index, match)
            for index, line in enumerate(lines)
            for match in [BUNDLE_END_RE.search(line)]
            if match is not None and match.group("name") == name
        ]
        if starts:
            start = starts[-1]
            later_ends = [(index, match) for index, match in ends if index > start]
            if not later_ends:
                errors.append(f"{name} started but never printed a passed or failed line")
            else:
                end_index, end_match = later_ends[0]
                result.finished = True
                if end_match.group("status") == "failed":
                    errors.append(f"{name} bundle ended as failed")
                parsed = find_summary(lines, end_index)
                if parsed is None:
                    errors.append(f"{name} finished without an Executed line")
                else:
                    result.executed, summary_skips, summary_failures = parsed
                    result.failures += summary_failures
                    if summary_skips != len(skipped[name]):
                        notices.append(
                            f"{name}: Executed line counts {summary_skips} skipped tests "
                            f"but {len(skipped[name])} skip lines were found"
                        )
        elif combined is None:
            errors.append(f"{name} did not start and no combined test bundle was found")
        else:
            result.executed = len(started[name])
            if result.executed == 0:
                errors.append(f"{name} has no test case lines in the combined bundle")
            result.failures += combined[2]

        result.skipped = len(skipped[name])
        if failed[name]:
            for identifier in sorted(failed[name]):
                errors.append(
                    f"{identifier[0]}.{identifier[1]} {identifier[2]} failed"
                )
            result.failures = max(result.failures, len(failed[name]))
        if result.failures:
            errors.append(f"{name} reported {result.failures} failure(s)")
        floor = floors.get(name, 0)
        if result.executed < floor:
            errors.append(
                f"{name} executed {result.executed} tests, below the floor of {floor}"
            )
        rows.append((name, result.executed, result.skipped, result.failures, floor))

    if combined is not None:
        aggregate = sum(row[1] for row in rows)
        if combined[0] != aggregate:
            errors.append(
                f"combined bundle executed {combined[0]} tests but the required bundles "
                f"account for {aggregate}"
            )
        if combined[2]:
            errors.append(f"combined bundle reported {combined[2]} failure(s)")

    for name in bundles:
        for bundle, class_name, test_name in sorted(skipped[name]):
            key = (f"{bundle}.{class_name}", test_name)
            if key not in allowlist and (class_name, test_name) not in allowlist:
                errors.append(
                    f"unknown skipped test {bundle}.{class_name}/{test_name}; add it "
                    "to scripts/ci/skip-allowlist.txt"
                )
        for bundle, class_name, test_name in sorted(started[name]):
            if (f"{bundle}.{class_name}", test_name) not in allowlist:
                continue
            if (bundle, class_name, test_name) not in skipped[name]:
                notices.append(
                    f"allowlisted test {bundle}.{class_name}/{test_name} did not skip"
                )

    if failure_lines and not any(" failed" in error for error in errors):
        errors.append("a test case failed: " + failure_lines[0])
    return errors, notices, rows


def render(rows: list[tuple[str, int, int, int, int]], notices: list[str]) -> str:
    parts = [
        "| Bundle | Executed | Skipped | Failures | Floor |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    parts.extend(
        f"| {name} | {executed} | {skipped} | {failures} | {floor} |"
        for name, executed, skipped, failures, floor in rows
    )
    if notices:
        parts.append("")
        parts.extend(notices)
    return "\n".join(parts) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--allowlist", type=Path, default=None)
    parser.add_argument("--bundles", nargs="+", default=None)
    args = parser.parse_args(argv)
    allowlist = args.allowlist or Path(__file__).with_name("skip-allowlist.txt")
    bundles = args.bundles or list(FLOORS)

    errors, notices, rows = check_log(args.log, allowlist, bundles)
    report = render(rows, notices)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(report)
    else:
        sys.stdout.write(report)
    for notice in notices:
        print(f"::notice::{notice}", file=sys.stderr)
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
