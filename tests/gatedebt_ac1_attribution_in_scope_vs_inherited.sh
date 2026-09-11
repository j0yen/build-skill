#!/usr/bin/env bash
# gatedebt_ac1_attribution_in_scope_vs_inherited.sh — PRD-build-gate-debt-
# auto-prd AC1.
#
# Given a fake repo where the building PRD's diff touches src/a.rs and the
# gate blocks on risk-gate findings in src/a.rs and src/b.rs, When the gate
# finishes, Then the summary receipt (gate-attribution.sh's JSON) lists the
# src/a.rs finding as in-scope and the src/b.rs finding as inherited, and
# the journal gate line reads inherited=1 in-scope=1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GA="$HERE/../scripts/gate-attribution.sh"
[ -x "$GA" ] || { echo "ac1: $GA not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac1.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Fake repo: a base commit, then the "PRD's own merge" commit that only
# touches src/a.rs (src/b.rs pre-exists, unrelated, landed by someone else).
git init -q "$ROOT/repo"
mkdir -p "$ROOT/repo/src"
echo "fn a() {}" > "$ROOT/repo/src/a.rs"
echo "fn b() {}" > "$ROOT/repo/src/b.rs"
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q -m base
base_sha="$(git -C "$ROOT/repo" rev-parse HEAD)"

echo "fn a() { /* unsafe block added */ }" > "$ROOT/repo/src/a.rs"
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q -m "the building PRD's own change"
head_sha="$(git -C "$ROOT/repo" rev-parse HEAD)"

# The gate blocked on TWO risk-gate findings this run: one in src/a.rs (the
# PRD's own diff) and one in src/b.rs (pre-existing, inherited).
notes_file="$ROOT/notes.tsv"
printf 'risk-gate\tunsafe block without SAFETY comment path=src/a.rs\n' > "$notes_file"
printf 'risk-gate\tunsafe block without SAFETY comment path=src/b.rs\n' >> "$notes_file"

out="$("$GA" compute "$ROOT/repo" "$base_sha" "$head_sha" "$notes_file" 2>"$ROOT/stderr.txt")"; rc=$?
expect "exits 0" "[ $rc -eq 0 ]"

a_scope="$(python3 -c "import json,sys; b=json.loads(sys.argv[1])['blocks']; print(next(x['scope'] for x in b if x['path']=='src/a.rs'))" "$out")"
b_scope="$(python3 -c "import json,sys; b=json.loads(sys.argv[1])['blocks']; print(next(x['scope'] for x in b if x['path']=='src/b.rs'))" "$out")"
expect "src/a.rs finding tagged in-scope" "[ '$a_scope' = 'in-scope' ]"
expect "src/b.rs finding tagged inherited" "[ '$b_scope' = 'inherited' ]"
expect "receipt lists in_scope=1" "grep -q '\"in_scope\": 1' <<<\"\$out\""
expect "receipt lists inherited=1" "grep -q '\"inherited\": 1' <<<\"\$out\""
expect "stderr summary reads inherited=1 in-scope=1 (the journal gate line's own token order)" \
  "grep -q 'gate-attribution: inherited=1 in-scope=1' '$ROOT/stderr.txt'"

# A pathless finding (e.g. a missing proof receipt) whose producer's inputs
# were NOT touched by this diff is inherited (requirement 1's second clause).
notes_file2="$ROOT/notes2.tsv"
printf 'proof-receipt\tmissing target/autobuilder/receipts/proof.json\n' > "$notes_file2"
out2="$("$GA" compute "$ROOT/repo" "$base_sha" "$head_sha" "$notes_file2" 2>/dev/null)"
p_scope="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['blocks'][0]['scope'])" "$out2")"
expect "pathless finding with untouched producer inputs is inherited" "[ '$p_scope' = 'inherited' ]"

# Same pathless receipt, but this diff DOES touch one of its producer
# inputs (Cargo.toml) — now it's in-scope.
echo '[dependencies]' >> "$ROOT/repo/Cargo.toml" 2>/dev/null || echo '[dependencies]' > "$ROOT/repo/Cargo.toml"
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q -m "touches Cargo.toml"
head_sha2="$(git -C "$ROOT/repo" rev-parse HEAD)"
out3="$("$GA" compute "$ROOT/repo" "$base_sha" "$head_sha2" "$notes_file2" 2>/dev/null)"
p_scope2="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['blocks'][0]['scope'])" "$out3")"
expect "pathless finding whose producer input IS touched is in-scope" "[ '$p_scope2' = 'in-scope' ]"

exit $fail
