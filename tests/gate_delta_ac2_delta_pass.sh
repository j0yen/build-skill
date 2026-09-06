#!/usr/bin/env bash
# gate_delta_ac2_delta_pass.sh — PRD-build-gate-delta-baseline AC2.
#
# Given a committed baseline containing receipts X,Y and a gate run whose
# blocking set is a subset of {X,Y}, when the verdict is computed, then
# it reports verdict=delta-pass and the exit code signals shippable (0).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GD="$HERE/../scripts/gate-delta.sh"
FIXTURE="$HERE/fixtures/gate-output/two-blocks.txt"

[ -x "$GD" ] || { echo "ac2: $GD not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gd-ac2.XXXXXX")"
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

# Record the baseline from the SAME fixture (X=reviewer-agent, Y=ci-checks)
# and commit it — a verdict run only ever reads the COMMITTED copy.
"$GD" record "$REPO" "$FIXTURE" >/dev/null
git -C "$REPO" add agent/gate-baseline.json
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "record baseline"

set +e
out="$("$GD" verdict "$REPO" "$FIXTURE" 1)"; rc=$?
set -e

expect "exit 0 (shippable)"        "[ $rc -eq 0 ]"
expect "baseline=present"          "grep -qx 'baseline=present' <<<\"\$out\""
expect "verdict=delta-pass"        "grep -qx 'verdict=delta-pass' <<<\"\$out\""
expect "no new blocks"             "grep -qx 'new_blocks=' <<<\"\$out\""
expect "both X,Y named as inherited" "grep -qx 'inherited_blocks=reviewer-agent,ci-checks' <<<\"\$out\""

exit $fail
