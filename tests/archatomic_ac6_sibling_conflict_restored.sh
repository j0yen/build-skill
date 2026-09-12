#!/usr/bin/env bash
# archatomic_ac6_sibling_conflict_restored.sh —
# PRD-build-archive-atomic-commit AC6: given a sibling edit that
# conflicts with the incoming commit, when lane-claim.sh pulls, then the
# rebase is aborted, the edit is restored, and the claim returns the busy
# code with reason checkout-conflict. A third required real failure-mode
# selftest case (this repo requires at least one; this PRD's own suite
# carries three, this being the trickiest: `git pull --rebase
# --autostash` can exit 0 while only its own final autostash-pop
# conflicts, which archive-commit-selftest.sh's fixture reproduces and
# the lane-claim.sh fix above handles explicitly).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: claim returns the busy exit code (2)" \
  "ok  AC6: reason is checkout-conflict" \
  "ok  AC6: no rebase left in progress" \
  "ok  AC6: no unmerged paths remain" \
  "ok  AC6: sibling's edit is restored exactly, uncommitted" \
  "ok  AC6: the claim never got written"
