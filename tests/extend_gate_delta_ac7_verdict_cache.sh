#!/usr/bin/env bash
# extend_gate_delta_ac7_verdict_cache.sh — PRD-build-gate-delta-baseline AC7
# (P1). Given a completed gate run at head H, when the gate is invoked
# again at H with an unchanged script, then it prints `verdict (cached)`,
# exits with the same code, and does NOT regenerate receipts (proved via
# a call counter the fake `autobuilder gate` subcommand increments only
# when it actually runs); when --force is given, the full gate runs.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EG="$HERE/../scripts/extend-gate.sh"
FAKE="$HERE/fixtures/extend-gate-fake"

[ -x "$EG" ] || { echo "ac7: $EG not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/eg-ac7.XXXXXX")"
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
export FAKE_GATE_PASS_NAMES="audit,vti-plan,rollback-plan,proof-receipt"
unset FAKE_GATE_BLOCKING_FILE || true

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# --- first run at head H: no blocks, verdict=pass, primes the cache ----
: > "$FAKE_GATE_CALL_COUNTER"
set +e
out1="$("$EG" "$REPO" 2>&1)"; rc1=$?
set -e
expect "first run: exit 0"                 "[ $rc1 -eq 0 ]"
expect "first run: gate actually ran once" "[ \"\$(wc -c < '$T/gate-calls')\" -eq 1 ]"
expect "first run: no (cached) marker"     "! grep -q '(cached)' <<<\"\$out1\""

# --- second run, same head, same script -> cache hit --------------------
: > "$FAKE_GATE_CALL_COUNTER"
set +e
out2="$("$EG" "$REPO" 2>&1)"; rc2=$?
set -e
expect "cache hit: same exit code as first run" "[ $rc2 -eq $rc1 ]"
expect "cache hit: prints (cached)"             "grep -q '(cached)' <<<\"\$out2\""
expect "cache hit: gate did NOT run again"      "[ \"\$(wc -c < '$T/gate-calls')\" -eq 0 ]"

# --- --force bypasses the cache, runs the full gate again ---------------
: > "$FAKE_GATE_CALL_COUNTER"
set +e
out3="$("$EG" "$REPO" --force 2>&1)"; rc3=$?
set -e
expect "--force: exit 0"                 "[ $rc3 -eq 0 ]"
expect "--force: no (cached) marker"     "! grep -q '(cached)' <<<\"\$out3\""
expect "--force: gate ran again"         "[ \"\$(wc -c < '$T/gate-calls')\" -eq 1 ]"

# --- a NEW commit (new head) invalidates the cache automatically -------
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "advance head"
: > "$FAKE_GATE_CALL_COUNTER"
set +e
out4="$("$EG" "$REPO" 2>&1)"; rc4=$?
set -e
expect "new head: cache miss, gate ran again" "[ \"\$(wc -c < '$T/gate-calls')\" -eq 1 ]"
expect "new head: no (cached) marker"         "! grep -q '(cached)' <<<\"\$out4\""

exit $fail
