#!/usr/bin/env bash
# tests/hostcontract_ac7_gate_incomplete_on_critical_drift.sh —
# PRD-build-host-contract AC7 (test_prefix hostcontract).
#
#   AC7 — a gate that starts during a critical host-contract drift ends
#   `incomplete infra=host-drift:<key>`, before any of the 24 receipt
#   producers ever runs — never `block`. Gated on
#   EXTEND_GATE_HOST_CONTRACT_CHECK=1 (extend-gate.sh's own default is
#   OFF; see that script's header) and a fixture double at
#   $HOST_CONTRACT_SH, never the real host-contract.sh.
#
#   Also proves the regression-safety default: with the flag unset (the
#   shape every OTHER extend-gate.sh selftest already runs under), the
#   same critical-drift fixture double is never even consulted and the
#   gate proceeds past this check.
#
# Reuses tests/revauth-common.sh's fixture crate builder (the same
# lightweight, no-real-cargo-toolchain path tests/revauth_ac*.sh already
# proves reaches extend-gate.sh's reviewer-auth-probe point safely) —
# this PRD's own check sits immediately before that point, so the same
# harness reaches it too.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=revauth-common.sh
source "$HERE/revauth-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/hostcontract-ac7.XXXXXX")"
trap '[ -n "${REVAUTH_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
revauth_write_fixture_crate "$REPO"

FAKE_HC="$T/fake-host-contract.sh"
cat > "$FAKE_HC" <<'FAKEHC'
#!/usr/bin/env bash
if [ "${1:-}" = "check" ]; then
  echo "manager-env:TMPDIR=drift(unset) severity=critical owner=self-heal"
  echo "tmp-usage:/tmp=drift(80%) severity=critical owner=operator"
  echo "path:autobuilder=drift(2-on-PATH) severity=warn owner=operator"
  exit 2
fi
exit 0
FAKEHC
chmod +x "$FAKE_HC"

JOURNAL="$T/journal.md"; : > "$JOURNAL"

t0=$(date +%s)
out="$(
  export EXTEND_GATE_HOST_CONTRACT_CHECK=1 HOST_CONTRACT_SH="$FAKE_HC" CLAUDE_CODE_OAUTH_TOKEN=irrelevant
  revauth_run_gate "$REPO" hostcontract-ac7-slug "$T/prds" "$JOURNAL" 2>&1
)"
rc=$?
t1=$(date +%s)
echo "$out" >&2

expect "AC7: extend-gate.sh exits 9 (incomplete)" "[ $rc -eq 9 ]"
expect "AC7: wall time under 90s" "[ $((t1 - t0)) -lt 90 ]"

line="$(tail -1 "$JOURNAL")"
expect "AC7: journal line reads outcome=incomplete" "printf '%s' '$line' | grep -q '  incomplete  '"
expect "AC7: journal line carries infra=host-drift: naming both critical keys" \
  "printf '%s' '$line' | grep -q 'infra=host-drift:manager-env:TMPDIR,tmp-usage:/tmp'"
expect "AC7: journal line never carries block" "! printf '%s' '$line' | grep -q '  block  '"
expect "AC7: journal line's phases= field names no receipt-producer phase" \
  "! printf '%s' '$line' | grep -oE 'phases=[^ ]*' | grep -qE 'risk-gate|intake|proof-receipt|vti-plan|rollback-plan|ci-checks|reviewer-auth-probe'"
expect "AC7: no receipt producer ever ran (empty/absent receipts dir)" \
  "[ \"\$(find '$REPO/target/autobuilder/receipts' -type f 2>/dev/null | wc -l)\" -eq 0 ]"

# --- regression safety: flag unset -> the same critical-drift fixture is
# never even consulted, and the gate proceeds past this check (reaches
# the reviewer-auth-probe point next, same as every other extend-gate
# selftest already assumes). -------------------------------------------
JOURNAL2="$T/journal2.md"; : > "$JOURNAL2"
out2="$(
  unset EXTEND_GATE_HOST_CONTRACT_CHECK
  export HOST_CONTRACT_SH="$FAKE_HC" CLAUDE_CODE_OAUTH_TOKEN=irrelevant
  revauth_run_gate "$REPO" hostcontract-ac7-off-slug "$T/prds" "$JOURNAL2" 2>&1
)"
rc2=$?
echo "$out2" >&2
expect "AC7 (flag off): never exits via the host-drift path (rc != 9, or a later producer's own rc)" \
  "[ $rc2 -ne 9 ] || ! grep -q 'infra=host-drift' '$JOURNAL2'"
expect "AC7 (flag off): journal never carries infra=host-drift" \
  "! grep -q 'infra=host-drift' '$JOURNAL2'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "hostcontract_ac7_gate_incomplete_on_critical_drift: ALL PASS"
else
  echo "hostcontract_ac7_gate_incomplete_on_critical_drift: FAILED" >&2
fi
exit "$fail"
