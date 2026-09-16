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
#
# PRD-build-burst-gate-canary-invariant R14/AC16 (2026-09-16): the same
# FAKE burst-lane.sh convention, extended to the cap-unbounded-under-burst
# guard.
#   AC16a — burst active, gate_ready=true, but the status JSON has NEITHER
#           `width` NOR `run_slots.cap`, combined with the old compat knob
#           BUILD_DISTINCT_TARGETS=0 (the only way this repo's cap math
#           reaches 999999): exactly one of five is admitted, `cap=1
#           source=blocked cap_source=blocked`, and the other four are
#           journaled same-target-blocked cause=cap-unbounded-under-burst.
#   AC16b — regression guard, same fixture shape but `run_slots.cap=4`
#           present (no `width` key — proves the `.width // .run_slots.cap`
#           fallback still resolves on its own): four of five admitted,
#           `cap=4 source=burst`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG="$HERE/select-guard.sh"
[ -x "$SG" ] || { echo "selftest: $SG not executable" >&2; exit 2; }

# R16/AC19 (PRD-build-burst-gate-canary-invariant): every fake `status
# --json` below is built by loading the recorded FIXTURE and overriding
# just the field(s) under test via jq — never an inline JSON literal
# carrying a `gate_ready` key (the handwritten-interface-fixture lint,
# scripts/handwritten-fixture-lint.sh, fails exactly that shape).
FIXTURE="$HERE/../tests/fixtures/burst-status.json"
[ -f "$FIXTURE" ] || { echo "selftest: $FIXTURE not found" >&2; exit 2; }
JQ="$(command -v jq)" || { echo "selftest: jq not found" >&2; exit 2; }

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
# PRD-build-journal-single-writer requirement 1 routed select-guard.sh
# through the shared journal_line, which gives BUILD_JOURNAL_ROOT
# unconditional priority over SELECT_GUARD_JOURNAL. Under run-selftests.sh
# — which exports BUILD_JOURNAL_ROOT for its own isolation — that silently
# redirects select-guard.sh's writes away from $SELECT_GUARD_JOURNAL (same
# gotcha select-guard-selftest.sh already documents and unsets); AC16a
# below is the first case in THIS file to read the journal file content
# rather than just stderr, so it's the first case that would trip on it.
unset BUILD_JOURNAL_ROOT

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
unset BUILD_SAME_TARGET_CAP BUILD_SAME_TARGET_CAP_BURST BUILD_DISTINCT_TARGETS BUILD_MAX_BRANCHES
# Isolate from the host's REAL burst lane: with a live box, select-guard.sh's
# default $HERE/burst-lane.sh reports gate_ready=true + run_slots.cap and this
# "no session" case would widen to cap=4 source=burst (2026-09-16, box up).
export BURST_LANE_SH="$T/no-such-burst-lane.sh"
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
  local body; body="$("$JQ" -c --argjson w "$width" '. + {width: $w}' "$FIXTURE")"
  cat > "$FAKE/burst-lane.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "status" ] && [ "\${2:-}" = "--json" ]; then
  cat <<'JSONEOF'
$body
JSONEOF
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

# =========================================================================
# AC16 — PRD-build-burst-gate-canary-invariant R14: cap never unbounded
# under burst. mk_fake_burst_no_width prints gate_ready=true with NEITHER
# `width` NOR `run_slots.cap` (the exact shape a status probe returns when
# the box hasn't published either key yet); mk_fake_burst_slots_cap prints
# only `run_slots.cap` (no `width`) as the regression-guard fixture.
# =========================================================================
mk_fake_burst_no_width() {
  local body; body="$("$JQ" -c 'del(.width) | del(.run_slots.cap)' "$FIXTURE")"
  cat > "$FAKE/burst-lane.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "status" ] && [ "\${2:-}" = "--json" ]; then
  cat <<'JSONEOF'
$body
JSONEOF
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE/burst-lane.sh"
}
mk_fake_burst_slots_cap() {
  local cap="$1"
  local body; body="$("$JQ" -c --argjson c "$cap" 'del(.width) | .run_slots.cap = $c' "$FIXTURE")"
  cat > "$FAKE/burst-lane.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "status" ] && [ "\${2:-}" = "--json" ]; then
  cat <<'JSONEOF'
$body
JSONEOF
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE/burst-lane.sh"
}

echo "=== AC16a: burst active, gate_ready=true, no width/run_slots.cap, BUILD_DISTINCT_TARGETS=0 -> 1 admitted, cap=1 source=blocked ==="
mk_fake_burst_no_width
export BURST_LANE_SH="$FAKE/burst-lane.sh" BUILD_DISTINCT_TARGETS=0
admitted16a="$(run_pool)"
expect "AC16a: exactly one of five admitted (fail closed, not unbounded)" "[ \"$admitted16a\" -eq 1 ]"
diag16a="$(BUILD_MAX_BRANCHES=30 "$SG" satcap-mcphost-1 redbaron "$T/clone" 0 "" 2>&1 >/dev/null)"
expect "AC16a: diagnostic reads cap=1 source=blocked cap_source=blocked" "printf '%s' \"\$diag16a\" | grep -q 'cap=1 source=blocked cap_source=blocked'"
diag16a_block="$(BUILD_MAX_BRANCHES=30 "$SG" satcap-mcphost-1 redbaron "$T/clone" 0 "$TARGET" 2>&1 >/dev/null)"
expect "AC16a: second candidate's diagnostic names cause=cap-unbounded-under-burst" "printf '%s' \"\$diag16a_block\" | grep -q 'cause=cap-unbounded-under-burst'"
journal16a="$(cat "$SELECT_GUARD_JOURNAL" 2>/dev/null || true)"
expect "AC16a: journal has same-target-blocked cause=cap-unbounded-under-burst" "printf '%s' \"\$journal16a\" | grep -q 'same-target-blocked' && printf '%s' \"\$journal16a\" | grep -q 'cause=cap-unbounded-under-burst'"
unset BURST_LANE_SH BUILD_DISTINCT_TARGETS

echo "=== AC16b: regression guard — same fixture shape, run_slots.cap=4 present -> 4 admitted, cap=4 source=burst ==="
mk_fake_burst_slots_cap 4
export BURST_LANE_SH="$FAKE/burst-lane.sh" BUILD_DISTINCT_TARGETS=0 BUILD_SAME_TARGET_CAP_BURST=4
admitted16b="$(run_pool)"
expect "AC16b: four of five admitted (run_slots.cap fallback still resolves)" "[ \"$admitted16b\" -eq 4 ]"
diag16b="$(BUILD_MAX_BRANCHES=30 "$SG" satcap-mcphost-1 redbaron "$T/clone" 0 "" 2>&1 >/dev/null)"
expect "AC16b: diagnostic reads cap=4 source=burst" "printf '%s' \"\$diag16b\" | grep -q 'select same-target cap=4 source=burst'"
unset BURST_LANE_SH BUILD_DISTINCT_TARGETS BUILD_SAME_TARGET_CAP_BURST

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "select-guard-same-target-cap-selftest: ALL PASS"
  exit 0
else
  echo "select-guard-same-target-cap-selftest: assertion(s) FAILED"
  exit 1
fi
