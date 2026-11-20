#!/usr/bin/env python3
"""Tests for the serial XCTest log checker."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_test_log as checker  # noqa: E402

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
ALLOWLIST = HERE / "skip-allowlist.txt"
BUNDLES = ["DotTests", "DotCoreTests"]
SMALL = {"DotTests": 1, "DotCoreTests": 1}


def check_fixture(
    name: str,
    floors: dict[str, int] | None = None,
    bundles: list[str] | None = None,
    allowlist: Path = ALLOWLIST,
) -> tuple[list[str], list[str], list[tuple[str, int, int, int, int]]]:
    return checker.check_log(
        FIXTURES / name,
        allowlist,
        bundles or BUNDLES,
        floors or SMALL,
    )


class SummaryGrammarTests(unittest.TestCase):
    def test_real_summary_tails(self) -> None:
        self.assertEqual(
            checker.summary("Executed 1 test, with 1 test skipped and 1 failure (0 unexpected) in 1.000 (1.000) seconds"),
            checker.Summary(1, 1, 1, 0),
        )
        self.assertEqual(
            checker.summary("Executed 894 tests, with 45 tests skipped and 0 failures (0 unexpected) in 335.230 (335.560) seconds"),
            checker.Summary(894, 45, 0, 0),
        )
        self.assertEqual(
            checker.summary("Executed 1300 tests, with 0 failures (0 unexpected) in 33.463 (33.725) seconds"),
            checker.Summary(1300, 0, 0, 0),
        )

    def test_malformed_and_truncated_counters_are_rejected(self) -> None:
        self.assertIsNone(checker.summary("Executed 894 tests, with 45 tests skipped"))
        self.assertIsNone(checker.summary("Executed 894 tests, with 45 tests skipped and"))
        self.assertIsNone(checker.summary("Executed 894 tests, with 0 skipped and 0 failures"))
        self.assertIsNone(checker.summary("Executed 894 tests,"))
        self.assertIsNone(checker.summary("Executed 1 test, with 0 failures (0 unexpected)"))


class FixtureTests(unittest.TestCase):
    def test_green_split_log_passes(self) -> None:
        errors, notices, rows = check_fixture("green_plural.txt")
        self.assertEqual(errors, [], errors)
        self.assertEqual(notices, [], notices)
        self.assertEqual(
            rows,
            [("DotTests", 1, 1, 0, 1), ("DotCoreTests", 1, 1, 0, 1)],
        )

    def test_combined_real_grammar_fixture_passes(self) -> None:
        errors, notices, rows = check_fixture("combined_real_grammar.txt")
        self.assertEqual(errors, [], errors)
        self.assertEqual(notices, [], notices)
        self.assertEqual(
            rows,
            [("DotTests", 1, 0, 0, 1), ("DotCoreTests", 1, 1, 0, 1)],
        )

    def test_missing_finished_bundle_fails(self) -> None:
        errors, _, _ = check_fixture("missing_bundle.txt")
        self.assertIn("expected one DotCoreTests run, found 0", errors)

    def test_failed_test_fails(self) -> None:
        errors, _, _ = check_fixture("failure.txt")
        self.assertIn("DotTests.GlassSurfaceTests testTheGlassIsCapturedWhenAsked failed", errors)

    def test_singular_failure_grammar_is_parsed_and_reported(self) -> None:
        errors, _, _ = check_fixture("singular_failure.txt")
        self.assertIn("DotTests Executed line counts 1 failures but the run contains 0 failed cases", errors)

    def test_unknown_skip_fails(self) -> None:
        errors, _, _ = check_fixture("unknown_skip.txt")
        self.assertTrue(
            any("unknown skipped test DotTests.UnlistedTests/testASurpriseSkip" in error for error in errors),
            errors,
        )

    def test_below_floor_fails(self) -> None:
        errors, _, _ = check_fixture(
            "below_floor.txt", {"DotTests": 2, "DotCoreTests": 1}
        )
        self.assertIn("DotTests executed 1 tests, below the floor of 2", errors)

    def test_allowlisted_test_that_ran_is_a_notice(self) -> None:
        errors, notices, _ = check_fixture("allowlisted_ran.txt")
        self.assertEqual(errors, [], errors)
        self.assertIn(
            "allowlisted test DotTests.GlassSurfaceTests/testTheGlassIsCapturedWhenAsked did not skip",
            notices,
        )


class RunIntegrityTests(unittest.TestCase):
    def test_dropped_skip_line_in_split_log_fails(self) -> None:
        errors, _, _ = check_fixture("dropped_skip_explicit.txt")
        self.assertIn(
            "DotTests Executed line counts 1 skipped tests but the run contains 0 skip lines",
            errors,
        )

    def test_dropped_skip_line_in_combined_log_fails(self) -> None:
        errors, _, _ = check_fixture("dropped_skip_combined.txt")
        self.assertIn(
            "dotPackageTests Executed line counts 1 skipped tests but the run contains 0 skip lines",
            errors,
        )

    def test_failed_combined_header_with_zero_summary_failures_fails(self) -> None:
        errors, _, _ = check_fixture("combined_failed_header.txt")
        self.assertIn("dotPackageTests bundle ended as failed", errors)

    def test_malformed_split_counter_fails(self) -> None:
        errors, _, _ = check_fixture("malformed_counter_explicit.txt")
        self.assertTrue(any("malformed Executed line" in error for error in errors), errors)

    def test_truncated_combined_counter_fails(self) -> None:
        errors, _, _ = check_fixture("truncated_counter_combined.txt")
        self.assertTrue(any("malformed Executed line" in error for error in errors), errors)

    def test_delayed_counter_is_not_accepted(self) -> None:
        errors, _, _ = check_fixture("delayed_counter.txt")
        self.assertIn("DotTests finished without an Executed line", errors)

    def test_missing_case_terminal_fails(self) -> None:
        errors, _, _ = check_fixture("missing_terminal.txt")
        self.assertIn(
            "DotTests.AboutTests/testOne has 0 terminal lines in DotTests run", errors
        )

    def test_duplicate_run_fails(self) -> None:
        errors, _, _ = check_fixture("duplicate_run.txt")
        self.assertIn("expected one DotTests run, found 2", errors)

    def test_truncated_summary_tail_fails(self) -> None:
        errors, _, _ = check_fixture("truncated_tail.txt")
        self.assertTrue(any("malformed Executed line" in error for error in errors), errors)

    def test_wrong_module_in_selected_run_fails(self) -> None:
        errors, _, _ = check_fixture("wrong_module.txt")
        self.assertIn(
            "DotTests run contains unexpected module DotCoreTests: DotCoreTests.ConfigTests testDefaults",
            errors,
        )

    def test_unexpected_failures_are_rejected(self) -> None:
        errors, _, _ = check_fixture("unexpected_failure.txt")
        self.assertIn("DotTests reported 1 unexpected failure(s)", errors)

    def test_valid_filtered_combined_dotcore_log_passes(self) -> None:
        errors, notices, rows = check_fixture(
            "filtered_combined_dotcore.txt", bundles=["DotCoreTests"]
        )
        self.assertEqual(errors, [], errors)
        self.assertEqual(notices, [], notices)
        self.assertEqual(rows, [("DotCoreTests", 1, 1, 0, 1)])

    def test_skip_allowlist_keys_must_be_qualified(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "allowlist.txt"
            path.write_text("AboutTests/testOne\n", encoding="utf-8")
            errors, _, _ = check_fixture("green_plural.txt", allowlist=path)
        self.assertTrue(any("invalid skip allowlist" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
