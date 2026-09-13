#!/usr/bin/env bash
# pullback_ac11_iteration_log.sh — PRD-build-burst-pull-back-restore AC11.
#
# Given the suite at the commit that ships this PRD, When it runs, Then
# the iteration log records the count of transfer-layer failures found
# after the guard came under suite control and the cause of each.
#
# GAP: there is no durable iteration log this wrapper (or anything else)
# can check. The evidence that exists — commit d888e51's message ("Full
# offline suite ... 0 FAIL, all 14 previously-red cases from the PRD now
# pass") — lives in git history, written by hand at commit time, not
# emitted by the suite or gate on every run the way a journal/ledger file
# is. No ~/brain/journal/build/*.md or state/ file records a per-run count
# of pull-back transfer-layer failures and their causes. This is a real,
# unimplemented gap (the PRD asks for a recorded, re-derivable count on
# every run, not a one-time commit message), not a tmpfs or environment
# artifact.
set -uo pipefail
echo "FAIL pullback AC11: GAP — no iteration log records a per-run count + cause of pull-back transfer-layer failures. The only existing evidence is commit d888e51's own commit message (git history, one-time, hand-written), not a file the suite/gate emits each run. Until such a log exists (e.g. a line in ~/brain/journal/build/ or a state/ ledger keyed by this PRD, written by the suite or gate on every run), AC11 has no case to pair with." >&2
exit 1
