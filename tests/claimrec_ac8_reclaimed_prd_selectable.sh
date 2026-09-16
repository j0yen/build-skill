#!/usr/bin/env bash
# claimrec_ac8_reclaimed_prd_selectable.sh — PRD-build-stale-claim-auto-
# recovery AC8.
#
# Given a reclaimed fixture PRD, When the selector runs on the next tick,
# Then the PRD is admitted as queued. The selector (build-contract.md,
# this PRD's own Problem statement) admits a PRD purely on its `Status:`
# field reading `queued` — this proves the reclaim leaves exactly that
# admissible state, in both the PRD file the selector reads and the
# manifest cache scan-prds.sh/select-tick.sh reconcile against.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
MANIFEST_SET="$HERE/../scripts/manifest-set.sh"
[ -x "$LC" ] || { echo "ac8: lane-claim.sh not executable" >&2; exit 2; }

# PRD-build-journal-single-writer requirement 3: structural isolation
# before lane-claim.sh (sourced below) or manifest-set.sh (invoked via
# lane-claim.sh's own reclaim, at the bottom of this file) run — this
# file already scoped lane-claim.sh's own JOURNAL_DIR per-call below, but
# never covered manifest-set.sh's separate JOURNAL default at all.
# shellcheck source=../scripts/lib/isolation.sh
source "$HERE/../scripts/lib/isolation.sh"
selftest_init || { echo "ac8: selftest_init failed" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claimrec-ac8.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue" "$T/state"
cat > "$T/clone/build-queue/PRD-claimrec-ac8.md" <<'EOF'
# PRD: claimrec-ac8

- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BR="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BR"
PRD="$T/clone/build-queue/PRD-claimrec-ac8.md"

source "$LC"
DEAD_PID=999978
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done
ts=$(now_iso)
write_claim "$PRD" building "$(hostname) $ts pid=$DEAD_PID boot=$(current_boot_id)"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: claimrec-ac8 (fixture, dead pid)"
git -C "$T/clone" push -q origin "$BR"

echo '{"prds": {"claimrec-ac8": {"status": "building"}}}' > "$T/state/manifest.json"

JOURNAL_DIR="$T" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" MANIFEST_SET_SH="$MANIFEST_SET" \
  "$LC" reclaim "$PRD" >/dev/null

# The selector's own admissibility test (build-contract.md / SKILL.md
# Selection rules): first token of the Status: line.
prd_status="$(head -n 80 "$PRD" | grep -E '^(- *Status:|Status:|\*\*Status:\*\*)' | head -n1 \
  | sed -E 's/^(- *Status:|Status:|\*\*Status:\*\*)[[:space:]]*//' | awk '{print $1}')"
expect "PRD file reads Status: queued for the selector" "[ '$prd_status' = queued ]"

manifest_status="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['claimrec-ac8']['status'])")"
expect "manifest cache agrees: queued" "[ '$manifest_status' = queued ]"

exit $fail
