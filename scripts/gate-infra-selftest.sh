#!/usr/bin/env bash
# gate-infra-selftest.sh — the one entrypoint for PRD-build-gate-infra-
# outcome's fixture coverage (test_prefix: gateinfra, R9).
#
# Runs every tests/gateinfra_ac*.sh:
#   AC1-AC3  — real extend-gate.sh through tests/fixtures/rvrcpt-fake/
#              (the same fake toolchain reviewer-receipt-selftest.sh
#              uses): a claude -p invocation failure, a real reviewer
#              block, and a real block mixed with reviewer infra on one
#              run.
#   AC4-AC5  — gate-then-land.sh's own retry/escalation logic against a
#              fixture stub extend-gate.sh (same modeling convention
#              gate-then-land-selftest.sh already uses).
#   AC6      — gate-red-summary.sh's `incomplete=`/`incomplete_infra:`
#              fields against a fixture journal, plus gates-banner.sh's
#              pass-through.
#   AC7      — the dead relabel sed is gone from extend-gate.sh.
#   AC12     — the 2026-09-17 amendment: a finalize-rejected verdict keeps
#              its rejected_verdict/infra_detail, still reports `infra`.
#
# AC8 (producer binary-missing / crash rc>=2 for phases OTHER than
# reviewer-agent) and AC10/AC11 (P1: verdict-tree cache / chain-stop
# reason) are this PRD's own deferred_acs — see the PRD frontmatter for
# the justification; this run does not claim them.
#
# Usage: gate-infra-selftest.sh
#
# Exit: 0 all green | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail_n=0
shopt -s nullglob
for f in "$SKILL_DIR"/tests/gateinfra_ac*.sh; do
  echo "== gate-infra-selftest: $(basename "$f") ==" >&2
  bash "$f"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "gate-infra-selftest: FAILED $(basename "$f") (rc=$rc)" >&2
    fail_n=$((fail_n + 1))
  fi
done
shopt -u nullglob

# R3 (the forbidden shape): each gateinfra_ac*.sh test above already
# asserts its OWN fixture journal never carries `blocking=none` on a
# `block` line (see gateinfra_ac1to3's AC3 assertion in particular, the
# one scenario constructed to have a real block this PRD's own R1/R6 scope
# never instrumented) — R3's safety net is exercised there, not re-swept
# here (each test's own $TMPDIR fixture is cleaned up by its own trap
# before this entrypoint would ever see it).

if [ "$fail_n" -eq 0 ]; then
  echo "gate-infra-selftest: PASS (0 FAIL)"
  exit 0
else
  echo "gate-infra-selftest: FAIL ($fail_n FAIL)" >&2
  exit 1
fi
