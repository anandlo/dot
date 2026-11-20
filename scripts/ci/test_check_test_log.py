#!/usr/bin/env python3
"""Tests for the serial XCTest log checker."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_test_log as checker  # noqa: E402

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
ALLOWLIST = HERE / "skip-allowlist.txt"
SCRIPT = HERE / "check_test_log.py"


def run_fixture(name: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(FIXTURES / name)],
        capture_output=True,
        text=True,
        check=False,
    )


class SummaryGrammarTests(unittest.TestCase):
    def test_singular_and_plural_executed_lines(self) -> None:
        self.assertEqual(
            checker.summary("Executed 1 test, with 1 test skipped and 1 failure (0 unexpected) in 1 s"),
            (1, 1, 1),
        )
        self.assertEqual(
            checker.summary("Executed 894 tests, with 45 tests skipped and 0 failures (0 unexpected) in 1 s"),
            (894, 45, 0),
        )
        self.assertEqual(
            checker.summary("Executed 1300 tests, with 0 failures (0 unexpected) in 1 s"),
            (1300, 0, 0),
        )


class FixtureTests(unittest.TestCase):
    def test_green_log_passes(self) -> None:
        result = run_fixture("green_plural.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| DotTests | 894 | 1 | 0 | 894 |", result.stdout)
        self.assertIn("| DotCoreTests | 1300 | 1 | 0 | 1300 |", result.stdout)

    def test_missing_finished_bundle_fails(self) -> None:
        result = run_fixture("missing_bundle.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DotCoreTests started but never printed a passed or failed line", result.stderr)

    def test_failed_test_fails(self) -> None:
        result = run_fixture("failure.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DotTests.GlassSurfaceTests testTheGlassIsCapturedWhenAsked failed", result.stderr)

    def test_singular_failure_grammar_fails(self) -> None:
        result = run_fixture("singular_failure.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DotTests reported 1 failure(s)", result.stderr)

    def test_unknown_skip_fails(self) -> None:
        result = run_fixture("unknown_skip.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown skipped test DotTests.UnlistedTests/testASurpriseSkip", result.stderr)

    def test_below_floor_fails(self) -> None:
        result = run_fixture("below_floor.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DotTests executed 893 tests, below the floor of 894", result.stderr)

    def test_allowlisted_test_that_ran_is_a_notice(self) -> None:
        result = run_fixture("allowlisted_ran.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "allowlisted test DotTests.GlassSurfaceTests/testTheGlassIsCapturedWhenAsked did not skip",
            result.stderr,
        )

    def test_combined_bundle_attributes_targets(self) -> None:
        path = Path("/private/tmp/dot-main-ci.log")
        if not path.exists():
            self.skipTest("the CI log used for this check is not present")
        errors, notices, rows = checker.check_log(
            path, ALLOWLIST, ["DotTests", "DotCoreTests"]
        )
        self.assertEqual(errors, [], errors)
        self.assertEqual(rows[0][1], 894)
        self.assertEqual(rows[1][1], 1300)


if __name__ == "__main__":
    unittest.main()
