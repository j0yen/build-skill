#!/usr/bin/env bash
# bursttdl_ac1_setup_grace_blocks_watchdog_and_idleguard.sh —
# PRD-build-burst-teardown-lifecycle AC1.
#
# Given a fake session in phase=setup inside the grace window, When
# watchdog or idle-guard attempts teardown, Then the box is not deleted and
# each journals teardown-deferred (cause=setup-grace remaining=…). Also
# covers the Migration/compatibility note: a session file with no "phase"
# key at all reads as already-provisioned (no grace).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC1 setup: a fresh session starts phase=setup" \
  "ok  bursttdl AC1: watchdog exits 0 on a deferred (not deleted, not leaked) teardown" \
  "ok  bursttdl AC1: watchdog does not delete a phase=setup box inside its grace window" \
  "ok  bursttdl AC1: watchdog journals teardown-deferred with cause=setup-grace and a remaining= countdown" \
  "ok  bursttdl AC1: idle-guard exits 0 on a deferred teardown" \
  "ok  bursttdl AC1: idle-guard does not delete a phase=setup box inside its grace window" \
  "ok  bursttdl AC1: idle-guard journals teardown-deferred with cause=setup-grace" \
  "ok  bursttdl AC1 migration setup: the session file now has no phase field at all" \
  "ok  bursttdl AC1 migration: a legacy session with no phase field is NOT grace-protected (reads as already-provisioned)"
