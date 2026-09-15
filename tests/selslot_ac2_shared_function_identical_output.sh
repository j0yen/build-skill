#!/usr/bin/env bash
# selslot_ac2_shared_function_identical_output.sh —
# PRD-build-select-guard-depends-before-slot AC2: given the Depends-on
# check is implemented once in scripts/lib/depends-gate.sh, when
# select-guard.sh and a fixture standing in for the coordinator's Phase 2
# prose both call it against the same PRD and built-prds/ state, then both
# return the identical unmet-dependency list (verified by literal
# comparison of the two outputs).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/selslot-common.sh"
selslot_setup

TARGET=/tmp/selslot-ac2-repo
selslot_write_prd first "$TARGET" PRD-selslot-ac2-dep-unmet.md
selslot_commit

# Coordinator stand-in: sources the SAME library select-guard.sh sources,
# calls the SAME function, against the SAME PRD/built-prds state.
coordinator_unmet=$(bash -c '
  set -uo pipefail
  source "$1"
  depends_gate_unmet "$2" "$3"
' _ "$DG" "$ROOT/clone/build-queue/PRD-first.md" "$ROOT/clone/built-prds") || true
coordinator_csv=$(printf '%s' "$coordinator_unmet" | tr '\n' ',' | sed 's/,$//')

guard_out=$(selslot_guard first 0 "" 2>&1) || true
guard_csv="${guard_out#*gated: depends-on: }"

[ -n "$coordinator_csv" ] || { echo "FAIL AC2: coordinator stand-in reported no unmet dependency" >&2; exit 1; }
[ "$guard_csv" = "$coordinator_csv" ] \
  || { echo "FAIL AC2: select-guard.sh ($guard_csv) and coordinator stand-in ($coordinator_csv) disagree" >&2; exit 1; }

echo "ok  AC2: select-guard.sh and the coordinator stand-in resolve depends-gate.sh identically ($guard_csv)"
