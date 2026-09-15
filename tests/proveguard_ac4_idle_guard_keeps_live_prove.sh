#!/usr/bin/env bash
# proveguard_ac4_idle_guard_keeps_live_prove.sh — PRD-build-burst-prove-
# inflight-guard AC4.
#
# Given a box otherwise idle-guard-eligible (runs_served=0, past the
# zero-runs age threshold) with a live prove.inflight marker, When
# `idle-guard` runs, Then it does not delete the box and journals
# decision=keep cause=prove-inflight — the same guard down uses.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  proveguard AC4: idle-guard exits 0 while a live prove.inflight pid is running" \
  "ok  proveguard AC4: idle-guard does not delete the box" \
  "ok  proveguard AC4: idle-guard journals decision=keep cause=prove-inflight"
