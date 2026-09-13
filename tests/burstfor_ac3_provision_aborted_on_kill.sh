#!/usr/bin/env bash
# burstfor_ac3_provision_aborted_on_kill.sh — PRD-build-burst-provision-forensics AC3.
#
# Given a fixture installer that blocks, when the provision process is
# killed mid-gh, then the journal's last provision line is
# provision-aborted (during=gh ...).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstfor-ac-common.sh"
run_burstfor_suite_and_expect_labels \
  "ok  AC3: provision exited nonzero (killed mid-gh)" \
  "ok  AC3: the last gate-tools/provision journal line is provision-aborted during gh" \
  "ok  AC3: no terminal install/install-failed line was ever written for gh"
