#!/usr/bin/env bash
# bursttdl_ac5_parity_never_tears_down.sh —
# PRD-build-burst-teardown-lifecycle AC5.
#
# Given a fake `up` run, When it completes, Then the backgrounded parity
# call reports its diff and no deletion is initiated from the parity path
# (fixture call-log shows no delete).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC5 setup: the backgrounded parity call actually ran to a terminal outcome" \
  "ok  bursttdl AC5: parity reports its diff (ok/diff/fallback), never a deletion, from the up-scheduled path" \
  "ok  bursttdl AC5: no decision=deleted line was ever journaled for this session" \
  "ok  bursttdl AC5: the box is still alive after its own scheduled parity check completed" \
  "ok  bursttdl AC5 (negative-case guard): cmd_parity's own source contains no teardown_and_delete/cmd_down call at all"
