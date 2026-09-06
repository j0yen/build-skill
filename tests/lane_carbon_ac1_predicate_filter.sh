#!/usr/bin/env bash
# lane_carbon_ac1_predicate_filter.sh — PRD-build-second-lane-carbon AC1.
#
# Given a queue with one shell and one rust-extend PRD, when both lanes
# tick, then carbon claims only the shell PRD and RedBaron is free to take
# either unclaimed one.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LP="$HERE/../scripts/lane-predicate.sh"
[ -x "$LP" ] || { echo "ac1: $LP not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-carbon-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/build-queue"

cat > "$T/build-queue/PRD-shell-one.md" <<'EOF'
# PRD: shell-one
- Status: queued
- build_target: shell
EOF
cat > "$T/build-queue/PRD-rust-one.md" <<'EOF'
# PRD: rust-one
- Status: queued
- build_target: rust-extend
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out=$("$LP" select "$T/build-queue/PRD-shell-one.md" carbon "$T"); rc=$?
expect "carbon selects the shell PRD (exit 0)" "[ $rc -eq 0 ]"
expect "carbon's ok reasons name build_target=shell" "grep -q 'ok:.*build_target=shell' <<<\"\$out\""

set +e
out=$("$LP" select "$T/build-queue/PRD-rust-one.md" carbon "$T" 2>&1); rc=$?
set -e
expect "carbon skips the rust-extend PRD (exit 1)" "[ $rc -eq 1 ]"
expect "skip reason names cargo-bound"             "grep -q '^skip: cargo-bound' <<<\"\$out\""

out=$("$LP" select "$T/build-queue/PRD-rust-one.md" RedBaron "$T"); rc=$?
expect "RedBaron is free to take the rust-extend PRD" "[ $rc -eq 0 ]"
out=$("$LP" select "$T/build-queue/PRD-shell-one.md" RedBaron "$T"); rc=$?
expect "RedBaron is free to take the shell PRD too"   "[ $rc -eq 0 ]"

exit $fail
