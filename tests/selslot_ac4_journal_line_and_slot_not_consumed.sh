#!/usr/bin/env bash
# selslot_ac4_journal_line_and_slot_not_consumed.sh —
# PRD-build-select-guard-depends-before-slot AC4: given a candidate is
# gated for a recognized skip-class reason (Depends-on unmet), when
# select-guard.sh returns its blocked: verdict, then a journal line
# matching exactly `select: <slug> gated (<reason>) slot-not-consumed` is
# written, and no build_into value for that candidate is added to the
# admitted-targets state.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/selslot-common.sh"
selslot_setup

TARGET=/tmp/selslot-ac4-repo
selslot_write_prd depwait "$TARGET" PRD-selslot-ac4-dep-unmet.md
selslot_write_prd free "$TARGET"
selslot_commit

selslot_guard depwait 0 "" >/dev/null 2>&1 || true
grep -qxF 'select: depwait gated (depends-on) slot-not-consumed' "$SELECT_GUARD_JOURNAL" \
  || { echo "FAIL AC4: journal missing the exact gated line" >&2; cat "$SELECT_GUARD_JOURNAL" >&2 2>/dev/null; exit 1; }

# "no build_into value for that candidate is added to the admitted-targets
# state": the gated candidate never contributes, so a same-target sibling
# evaluated against the SAME (still-empty) admitted-targets is admitted --
# proving the gate never touched that state.
out=$(selslot_guard free 0 "")
echo "$out" | grep -q '^ok: free:' \
  || { echo "FAIL AC4: expected free admitted (target slot untouched by the gated candidate), got: $out" >&2; exit 1; }

echo "ok  AC4: exact journal line written, gated candidate never consumed the slot"
