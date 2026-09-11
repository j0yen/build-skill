#!/usr/bin/env bash
# burstuser_ac1_up_creates_build_user.sh — PRD-build-burst-unprivileged-user AC1.
#
# Given a fake box with no `build` user, When `up` runs, Then the fake root
# ssh receives the user-creation and key-install commands, session state has
# remote_user=build, and every later fake ssh/rsync call targets build@.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC1: up exits 0" \
  "ok  burstuser AC1: root ssh received the user-creation call" \
  "ok  burstuser AC1: the same root call installs the ssh key (authorized_keys)" \
  "ok  burstuser AC1: session.json records remote_user=build" \
  "ok  burstuser AC1: booted journal line names remote_user=build" \
  "ok  burstuser AC1: at least one later call targeted build@ (sandbox/gate-tools probes)" \
  "ok  burstuser AC1: the literal default remote_root is /home/build/build" \
  "ok  burstuser AC1: the literal default gate_tools_bin is /home/build/.local/bin" \
  "ok  burstuser AC1: the literal default gate_cred_path is /home/build/.claude/.credentials.json"
