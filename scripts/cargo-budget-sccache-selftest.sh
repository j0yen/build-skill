#!/usr/bin/env bash
# cargo-budget-sccache-selftest.sh — proves cargo-budget.sh's sccache-
# assert wiring (PRD-build-gate-wall-clock requirement 2/5) without ever
# touching the real production sccache server. Same discipline as
# cargo-budget-selftest.sh: fixture binaries only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB="$HERE/cargo-budget.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/cargo-budget-sccache-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

quiet_loadavg() { printf '%s\n' "0.10 0.05 0.01 1/200 12345" > "$1"; }
healthy_meminfo() {
  cat > "$1" <<'EOF'
MemTotal:       31000000 kB
MemFree:        20000000 kB
MemAvailable:   25000000 kB
EOF
}

common_env() {
  export CARGO_BUDGET_STATE_DIR="$T/state" CARGO_BUDGET_JOURNAL="$T/journal.md"
  healthy_meminfo "$T/meminfo"; quiet_loadavg "$T/loadavg"
  export CARGO_BUDGET_MEMINFO="$T/meminfo" CARGO_BUDGET_LOADAVG="$T/loadavg"
  export CARGO_BUDGET_HOSTNAME="not-redbaron"
  mkdir -p "$T/state"
}

# --- case 1: sccache answering (fake) -> ledger row carries pid/started_at
common_env
FAKE_ASSERT_OK="$T/fake-assert-ok.sh"
cat > "$FAKE_ASSERT_OK" <<'EOF'
#!/usr/bin/env bash
echo "sccache-assert: ok pid=555 started_at=2026-09-10T04:00:00Z"
exit 0
EOF
chmod +x "$FAKE_ASSERT_OK"
out1="$(CARGO_BUDGET_SCCACHE_ASSERT=1 SCCACHE_ASSERT_SH="$FAKE_ASSERT_OK" "$CB" run -- echo hi)"; rc1=$?
[ "$rc1" -eq 0 ] && [[ "$out1" == *hi* ]] && pass "case1: run succeeds when sccache answers" \
  || fail "case1: run succeeds when sccache answers (rc=$rc1 out=$out1)"
row1="$(tail -1 "$T/state/ledger.jsonl")"
pid1="$(jq -r '.sccache_server.pid' <<<"$row1")"
started1="$(jq -r '.sccache_server.started_at' <<<"$row1")"
[ "$pid1" = "555" ] && pass "case1: ledger row carries sccache_server.pid" || fail "case1: ledger sccache_server.pid=$pid1 want 555"
[ "$started1" = "2026-09-10T04:00:00Z" ] && pass "case1: ledger row carries sccache_server.started_at" \
  || fail "case1: ledger sccache_server.started_at=$started1"

# --- case 2: sccache unreachable (fake) -> run refused, exit 4, no ledger row
rm -f "$T/state/ledger.jsonl"
FAKE_ASSERT_FAIL="$T/fake-assert-fail.sh"
cat > "$FAKE_ASSERT_FAIL" <<'EOF'
#!/usr/bin/env bash
echo "sccache-assert: sccache_unreachable — restart attempted, server still not answering within 5s" >&2
exit 1
EOF
chmod +x "$FAKE_ASSERT_FAIL"
rm -f "$T/command-ran.marker"
out2="$(CARGO_BUDGET_SCCACHE_ASSERT=1 SCCACHE_ASSERT_SH="$FAKE_ASSERT_FAIL" "$CB" run -- touch "$T/command-ran.marker" 2>&1)"; rc2=$?
[ "$rc2" -eq 4 ] && pass "case2: exit 4 on sccache_unreachable" || fail "case2: exit=$rc2 want 4"
[[ "$out2" == *sccache_unreachable* ]] && pass "case2: message names sccache_unreachable" \
  || fail "case2: message missing sccache_unreachable ($out2)"
[ ! -e "$T/command-ran.marker" ] && pass "case2: the wrapped command itself never ran" \
  || fail "case2: the wrapped command ran despite an unreachable server"
[ ! -s "$T/state/ledger.jsonl" ] && pass "case2: no ledger row written for a refused run" \
  || fail "case2: a ledger row was written for a refused run"
grep -q sccache_unreachable "$T/journal.md" && pass "case2: journaled sccache_unreachable" \
  || fail "case2: journal missing sccache_unreachable line"

# --- case 3: CARGO_BUDGET_SCCACHE_ASSERT=0 -> assert skipped entirely, even
#     with a failing fake assert script wired up
rm -f "$T/state/ledger.jsonl" "$T/journal.md"
out3="$(CARGO_BUDGET_SCCACHE_ASSERT=0 SCCACHE_ASSERT_SH="$FAKE_ASSERT_FAIL" "$CB" run -- echo runs-anyway)"; rc3=$?
[ "$rc3" -eq 0 ] && [[ "$out3" == *runs-anyway* ]] && pass "case3: assert_mode=off skips the check entirely" \
  || fail "case3: rc=$rc3 out=$out3"

if [ "$fails" -eq 0 ]; then
  echo "-----"
  echo "cargo-budget-sccache-selftest: ALL PASS"
else
  echo "-----"
  echo "cargo-budget-sccache-selftest: $fails FAILURE(S)" >&2
fi
exit "$fails"
