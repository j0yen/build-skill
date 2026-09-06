#!/usr/bin/env bash
# gate_delta_ac4_no_baseline_unchanged.sh — PRD-build-gate-delta-baseline AC4.
#
# Given a repo with no agent/gate-baseline.json (or one not committed to
# HEAD), when the gate runs with block>0, then the verdict is `block`
# exactly as v-current (fail closed): verdict/exit code mirror <gate-rc>
# byte-for-byte, with no baseline-derived fields.
#
# Also covers the "uncommitted baseline never counts" half of AC4: a
# baseline file sitting in the working tree but never `git add`ed/
# committed is treated identically to no baseline at all.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-delta.sh"
FIXTURE="$HERE/fixtures/gate-output/two-blocks.txt"
PASS_FIXTURE="$HERE/fixtures/gate-output/all-pass.txt"

[ -x "$GD" ] || { echo "ac4: $GD not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gd-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# --- no baseline file at all -------------------------------------------
set +e
out="$("$GD" verdict "$REPO" "$FIXTURE" 1)"; rc=$?
set -e
expect "no-file: exit mirrors gate-rc (1)" "[ $rc -eq 1 ]"
expect "no-file: baseline=absent"          "grep -qx 'baseline=absent' <<<\"\$out\""
expect "no-file: verdict=block (not delta-pass)" "grep -qx 'verdict=block' <<<\"\$out\""

set +e
out0="$("$GD" verdict "$REPO" "$PASS_FIXTURE" 0)"; rc0=$?
set -e
expect "no-file, gate-rc=0: exit mirrors gate-rc (0)" "[ $rc0 -eq 0 ]"
expect "no-file, gate-rc=0: verdict=pass"             "grep -qx 'verdict=pass' <<<\"\$out0\""

# --- baseline file present but UNCOMMITTED (working tree only) ---------
"$GD" record "$REPO" "$FIXTURE" >/dev/null
[ -f "$REPO/agent/gate-baseline.json" ] || { echo "ac4: setup failed to write baseline" >&2; exit 2; }
# deliberately never `git add`/commit it
set +e
out2="$("$GD" verdict "$REPO" "$FIXTURE" 1)"; rc2=$?
set -e
expect "uncommitted: still exits 1 (fail closed)" "[ $rc2 -eq 1 ]"
expect "uncommitted: still baseline=absent"        "grep -qx 'baseline=absent' <<<\"\$out2\""
expect "uncommitted: still verdict=block"          "grep -qx 'verdict=block' <<<\"\$out2\""

exit $fail
