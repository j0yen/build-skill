#!/usr/bin/env bash
# multibox_ac3_run_selects_free_slot_box.sh — PRD-build-burst-state-keyed-
# by-server-v2 AC3.
#
# Given two ready fixture boxes with cap 4 each, When 12 fixture runs start
# together, Then peak concurrency is 8 across boxes (4 per box, from
# `run routed ... server_id=... concurrent=`), all 12 complete, and each
# attribution row names its own box. This AC is a real-time concurrency
# proof (12 backgrounded invocations, a peak-overlap measurement) — the
# same shape as burstpar-selftest.sh's own single-box AC1/AC3 concurrency
# oracle, not the one-shot `expect` assertions burst-lane-selftest.sh uses
# for the other multibox ACs — so this wrapper drives burstpar-selftest.sh
# via run_burstpar_and_expect_labels, per that helper's own convention (no
# separate, hand-duplicated per-AC test body here either).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_burstpar_and_expect_labels \
  "ok  multibox AC3: all 12 runs exit 0 across two boxes" \
  "ok  multibox AC3: all 12 runs actually started (starts=12)" \
  "ok  multibox AC3: peak concurrency is 8 across both boxes" \
  "ok  multibox AC3: box 201 (127.0.0.11) reached its own cap of 4" \
  "ok  multibox AC3: box 202 (127.0.0.12) reached its own cap of 4" \
  "ok  multibox AC3: 12 attribution rows total, split across both boxes' own ledgers" \
  "ok  multibox AC3: every attribution row's session_id names its own box (201/202, never crossed)"
