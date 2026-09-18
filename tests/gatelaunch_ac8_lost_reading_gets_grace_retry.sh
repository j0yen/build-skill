#!/usr/bin/env bash
# gatelaunch_ac8_lost_reading_gets_grace_retry.sh —
# PRD-build-burst-gate-canary-invariant AC1.
#
# Given gate-status.sh reports `lost` on gate-launch.sh --wait's first
# poll (the cache-hit-fast-finish race observed 2026-09-18T04:36:03Z/04Z:
# a real box gate finished and wrote its receipts, but the single
# un-retried poll still read "lost"), when a grace re-check shortly after
# would see the gate as finished, then --wait recovers instead of exiting
# 1 on the first sighting -- and, the paired negative case, a gate that is
# genuinely still lost on the re-check still exits 1 and still journals
# wait-lost.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  one lost + a recovering re-check: --wait exits 0, not 1" \
  "ok  one lost + recovery is never journaled as wait-lost" \
  "ok  genuinely lost twice: --wait still exits 1" \
  "ok  genuinely lost twice: still journaled wait-lost"
