#!/usr/bin/env bash
# extend_gate_delta_ac6_record_ship_paths.sh — PRD-build-gate-delta-baseline
# AC6, integration level: drives the REAL extend-gate.sh end to end (not
# just gate-delta.sh in isolation) through the record / delta-pass /
# new-block / no-baseline paths, against a scratch git repo and a fake
# `autobuilder` that emits the exact line shapes autobuilder/src/gate.rs
# prints (see tests/fixtures/extend-gate-fake/autobuilder), driven by env
# vars rather than a hand-asserted echo of the verdict under test.
#
# `autobuilder`, `extended-receipts.sh`, and `ship-tag.sh` are faked
# (fixtures/extend-gate-fake/); `HOME` is pointed at an empty scratch dir
# for the child process so the script's own
# `PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"` prepend can never
# shadow the fakes with a real system-installed autobuilder. `gh` is left
# off PATH entirely so the ci-checks producer no-ops via its own
# not-on-PATH branch, and reviewer-agent's fake always fails at `prepare`
# so the flow never reaches a real `claude -p` subagent spawn.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EG="$HERE/../scripts/extend-gate.sh"
FAKE="$HERE/fixtures/extend-gate-fake"

[ -x "$EG" ] || { echo "ac6: $EG not executable" >&2; exit 2; }
[ -x "$FAKE/autobuilder" ] || { echo "ac6: $FAKE/autobuilder missing" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/eg-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
mkdir -p "$REPO" "$T/fakehome"
git -C "$REPO" init -q
printf '[package]\nname = "dummy"\nversion = "0.1.0"\nedition = "2021"\n' > "$REPO/Cargo.toml"
mkdir -p "$REPO/src"; echo 'fn main() {}' > "$REPO/src/main.rs"
echo 'target/' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init

export HOME="$T/fakehome"
export PATH="$FAKE:/usr/bin:/bin"
export RUSTBUILD_SCRIPTS="$FAKE"
export EXTEND_GATE_JOURNAL="$T/journal.md"
export FAKE_GATE_CALL_COUNTER="$T/gate-calls"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

TWO_BLOCK_FILE="$T/two-blocks.tsv"
printf 'reviewer-agent\tprepare exited non-zero\nci-checks\tgh not authenticated\n' > "$TWO_BLOCK_FILE"
export FAKE_GATE_BLOCKING_FILE="$TWO_BLOCK_FILE"

# --- A: no baseline yet -> block, exit 1, no delta summary line --------
: > "$FAKE_GATE_CALL_COUNTER"
set +e
outA="$("$EG" "$REPO" 2>&1)"; rcA=$?
set -e
expect "A (no baseline): exit 1"                    "[ $rcA -eq 1 ]"
expect "A (no baseline): no 'extend-gate: delta' line" "! grep -q '^extend-gate: delta' <<<\"\$outA\""
expect "A (no baseline): journal line carries no inherited_blocks suffix" \
  "! grep -q 'inherited_blocks=\\[' \"$T/journal.md\""

# --- B: --record-baseline writes + prints, then caller commits it ------
set +e
outB="$("$EG" "$REPO" --record-baseline 2>&1)"; rcB=$?
set -e
expect "B (record): exit 0"                     "[ $rcB -eq 0 ]"
expect "B (record): agent/gate-baseline.json written" "[ -f '$REPO/agent/gate-baseline.json' ]"
expect "B (record): printed the recorded set"   "grep -q 'reviewer-agent' <<<\"\$outB\""
git -C "$REPO" add agent/gate-baseline.json
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "record baseline"

# --- C: same blocking set, now baselined -> delta-pass, exit 0 ---------
: > "$FAKE_GATE_CALL_COUNTER"
set +e
outC="$("$EG" "$REPO" 2>&1)"; rcC=$?
set -e
expect "C (delta-pass): exit 0"                     "[ $rcC -eq 0 ]"
expect "C (delta-pass): delta verdict=delta-pass"   "grep -q '^extend-gate: delta verdict=delta-pass' <<<\"\$outC\""
expect "C (delta-pass): names both inherited receipts" \
  "grep -q 'inherited_blocks=reviewer-agent,ci-checks' <<<\"\$outC\""
expect "C (delta-pass): journal line carries inherited_blocks" \
  "grep -q 'inherited_blocks=\[reviewer-agent,ci-checks\]' \"$T/journal.md\""

# --- D: a genuinely NEW blocking receipt -> block, names it ------------
THREE_BLOCK_FILE="$T/three-blocks.tsv"
printf 'reviewer-agent\tprepare exited non-zero\nci-checks\tgh not authenticated\nsupply-audit\tnew unpinned dependency\n' > "$THREE_BLOCK_FILE"
export FAKE_GATE_BLOCKING_FILE="$THREE_BLOCK_FILE"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "advance head for scenario D"
: > "$FAKE_GATE_CALL_COUNTER"
set +e
outD="$("$EG" "$REPO" 2>&1)"; rcD=$?
set -e
expect "D (new block): exit 1"                  "[ $rcD -eq 1 ]"
expect "D (new block): delta verdict=block"     "grep -q '^extend-gate: delta verdict=block' <<<\"\$outD\""
expect "D (new block): names supply-audit as the new block" \
  "grep -q 'new_blocks=supply-audit' <<<\"\$outD\""

exit $fail
