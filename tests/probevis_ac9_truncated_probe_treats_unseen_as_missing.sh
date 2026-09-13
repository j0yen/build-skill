#!/usr/bin/env bash
# probevis_ac9_truncated_probe_treats_unseen_as_missing.sh —
# PRD-build-burst-probe-visibility AC9.
#
# Given fixture probe output that is truncated before the sentinel, When
# it is parsed, Then probe-truncated (phase=... tools_seen=N expected=8)
# is journaled and every unseen tool is treated as MISSING (never as
# present).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/probevis-ac-common.sh"
run_probevis_suite_and_expect_labels \
  "ok  AC9: probe-truncated journaled for phase=pre naming 3 of 8 seen" \
  "ok  AC9: unseen tool=mold is treated as MISSING (attempted), never present" \
  "ok  AC9: unseen tool=cargo-deny is treated as MISSING (attempted), never present" \
  "ok  AC9: unseen tool=cargo-nextest is treated as MISSING (attempted), never present" \
  "ok  AC9: unseen tool=uv is treated as MISSING (attempted), never present" \
  "ok  AC9: unseen tool=claude is treated as MISSING (attempted), never present"
