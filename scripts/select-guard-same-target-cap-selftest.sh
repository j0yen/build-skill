#!/usr/bin/env bash
# select-guard-same-target-cap-selftest.sh — PRD-build-gate-before-land
# requirement 5 (P0) / AC8, AC9: BUILD_SAME_TARGET_CAP replaces the binary
# BUILD_DISTINCT_TARGETS check with a real numeric per-target admission cap,
# widened when a burst-lane session reports `gate_ready=true` for
# `build_target: rust-extend` candidates. Complements the pre-existing
# select-guard-selftest.sh (compat coverage: BUILD_DISTINCT_TARGETS=1 still
# forces 1, BUILD_DISTINCT_TARGETS=0 still disables the cap — both
# unmodified by this PRD's own test file).
#
#   AC8 — no burst session, five queued mcphost-shaped PRDs sharing one
#         build_into: exactly one is admitted, `select same-target cap=1
#         source=local` is printed; BUILD_DISTINCT_TARGETS=1 +
#         BUILD_SAME_TARGET_CAP=3 together still admit exactly one (the
#         compat knob wins over the numeric cap).
#   AC9 — a FAKE burst-lane.sh reports an active gate_ready=true session
#         with width 8 and BUILD_SAME_TARGET_CAP_BURST=4: four of five are
#         admitted, `cap=4 source=burst`; width 2 admits two, `cap=2
#         source=burst` (min(cap_burst, width) both ways).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG="$HERE/select-guard.sh"
[ -x "$SG" ] || { echo "selftest: $SG not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/select-guard-satcap-selftest.XXXXXX")"
trap '[ -n "${SELECT_GUARD_SATCAP_KEEP:-}" ] || rm -rf "$T"' EXIT
# PRD-build-gate-before-land requirement 7: select-guard.sh now journals
# every same-target admit/block decision — isolate it, or every run of
# this selftest (five candidates x N sub-scenarios) pollutes the real
# shared journal.
export SELECT_GUARD_JOURNAL="$T/select-guard-journal.md"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone" >/dev/null 2>&1
mkdir -p "$T/clone/build-queue"
TARGET="/tmp/select-guard-satcap-mcphost-repo"
for n in 1 2 3 4 5; do
  cat > "$T/clone/build-queue/PRD-satcap-mcphost-$n.md" <<EOF
# PRD: satcap-mcphost-$n

- Status: queued
- build_target: rust-extend
- build_into: $TARGET
EOF
done
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
BRANCH="$(git -C "$T/clone" symbolic-ref --short HEAD)"
git -C "$T/clone" push -q origin "$BRANCH"
export JOURNAL_DIR="$T/journal"
mkdir -p "$JOURNAL_DIR"

# Drives select-guard.sh over the 5 fixture PRDs in order, returns the
# count admitted (stdout) with the given env already exported by the
# caller. Mirrors SKILL.md's own caller-maintained branch-count/
# admitted-targets running-state convention.
run_pool() {
  local branch_count=0 admitted_targets="" admitted=0 n out rc
  for n in 1 2 3 4 5; do
    out=$("$SG" "satcap-mcphost-$n" redbaron "$T/clone" "$branch_count" "$admitted_targets" 2>/tmp/select-guard-satcap-last.stderr)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      admitted=$((admitted + 1))
      branch_count=$((branch_count + 1))
      admitted_targets="${admitted_targets:+$admitted_targets,}$TARGET"
    fi
  done
  echo "$admitted"
}

# =========================================================================
# AC8 — no burst session (no BURST_LANE_SH override, so select-guard.sh
# falls back to $HERE/burst-lane.sh — the real one, which reports no
# active session in this sandboxed environment) -> cap=1, source=local.
# =========================================================================
echo "=== AC8: no burst session ==="
unset BUILD_SAME_TARGET_CAP BUILD_SAME_TARGET_CAP_BURST BUILD_DISTINCT_TARGETS BUILD_MAX_BRANCHES BURST_LANE_SH
admitted="$(run_pool)"
expect "AC8: exactly one of five admitted (default cap=1)" "[ \"$admitted\" -eq 1 ]"
diag="$(BUILD_MAX_BRANCHES=30 "$SG" satcap-mcphost-1 redbaron "$T/clone" 0 "" 2>&1 >/dev/null)"
expect "AC8: diagnostic reads cap=1 source=local" "printf '%s' \"\$diag\" | grep -q 'select same-target cap=1 source=local'"

echo "=== AC8b: BUILD_DISTINCT_TARGETS=1 + BUILD_SAME_TARGET_CAP=3 -> still exactly one ==="
export BUILD_DISTINCT_TARGETS=1 BUILD_SAME_TARGET_CAP=3
admitted8b="$(run_pool)"
expect "AC8b: compat knob (=1) still wins over a higher numeric cap" "[ \"$admitted8b\" -eq 1 ]"
unset BUILD_DISTINCT_TARGETS BUILD_SAME_TARGET_CAP

# =========================================================================
# AC9 — fake burst-lane.sh: active session, gate_ready=true, width N.
# =========================================================================
FAKE="$T/fake-burst-bin"
mkdir -p "$FAKE"
mk_fake_burst() {
  local width="$1"
  cat > "$FAKE/burst-lane.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "status" ] && [ "\${2:-}" = "--json" ]; then
  printf '{"active":true,"gate_ready":"true","width":$width}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE/burst-lane.sh"
}

echo "=== AC9a: burst active, width=8, BUILD_SAME_TARGET_CAP_BURST=4 -> 4 admitted, cap=4 ==="
mk_fake_burst 8
export BURST_LANE_SH="$FAKE/burst-lane.sh" BUILD_SAME_TARGET_CAP_BURST=4
admitted9a="$(run_pool)"
expect "AC9a: four of five admitted (min(4,8)=4)" "[ \"$admitted9a\" -eq 4 ]"
diag9a="$(BUILD_MAX_BRANCHES=30 "$SG" satcap-mcphost-1 redbaron "$T/clone" 0 "" 2>&1 >/dev/null)"
expect "AC9a: diagnostic reads cap=4 source=burst" "printf '%s' \"\$diag9a\" | grep -q 'select same-target cap=4 source=burst'"

echo "=== AC9b: burst active, width=2, BUILD_SAME_TARGET_CAP_BURST=4 -> 2 admitted, cap=2 ==="
mk_fake_burst 2
admitted9b="$(run_pool)"
expect "AC9b: two of five admitted (min(4,2)=2)" "[ \"$admitted9b\" -eq 2 ]"
diag9b="$(BUILD_MAX_BRANCHES=30 "$SG" satcap-mcphost-1 redbaron "$T/clone" 0 "" 2>&1 >/dev/null)"
expect "AC9b: diagnostic reads cap=2 source=burst" "printf '%s' \"\$diag9b\" | grep -q 'select same-target cap=2 source=burst'"
unset BURST_LANE_SH BUILD_SAME_TARGET_CAP_BURST

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "select-guard-same-target-cap-selftest: ALL PASS"
  exit 0
else
  echo "select-guard-same-target-cap-selftest: assertion(s) FAILED"
  exit 1
fi
