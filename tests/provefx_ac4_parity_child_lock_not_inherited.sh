#!/usr/bin/env bash
# provefx_ac4_parity_child_lock_not_inherited.sh —
# PRD-build-burst-prove-forensics AC4.
#
# Given up scheduling a fixture parity child that sleeps 30s, When a second
# up starts within 5s, Then it takes the lock and journals `up booted`
# (fixture) rather than up-refused.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC4: a fresh flock succeeds immediately once the caller's own fd closes (background child did not inherit 221)"
