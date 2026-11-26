#!/usr/bin/env bash
#
# Fluidity gate: run every frame pacing and smoothness suite and refuse to
# continue unless all of them pass. install.sh runs it before it builds, so a
# build that drops frames in the HUD, a visualizer, a Settings demo or a page
# scroll is never installed.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES="AnimationFluidityTests|HUDFramePacingAcceptanceTests|HUDFrameStatisticsTests|FrameDropMonitorTests|PageScrollEdgeTests|VisualizerSwatchDriverTests|HistoryTranscriptListTests"
LOG="$(mktemp -t dot-fluidity-gate)"
trap 'rm -f -- "$LOG"' EXIT

printf 'fluidity gate: %s\n' "$SUITES"
cd -- "$PROJECT_DIR"
# The suites draw into off-screen windows and read the display link, which the
# test sandbox does not allow.
if ! swift test --disable-sandbox --filter "$SUITES" >"$LOG" 2>&1; then
  grep -E "FLUIDITY" "$LOG" >&2 || true
  grep -E "error:" "$LOG" >&2 || tail -40 "$LOG" >&2
  printf 'error: the fluidity gate failed; nothing was installed\n' >&2
  exit 1
fi
# Every listed suite must have run, passed and skipped nothing: the gate runs
# on a Mac with a display, so a skipped display-link test is a check that did
# not happen.
TOTAL=0
for SUITE in ${SUITES//|/ }; do
  SUMMARY="$(grep -A1 -E "^Test Suite '$SUITE' passed" "$LOG" | grep -Eo 'Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?0 failures' | head -1 || true)"
  if [ -z "$SUMMARY" ]; then
    printf 'error: the fluidity gate did not run %s\n' "$SUITE" >&2
    exit 1
  fi
  RAN="$(printf '%s' "$SUMMARY" | awk '{ print $2 }')"
  SKIPPED="$(printf '%s' "$SUMMARY" | grep -Eo '[0-9]+ tests? skipped' | awk '{ print $1 }' || true)"
  if [ "$RAN" -lt 1 ] || [ "${SKIPPED:-0}" -gt 0 ]; then
    printf 'error: %s ran %s tests and skipped %s\n' "$SUITE" "$RAN" "${SKIPPED:-0}" >&2
    exit 1
  fi
  TOTAL=$((TOTAL + RAN))
done
if [ "$TOTAL" -lt 20 ]; then
  printf 'error: the fluidity gate ran only %s tests\n' "$TOTAL" >&2
  exit 1
fi
printf 'fluidity gate passed (%s tests)\n' "$TOTAL"
