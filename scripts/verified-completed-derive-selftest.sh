#!/usr/bin/env bash
# verified-completed-derive-selftest.sh — durable acceptance harness for
# `verified-completed.sh --derive` (PRD-build-archive-autopair). Builds
# throwaway fixture repos + PRDs + a scratch manifest.json under a
# tempdir (fully hermetic — never touches a real ~/wintermute repo or
# the live state/manifest.json) and asserts AC1-AC7 from the PRD.
#
# Run: bash scripts/verified-completed-derive-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VC="$HERE/verified-completed.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/vc-derive-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ck(){ if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }

mkdir -p "$T/mcphost/tests" "$T/ac-judge/tests" "$T/clean-repo/tests" \
         "$T/prds" "$T/state"

# ---- shared-crate fixture: mcphost -------------------------------------
# Bare ac<NN> series belonging to a DIFFERENT ("core") PRD on this crate —
# present specifically to prove the prefix rule (and the bare-disabled
# guard) don't false-pair against it.
for i in 01 02 03 04 05; do : > "$T/mcphost/tests/ac${i}_unrelated_other_prd.rs"; done
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do : > "$T/mcphost/tests/http_ac${i}_thing.rs"; done
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do : > "$T/mcphost/tests/python_ac${i}_thing.rs"; done

# ---- shared-crate fixture: ac-judge --------------------------------------
for i in 1 2 3 4 5 6 7 8 9; do : > "$T/ac-judge/tests/acceptance_ac${i}.rs"; done
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  printf '#[test]\nfn ac%s_some_backend_behavior() {\n    assert!(true);\n}\n' "$i" \
    > "$T/ac-judge/tests/backend_ac${i}.rs"
done

cat > "$T/state/manifest.json" <<EOF
{"prds":[
  {"slug":"mcphost-rest-tools","output_repo_path":"$T/mcphost"},
  {"slug":"mcphost-code-tools","output_repo_path":"$T/mcphost"},
  {"slug":"ac-judge-pluggable-backend","output_repo_path":"$T/ac-judge"},
  {"slug":"clean-nomatch","output_repo_path":"$T/clean-repo"}
]}
EOF
export MANIFEST="$T/state/manifest.json"

cat > "$T/prds/PRD-mcphost-rest-tools.md" <<'EOF'
# PRD: mcphost-rest-tools fixture
Status: Draft v0.1
build_target: rust-extend
test_prefix: http

## Acceptance

1. a.
2. b.
3. c.
4. d.
5. e.
6. f.
7. g.
8. h.
9. i.
10. j.
11. k.
12. l.
13. m.
EOF

cat > "$T/prds/PRD-mcphost-code-tools.md" <<'EOF'
# PRD: mcphost-code-tools fixture
Status: Draft v0.1
build_target: rust-extend
test_prefix: python
deferred_acs: [15, 16]

## Acceptance

1. a.
2. b.
3. c.
4. d.
5. e.
6. f.
7. g.
8. h.
9. i.
10. j.
11. k.
12. l.
13. m.
14. n.
15. o.
16. p.
EOF

cat > "$T/prds/PRD-ac-judge-pluggable-backend.md" <<'EOF'
# PRD: ac-judge-pluggable-backend fixture (no test_prefix — must derive "backend")
Status: Draft v0.1
build_target: rust-extend

## Acceptance

1. a.
2. b.
3. c.
4. d.
5. e.
6. f.
7. g.
8. h.
9. i.
10. j.
11. k.
12. l.
13. m.
EOF

cat > "$T/prds/PRD-prose-deferred.md" <<'EOF'
# PRD: prose deferred_acs fixture
Status: Draft v0.1
build_target: rust-extend
deferred_acs: see note below

## Acceptance

1. a (no test anywhere).
2. b (no test anywhere).
EOF

cat > "$T/prds/PRD-clean-nomatch.md" <<'EOF'
# PRD: clean nomatch fixture (repo with tests/ but no matching AC files)
Status: Draft v0.1
build_target: rust-extend

## Acceptance

1. an AC with no matching file or function anywhere.
2. a second AC, also unmatched.
EOF

# ---- AC1: http_ prefix, all 13 PAIRED, exit 0 ---------------------------
out="$("$VC" "$T/prds/PRD-mcphost-rest-tools.md" --derive --format json)"
ck "AC1 exit 0" '"$VC" "$T/prds/PRD-mcphost-rest-tools.md" --derive >/dev/null 2>&1'
ck "AC1 all 13 via prefix:http" \
  '[ "$(printf "%s" "$out" | grep -o "\"rule\":\"prefix:http\"" | wc -l)" -eq 13 ]'
ck "AC1 zero missing" '[ "$(printf "%s" "$out" | grep -o "\"missing\":\[\]")" = "\"missing\":[]" ]'

# ---- AC2: python_ prefix for 1-14, 15/16 DEFERRED (not false-paired to
# the unrelated bare ac15/ac16 files), exit 0 -----------------------------
out="$("$VC" "$T/prds/PRD-mcphost-code-tools.md" --derive --format json)"
ck "AC2 exit 0" '"$VC" "$T/prds/PRD-mcphost-code-tools.md" --derive >/dev/null 2>&1'
ck "AC2 14 via prefix:python" \
  '[ "$(printf "%s" "$out" | grep -o "\"rule\":\"prefix:python\"" | wc -l)" -eq 14 ]'
ck "AC2 AC15 DEFERRED (not bare-matched)" \
  'printf "%s" "$out" | grep -q "{\"ac\":15,\"status\":\"DEFERRED\""'
ck "AC2 AC16 DEFERRED (not bare-matched)" \
  'printf "%s" "$out" | grep -q "{\"ac\":16,\"status\":\"DEFERRED\""'

# ---- AC3: prose deferred_acs -> named + MISSING, exit 1 ------------------
err="$("$VC" "$T/prds/PRD-prose-deferred.md" --derive 2>&1 1>/dev/null)"
out="$("$VC" "$T/prds/PRD-prose-deferred.md" --derive 2>/dev/null)"; rc=$?
ck "AC3 exit 1" '[ "$rc" -eq 1 ]'
ck "AC3 unparsed message" 'printf "%s" "$out" | grep -qF "deferred_acs: unparsed — use [N, N]"'
ck "AC3 both ACs MISSING" '[ "$(printf "%s\n" "$out" | grep -c ": MISSING")" -eq 2 ]'

# ---- AC4: ac-judge, no test_prefix, derives "backend", all 13 PAIRED ----
out="$("$VC" "$T/prds/PRD-ac-judge-pluggable-backend.md" --derive --format json)"
ck "AC4 exit 0" '"$VC" "$T/prds/PRD-ac-judge-pluggable-backend.md" --derive >/dev/null 2>&1'
ck "AC4 all 13 via prefix:backend" \
  '[ "$(printf "%s" "$out" | grep -o "\"rule\":\"prefix:backend\"" | wc -l)" -eq 13 ]'

# ---- AC5: no match anywhere -> MISSING, exit 1 ---------------------------
"$VC" "$T/prds/PRD-clean-nomatch.md" --derive >/dev/null 2>&1
ck "AC5 exit 1" '[ $? -eq 1 ]'

# ---- AC6: --paired 1 + derivation -> AC1 PAIRED/asserted, AC2 still
# MISSING (derivation not overridden, --paired only adds) -----------------
out="$("$VC" "$T/prds/PRD-clean-nomatch.md" --derive --paired 1 --format table 2>/dev/null)"
"$VC" "$T/prds/PRD-clean-nomatch.md" --derive --paired 1 >/dev/null 2>&1; rc=$?
ck "AC6 exit 1 (AC2 still missing)" '[ "$rc" -eq 1 ]'
ck "AC6 AC1 rule=asserted" 'printf "%s\n" "$out" | awk -F"\t" "\$1==1{print \$2}" | grep -qx asserted'
ck "AC6 AC1 classification PAIRED" 'printf "%s\n" "$out" | awk -F"\t" "\$1==1{print \$4}" | grep -qx PAIRED'

# ---- AC7: --verify-run marks a failing paired test PAIRED-FAILING,
# exit 1 (P1) --------------------------------------------------------------
mkdir -p "$T/vrepo/src" "$T/vrepo/tests"
cat > "$T/vrepo/Cargo.toml" <<'EOF'
[package]
name = "vrfix"
version = "0.1.0"
edition = "2021"
EOF
echo 'pub fn add(a: i32, b: i32) -> i32 { a + b }' > "$T/vrepo/src/lib.rs"
cat > "$T/vrepo/tests/ac1_passes.rs" <<'EOF'
#[test]
fn it_passes() { assert_eq!(vrfix::add(2, 2), 4); }
EOF
cat > "$T/vrepo/tests/ac2_fails.rs" <<'EOF'
#[test]
fn it_fails() { assert_eq!(vrfix::add(2, 2), 5); }
EOF
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"
"$JQ" --arg r "$T/vrepo" '.prds += [{"slug":"vrfix","output_repo_path":$r}]' \
  "$T/state/manifest.json" > "$T/state/manifest.json.tmp" \
  && mv "$T/state/manifest.json.tmp" "$T/state/manifest.json"
cat > "$T/prds/PRD-vrfix.md" <<'EOF'
# PRD: vrfix fixture
Status: Draft v0.1
build_target: rust-cli

## Acceptance

1. addition works.
2. addition is wrong on purpose (should fail under --verify-run).
EOF
out="$("$VC" "$T/prds/PRD-vrfix.md" --derive --verify-run --format table 2>/dev/null)"
"$VC" "$T/prds/PRD-vrfix.md" --derive --verify-run >/dev/null 2>&1; rc=$?
ck "AC7 exit 1" '[ "$rc" -eq 1 ]'
ck "AC7 AC2 PAIRED-FAILING" 'printf "%s\n" "$out" | awk -F"\t" "\$1==2{print \$4}" | grep -qx PAIRED-FAILING'
ck "AC7 AC1 still PAIRED" 'printf "%s\n" "$out" | awk -F"\t" "\$1==1{print \$4}" | grep -qx PAIRED'

echo "----"
echo "verified-completed-derive-selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
