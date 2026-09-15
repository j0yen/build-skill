#!/usr/bin/env bash
# proveguard_ac1_down_keeps_live_prove.sh — PRD-build-burst-prove-inflight-
# guard AC1.
#
# Given an active session with a live prove.inflight marker (a real running
# pid), When `down` runs, Then it returns decision=keep, journals
# cause=prove-inflight naming the live pid, and the box is never deleted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  proveguard AC1: down exits 0 while a live prove.inflight pid is running" \
  "ok  proveguard AC1: down prints decision=keep" \
  "ok  proveguard AC1: down journals decision=keep cause=prove-inflight naming the live pid" \
  "ok  proveguard AC1: the box is still alive (down never reached its own delete decision)"
