#!/usr/bin/env python3
"""Check a serial SwiftPM XCTest log for complete bundle runs and allowed skips."""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

FLOORS = {"DotTests": 894, "DotCoreTests": 1098}
# A deliberate test deletion lowers the affected floor in the same PR.

SUMMARY_RE = re.compile(
    r"Executed\s+(?P<executed>\d+)\s+tests?"
    r"(?:,\s*with\s+(?P<skipped>\d+)\s+tests?\s+skipped)?"
    r"(?:,\s*with\s+(?P<with_failures>\d+)\s+failures?"
    r"|\s+and\s+(?P<and_failures>\d+)\s+failures?)"
    r"\s+\(\s*(?P<unexpected>\d+)\s+unexpected\s*\)"
    r"\s+in\s+[\d.]+\s+\([\d.]+\s*\)\s+seconds?\s*$"
)
BUNDLE_START_RE = re.compile(r"Test Suite '(?P<name>[^']+)\.xctest' started")
BUNDLE_END_RE = re.compile(
    r"Test Suite '(?P<name>[^']+)\.xctest' (?P<status>passed|failed)"
)
CASE_RE = re.compile(r"Test Case '-\[(?P<identifier>[^\]]+)\]'\s+(?P<action>\w+)")


@dataclass(frozen=True)
class Summary:
    executed: int
    skipped: int
    failures: int
    unexpected: int


@dataclass
class CaseRecord:
    starts: int = 0
    terminals: dict[str, int] = field(default_factory=dict)


@dataclass
class RunStats:
    name: str
    cases: dict[tuple[str, str, str], CaseRecord] = field(default_factory=dict)


@dataclass
class ParsedRun:
    name: str
    start: int
    end: int
    status: str
    summary: Summary


def parse_identifier(identifier: str) -> tuple[str, str, str] | None:
    bundle, separator, rest = identifier.partition(".")
    class_name, gap, test_name = rest.partition(" ")
    if not separator or not gap or not class_name or not test_name:
        return None
    return bundle, class_name, test_name.strip()


def summary(line: str) -> Summary | None:
    match = SUMMARY_RE.search(line)
    if match is None:
        return None
    failures = match.group("and_failures") or match.group("with_failures")
    if failures is None:
        return None
    return Summary(
        executed=int(match.group("executed")),
        skipped=int(match.group("skipped") or 0),
        failures=int(failures),
        unexpected=int(match.group("unexpected")),
    )


def next_nonempty_line(lines: list[str], after: int) -> tuple[int | None, str]:
    for index in range(after + 1, len(lines)):
        if lines[index].strip():
            return index, lines[index]
    return None, ""


def load_allowlist(path: Path) -> set[tuple[str, str]]:
    entries: set[tuple[str, str]] = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "/" not in line:
            raise ValueError(f"line {number} is not Bundle.Class/test: {line}")
        qualified_class, test_name = line.split("/", 1)
        if "." not in qualified_class:
            raise ValueError(f"line {number} has no bundle prefix: {line}")
        bundle, class_name = qualified_class.split(".", 1)
        if not all(part.strip() for part in (bundle, class_name, test_name)):
            raise ValueError(f"line {number} has an empty field: {line}")
        entries.add((f"{bundle.strip()}.{class_name.strip()}", test_name.strip()))
    return entries


def find_runs(lines: list[str]) -> tuple[list[ParsedRun], list[str]]:
    runs: list[ParsedRun] = []
    errors: list[str] = []
    for index, line in enumerate(lines):
        start_match = BUNDLE_START_RE.search(line)
        if start_match is None:
            continue
        name = start_match.group("name")
        end_match = None
        end_index = None
        for candidate_index in range(index + 1, len(lines)):
            candidate = BUNDLE_END_RE.search(lines[candidate_index])
            if candidate is not None and candidate.group("name") == name:
                end_match = candidate
                end_index = candidate_index
                break
        if end_match is None or end_index is None:
            errors.append(f"{name} started but never printed a passed or failed line")
            continue
        _, candidate_line = next_nonempty_line(lines, end_index)
        parsed = summary(candidate_line) if candidate_line else None
        if parsed is None:
            if candidate_line and "Executed" in candidate_line:
                errors.append(
                    f"{name} finished with a malformed Executed line: {candidate_line.strip()}"
                )
            else:
                errors.append(f"{name} finished without an Executed line")
            continue
        runs.append(
            ParsedRun(name, index, end_index, end_match.group("status"), parsed)
        )
    return runs, errors


def scan_run(lines: list[str], run: ParsedRun, allowed: set[str]) -> tuple[RunStats, list[str]]:
    stats = RunStats(name=run.name)
    errors: list[str] = []
    for line in lines[run.start + 1 : run.end]:
        case_match = CASE_RE.search(line)
        if case_match is None:
            continue
        identifier = case_match.group("identifier")
        parsed = parse_identifier(identifier)
        if parsed is None:
            errors.append(f"{run.name} run has a malformed test case: {identifier}")
            continue
        if parsed[0] not in allowed:
            errors.append(f"{run.name} run contains unexpected module {parsed[0]}: {identifier}")
            continue
        record = stats.cases.setdefault(parsed, CaseRecord())
        action = case_match.group("action")
        if action == "started":
            record.starts += 1
        elif action in ("passed", "failed", "skipped"):
            record.terminals[action] = record.terminals.get(action, 0) + 1
    for key, record in sorted(stats.cases.items()):
        label = f"{key[0]}.{key[1]}/{key[2]}"
        if record.starts != 1:
            errors.append(f"{label} has {record.starts} started lines in {run.name} run")
        terminals = sum(record.terminals.values())
        if terminals != 1:
            errors.append(f"{label} has {terminals} terminal lines in {run.name} run")
    return stats, errors


def run_counts(stats: RunStats) -> tuple[int, int, int, dict[str, tuple[int, int, int]]]:
    per_bundle: dict[str, list[int]] = {}
    executed = skipped = failures = 0
    for (bundle, _, _), record in stats.cases.items():
        started = 1 if record.starts == 1 else 0
        was_skipped = 1 if record.terminals.get("skipped") == 1 else 0
        was_failed = 1 if record.terminals.get("failed") == 1 else 0
        executed += started
        skipped += was_skipped
        failures += was_failed
        values = per_bundle.setdefault(bundle, [0, 0, 0])
        values[0] += started
        values[1] += was_skipped
        values[2] += was_failed
    return (
        executed,
        skipped,
        failures,
        {name: tuple(values) for name, values in per_bundle.items()},
    )


def check_log(
    log_path: Path,
    allowlist_path: Path,
    bundles: list[str],
    floors: dict[str, int] | None = None,
) -> tuple[list[str], list[str], list[tuple[str, int, int, int, int]]]:
    floors = dict(FLOORS if floors is None else floors)
    rows = [(name, 0, 0, 0, floors.get(name, 0)) for name in bundles]
    try:
        allowlist = load_allowlist(allowlist_path)
    except ValueError as error:
        return [f"invalid skip allowlist: {error}"], [], rows

    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    runs, errors = find_runs(lines)
    combined_runs = [run for run in runs if run.name == "dotPackageTests"]
    split_runs = [run for run in runs if run.name != "dotPackageTests"]

    if combined_runs:
        if len(combined_runs) != 1:
            errors.append(f"expected one combined test run, found {len(combined_runs)}")
        if split_runs:
            errors.append("the log mixes combined and split test runs")
    else:
        for name in bundles:
            count = sum(1 for run in split_runs if run.name == name)
            if count != 1:
                errors.append(f"expected one {name} run, found {count}")

    scanned: list[tuple[ParsedRun, RunStats, tuple[int, int, int, dict[str, tuple[int, int, int]]]]] = []
    for run in runs:
        if run.name == "dotPackageTests":
            allowed = set(bundles)
        elif run.name in bundles:
            allowed = {run.name}
        else:
            allowed = set()
        stats, scan_errors = scan_run(lines, run, allowed)
        errors.extend(scan_errors)
        counts = run_counts(stats)
        executed, skipped, failures, _ = counts
        if run.name not in bundles and run.name != "dotPackageTests" and executed:
            errors.append(f"unexpected test run {run.name} contains {executed} tests")
        if run.status == "failed":
            errors.append(f"{run.name} bundle ended as failed")
        if run.summary.unexpected:
            errors.append(f"{run.name} reported {run.summary.unexpected} unexpected failure(s)")
        if run.summary.executed != executed:
            errors.append(
                f"{run.name} Executed line counts {run.summary.executed} tests "
                f"but the run contains {executed} started cases"
            )
        if run.summary.skipped != skipped:
            errors.append(
                f"{run.name} Executed line counts {run.summary.skipped} skipped tests "
                f"but the run contains {skipped} skip lines"
            )
        if run.summary.failures != failures:
            errors.append(
                f"{run.name} Executed line counts {run.summary.failures} failures "
                f"but the run contains {failures} failed cases"
            )
        scanned.append((run, stats, counts))
        for key, record in stats.cases.items():
            if record.terminals.get("failed"):
                errors.append(f"{key[0]}.{key[1]} {key[2]} failed")

    if combined_runs:
        selected = [entry for entry in scanned if entry[0].name == "dotPackageTests"][:1]
    else:
        selected = [entry for entry in scanned if entry[0].name in bundles]
    per_bundle: dict[str, list[int]] = {name: [0, 0, 0] for name in bundles}
    started: dict[str, set[tuple[str, str, str]]] = {name: set() for name in bundles}
    skipped_cases: dict[str, set[tuple[str, str, str]]] = {name: set() for name in bundles}
    for _, stats, counts in selected:
        for name in bundles:
            values = counts[3].get(name, (0, 0, 0))
            current = per_bundle[name]
            current[0] += values[0]
            current[1] += values[1]
            current[2] += values[2]
        for key, record in stats.cases.items():
            if key[0] not in started:
                continue
            if record.starts:
                started[key[0]].add(key)
            if record.terminals.get("skipped"):
                skipped_cases[key[0]].add(key)

    notices: list[str] = []
    rows = []
    for name in bundles:
        executed, skipped, failures = per_bundle[name]
        if failures:
            errors.append(f"{name} reported {failures} failure(s)")
        floor = floors.get(name, 0)
        if executed < floor:
            errors.append(f"{name} executed {executed} tests, below the floor of {floor}")
        rows.append((name, executed, skipped, failures, floor))
        for bundle, class_name, test_name in sorted(skipped_cases[name]):
            key = (f"{bundle}.{class_name}", test_name)
            if key not in allowlist:
                errors.append(
                    f"unknown skipped test {bundle}.{class_name}/{test_name}; add it "
                    "to scripts/ci/skip-allowlist.txt"
                )
        for bundle, class_name, test_name in sorted(started[name]):
            key = (f"{bundle}.{class_name}", test_name)
            if key in allowlist and (bundle, class_name, test_name) not in skipped_cases[name]:
                notices.append(f"allowlisted test {bundle}.{class_name}/{test_name} did not skip")
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
