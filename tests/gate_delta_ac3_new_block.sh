#!/usr/bin/env bash
# gate_delta_ac3_new_block.sh — PRD-build-gate-delta-baseline AC3.
#
# Given the same baseline and a gate run whose blocking set contains a
# receipt Z not in the baseline, when the summary is computed, then
# verdict=block and Z is named as the new block.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-delta.sh"
BASE_FIXTURE="$HERE/fixtures/gate-output/two-blocks.txt"
NEW_FIXTURE="$HERE/fixtures/gate-output/three-blocks-new-receipt.txt"

[ -x "$GD" ] || { echo "ac3: $GD not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gd-ac3.XXXXXX")"
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

"$GD" record "$REPO" "$BASE_FIXTURE" >/dev/null
git -C "$REPO" add agent/gate-baseline.json
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "record baseline"

# three-blocks-new-receipt.txt keeps the SAME two baselined receipts
# blocking (reviewer-agent, ci-checks) and additionally blocks
# supply-audit (Z), which the baseline never named.
set +e
out="$("$GD" verdict "$REPO" "$NEW_FIXTURE" 1)"; rc=$?
set -e

expect "exit 1 (not shippable)" "[ $rc -eq 1 ]"
expect "verdict=block"          "grep -qx 'verdict=block' <<<\"\$out\""
expect "Z (supply-audit) named as new_blocks" "grep -qx 'new_blocks=supply-audit' <<<\"\$out\""
expect "the two baselined receipts still reported inherited" \
  "grep -qx 'inherited_blocks=reviewer-agent,ci-checks' <<<\"\$out\""

exit $fail
