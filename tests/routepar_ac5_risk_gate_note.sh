#!/usr/bin/env bash
# tests/routepar_ac5_risk_gate_note.sh — PRD-build-gate-route-parity-
# ledger AC5: "Given a risk-gate.json with 2 BLOCKING findings, When the
# risk-gate producer fails, Then the note reads risk-gate — 2 BLOCKING
# finding(s), receipt target/autobuilder/receipts/risk-gate.json; Given
# an empty file, Then the note says receipt unreadable (0 bytes) and the
# producer still fails."
#
# scripts/audit.sh lives INSIDE the gated repo (extend-gate.sh only
# invokes it when the crate has one), so this test drops its own
# controllable fake there (FAKE_AUDIT_MODE / FAKE_AUDIT_BLOCKING_N /
# FAKE_AUDIT_RC) rather than in tests/fixtures/routepar-fake/, which
# stands in for the SHARED toolchain (autobuilder/claude/gh/...) every
# routepar test uses identically.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/routepar-common.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/routepar-ac5-selftest.XXXXXX")"
trap '[ -n "${ROUTEPAR_AC5_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
routepar_write_fixture_crate "$REPO"
mkdir -p "$REPO/scripts"
cat > "$REPO/scripts/audit.sh" <<'EOF'
#!/usr/bin/env bash
# Fake audit.sh for routepar_ac5 — writes a controllable JSONL findings
# file at the real gate's own expected path and exits per FAKE_AUDIT_RC.
set -uo pipefail
mkdir -p target/autobuilder/receipts
out=target/autobuilder/receipts/risk-gate.json
case "${FAKE_AUDIT_MODE:-normal}" in
  empty)   : > "$out" ;;
  missing) rm -f "$out" ;;
  *)
    : > "$out"
    i=0
    while [ "$i" -lt "${FAKE_AUDIT_BLOCKING_N:-0}" ]; do
      echo '{"severity":"blocking","id":"fake-'"$i"'"}' >> "$out"
      i=$((i + 1))
    done
    echo '{"severity":"advisory","id":"fake-adv"}' >> "$out"
    ;;
esac
exit "${FAKE_AUDIT_RC:-0}"
EOF
chmod +x "$REPO/scripts/audit.sh"
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "add fake audit.sh"

JOURNAL="$T/journal.md"
: > "$JOURNAL"
export FAKE_GH_AUTH_RC=0

echo "=== AC5a: 2 BLOCKING findings -> the note names the count and receipt path ==="
export FAKE_AUDIT_MODE=normal FAKE_AUDIT_BLOCKING_N=2 FAKE_AUDIT_RC=1
out_a="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_AUDIT_MODE FAKE_AUDIT_BLOCKING_N FAKE_AUDIT_RC
line_a="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC5a: gate line blocks with risk-gate@local named" "[[ '$line_a' == *'blocking='*'risk-gate@local'* ]]"
expect "AC5a: note reads '2 BLOCKING finding(s)'" "[[ '$line_a' == *'2 BLOCKING finding(s)'* ]]"
expect "AC5a: note names the relative receipt path" \
  "[[ '$line_a' == *'receipt target/autobuilder/receipts/risk-gate.json'* ]]"

echo "=== AC5b: an empty risk-gate.json -> 'receipt unreadable (0 bytes)', producer still fails ==="
export FAKE_AUDIT_MODE=empty FAKE_AUDIT_RC=1
out_b="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_AUDIT_MODE FAKE_AUDIT_RC
line_b="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC5b: gate line blocks with risk-gate@local named" "[[ '$line_b' == *'blocking='*'risk-gate@local'* ]]"
expect "AC5b: note reads 'receipt unreadable (0 bytes)'" "[[ '$line_b' == *'receipt unreadable (0 bytes)'* ]]"
val_b="$(printf '%s\n' "$line_b" | grep -oE '[,=]risk-gate:[^, )]*' | sed -E 's/^.risk-gate://')"
expect "AC5b: risk-gate phase still records a fail (trailing !), got '$val_b'" "[[ '$val_b' == *'!' ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac5: ALL PASS"
else
  echo "routepar_ac5: assertion(s) FAILED"
fi
exit "$fail"
