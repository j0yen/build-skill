#!/usr/bin/env bash
# burstuser_ac5_credential_under_build_home_shredded.sh — PRD-build-burst-
# unprivileged-user AC5.
#
# Given BURST_GATE_REVIEWER=1, When `up` then `down` run, Then the
# credential exists at the resolved $REMOTE_HOME/.claude/.credentials.json
# (build's own home, not root's) between them, is shredded after, and no
# token bytes appear in journal or receipts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC5: the credential landed at the resolved cred path" \
  "ok  burstuser AC5: the credential mkdir+chmod over ssh targeted build@" \
  "ok  burstuser AC5: the credential rsync push targeted build@" \
  "ok  burstuser AC5: journal names the placement (no token bytes)" \
  "ok  burstuser AC5: the credential file is gone after down" \
  "ok  burstuser AC5: journal records the shred, still no token bytes"
