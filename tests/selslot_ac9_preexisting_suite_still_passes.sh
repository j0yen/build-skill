#!/usr/bin/env bash
# selslot_ac9_preexisting_suite_still_passes.sh —
# PRD-build-select-guard-depends-before-slot AC9: given the pre-existing
# select-guard-selftest.sh fixtures (AC1 foreign-lane-claim block, AC2
# stale-claim reclaim), when the full selftest suite runs after this PRD's
# changes land, then both continue to pass unmodified -- proving the new
# pre-slot Depends-on check does not alter the existing busy/cargo-free/
# stale-claim checks' behavior or ordering relative to each other.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELFTEST="$HERE/../scripts/select-guard-selftest.sh"

# -u the per-tick orchestration knobs a live /build coordinator's own shell
# commonly exports (BUILD_DISTINCT_TARGETS=0, etc.) -- select-guard-
# selftest.sh's own same-target fixtures set what they need explicitly, so
# this only removes ambient noise this AC's assertion doesn't care about.
out=$(env -u BUILD_DISTINCT_TARGETS -u BUILD_MAX_BRANCHES -u BUILD_BURST_ENABLED -u BUILD_SAME_TARGET_CAP_BURST "$SELFTEST" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL AC9: select-guard-selftest.sh exited $rc:" >&2; printf '%s\n' "$out" >&2; exit 1; }

printf '%s\n' "$out" | grep -q '^== AC1: a live foreign-lane claim on build_into blocks dispatch, loudly ==$' \
  || { echo "FAIL AC9: AC1 foreign-lane-claim block missing" >&2; exit 1; }
printf '%s\n' "$out" | grep -q '^== AC2: once the same claim goes stale' \
  || { echo "FAIL AC9: AC2 stale-claim reclaim block missing" >&2; exit 1; }
printf '%s\n' "$out" | grep -q '^ALL PASS$' \
  || { echo "FAIL AC9: suite did not report ALL PASS" >&2; exit 1; }

echo "ok  AC9: pre-existing select-guard-selftest.sh fixtures (AC1/AC2) still pass unmodified"
