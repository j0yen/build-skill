#!/usr/bin/env bash
# tests/canary_ac19_handwritten_fixture_lint.sh — PRD-build-burst-gate-
# canary-invariant AC19: given a selftest file under scripts/ or tests/
# with an inline JSON literal carrying a gate_ready key, the lint fails
# naming file:line; given the same file loading tests/fixtures/burst-
# status.json and overriding fields, the lint passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
LINT="$SKILL_DIR/scripts/handwritten-fixture-lint.sh"
[ -x "$LINT" ] || { echo "ac19: $LINT not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac19.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "== AC19a: inline literal with active+gate_ready -> fails, names file:line =="
# The two halves below are assembled at THIS script's runtime, each on its
# own line with only one of the two trigger keys -- neither line here
# matches the lint's own "both keys, one line" rule, so a later `--all`
# sweep never flags this selftest for demonstrating the pattern it tests.
# Concatenated, they become the single-line printf literal that lands in
# the GENERATED bad-selftest.sh, which is what the lint actually scans.
_half1='{"active":true,'
_half2='"gate_ready":"true","width":8}'
{
  printf '#!/usr/bin/env bash\n'
  printf 'mk_fake() {\n'
  printf "  printf '%s%s\\\\n'\n" "$_half1" "$_half2"
  printf '}\n'
} > "$T/bad-selftest.sh"
out_a="$("$LINT" "$T/bad-selftest.sh" 2>&1)"; rc_a=$?
expect "AC19a: exit 1" "[ $rc_a -eq 1 ]"
expect "AC19a: names handwritten-interface-fixture with file:line" \
  "printf '%s' \"\$out_a\" | grep -q 'handwritten-interface-fixture '\"\$T\"'/bad-selftest.sh:3'"

echo "== AC19b: same file rewritten to load the fixture + jq-override -> passes =="
cat > "$T/good-selftest.sh" <<EOF
#!/usr/bin/env bash
FIXTURE="$SKILL_DIR/tests/fixtures/burst-status.json"
mk_fake() {
  jq -c --argjson w 8 '. + {width: \$w}' "\$FIXTURE"
}
EOF
out_b="$("$LINT" "$T/good-selftest.sh" 2>&1)"; rc_b=$?
expect "AC19b: exit 0" "[ $rc_b -eq 0 ]"
expect "AC19b: no violation printed" "[ -z \"\$out_b\" ]"

echo "== AC19c: a bare jq path expression (.gate_ready, no literal object) never trips it =="
cat > "$T/jqpath-selftest.sh" <<'EOF'
#!/usr/bin/env bash
gr="$(jq -r '.gate_ready' status.json)"
[ "$gr" = "true" ] && echo active
EOF
out_c="$("$LINT" "$T/jqpath-selftest.sh" 2>&1)"; rc_c=$?
expect "AC19c: exit 0" "[ $rc_c -eq 0 ]"

echo "== AC19d: a session.json-shaped fixture (gate_ready, no active key) never trips it =="
cat > "$T/session-selftest.sh" <<'EOF'
#!/usr/bin/env bash
cat > session.json <<'JSONEOF'
{"server_id":"1","ip":"203.0.113.10","gate_ready":"true"}
JSONEOF
EOF
out_d="$("$LINT" "$T/session-selftest.sh" 2>&1)"; rc_d=$?
expect "AC19d: exit 0" "[ $rc_d -eq 0 ]"

echo "== AC19e: the canonical fixture file itself is always exempt =="
out_e="$("$LINT" "$SKILL_DIR/tests/fixtures/burst-status.json" 2>&1)"; rc_e=$?
expect "AC19e: exit 0" "[ $rc_e -eq 0 ]"

if [ "$fail" -eq 0 ]; then
  echo "canary_ac19_handwritten_fixture_lint: ALL PASS"
else
  echo "canary_ac19_handwritten_fixture_lint: assertion(s) FAILED" >&2
fi
exit "$fail"
