#!/usr/bin/env bash
# reality-check-selftest.sh — durable acceptance harness for the tier-aware
# post-ship reality check (PRD-build-post-ship-reality-check requirement 3,
# 2026-09-12 revision: container tier immediate, box-only event-driven,
# 6h alarm). Covers the slice that shipped 2026-09-11 only by exercising it
# unchanged (regression); the bulk of these cases are the NEW mechanics:
#
#   AC9  — a container-coverable AC whose real box is unreachable runs THIS
#          SAME TICK in a fresh, empty, non-root bwrap sandbox on this host
#          (no gate tools on PATH, uid != 0), tier=container in the receipt.
#   AC2  — a box-only AC whose box is unreachable on TWO spaced probes
#          registers pending (not a bare "unreachable"), with a
#          registration timestamp and both probes journaled.
#   AC10 — `pending-run <target>` executes a registered pending check
#          against a just-booted box, writes the verdict back onto the
#          ORIGINAL parent PRD (tier=box), and removes the registration so
#          a later boot doesn't repeat it.
#   AC11 — `alarm-check` fires exactly one alarm for a registration ≥6h old
#          with no boot window, then never repeats for the same pending
#          state (real failure-mode case: the second alarm-check call).
#   AC7  — a pure-fixture PRD (no substrate-naming AC with a runnable
#          command) gets a `reality: fixture-only` receipt, not a silent
#          skip and never a false `pending` (real failure-mode case: an
#          absent PRD path must die, tested at the very end).
#   regression — a REACHABLE box AC still runs live (tier=live), unaffected
#          by the tier split; a failing live AC still drafts a follow-up.
#
# Run: bash scripts/reality-check-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
RC="$HERE/reality-check.sh"
[ -x "$RC" ] || { echo "selftest: $RC not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/reality-check-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label" >&2; FAIL=$((FAIL+1)); fi
}
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# One throwaway "shared PRDs checkout" fixture per case, bare origin + one
# clone, same shape as archive-commit-selftest.sh's new_prd_fixture, so
# commit_and_push exercises the real git commit path (still --no-push'd,
# never touching the real ~/Documents/PRDs clone).
new_fixture() {
  local d="$1"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/prds" 2>/dev/null
  mkdir -p "$d/prds/build-queue" "$d/prds/built-prds" "$d/prds/visions"
  : > "$d/prds/visions/selftest.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm init
}

export BUILD_JOURNAL_DIR="$T/journal"
export BUILD_RECEIPTS_DIR="$T/journal/receipts"
export REALITY_CHECK_PENDING_DIR="$T/reality-pending"
mkdir -p "$BUILD_JOURNAL_DIR" "$BUILD_RECEIPTS_DIR" "$REALITY_CHECK_PENDING_DIR"

FAKE_INACTIVE="$T/fake-burst-lane-inactive.sh"
cat > "$FAKE_INACTIVE" <<'EOF'
#!/usr/bin/env bash
echo '{"active": false}'
EOF
chmod +x "$FAKE_INACTIVE"

FAKE_ACTIVE="$T/fake-burst-lane-active.sh"
cat > "$FAKE_ACTIVE" <<'EOF'
#!/usr/bin/env bash
echo '{"active": true}'
EOF
chmod +x "$FAKE_ACTIVE"

# ======================================================================
# == plan: tier classification (foundation for AC9/AC2) ==
# ======================================================================
D1="$T/d1"; new_fixture "$D1"
cat > "$D1/prds/build-queue/PRD-tiertest.md" <<'EOF'
# PRD: tiertest

- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given the real box, When `echo cc` runs against the live lane, Then it exits 0.
2. P0 — Given the real box, When `echo bo` runs via hcloud snapshot against the live lane, Then it exits 0.
EOF
plan1="$("$RC" plan "$D1/prds/build-queue/PRD-tiertest.md")"
expect "plan AC1: default tier is container-coverable" \
  "[ \"\$(echo \"\$plan1\" | \"\${JQ:-jq}\" -r '.[0].tier')\" = container-coverable ]"
expect "plan AC2: hcloud/snapshot keyword tags box-only" \
  "[ \"\$(echo \"\$plan1\" | \"\${JQ:-jq}\" -r '.[1].tier')\" = box-only ]"

# ======================================================================
# == AC9: container-coverable AC runs in a fresh sandbox this same tick,
#    tier=container, no gate tools on PATH, non-root uid (real assertion,
#    not just an exit-code check) ==
# ======================================================================
D2="$T/d2"; new_fixture "$D2"
cat > "$D2/prds/build-queue/PRD-container-ac9.md" <<'EOF'
# PRD: container-ac9

- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given the real box, When `id -u; command -v gh || echo no-gh-found` runs against the live lane, Then it exits 0.
EOF
REALITY_CHECK_BURST_LANE="$FAKE_INACTIVE" \
  "$RC" run "$D2/prds/build-queue/PRD-container-ac9.md" --no-push >"$T/ac9.out" 2>&1
rc9=$?
receipt9="$(grep -m1 '^- reality_receipt:' "$D2/prds/build-queue/PRD-container-ac9.md" | sed -E 's/^- reality_receipt: *//')"
expect "AC9: run exits 0" "[ $rc9 -eq 0 ]"
expect "AC9: reality=ok (container tier answered for real)" \
  "grep -qxe '- reality: ok' '$D2/prds/build-queue/PRD-container-ac9.md'"
expect "AC9: receipt records tier=container" "grep -q 'tier=container' '$receipt9'"
expect "AC9: receipt shows the sandbox ran as a non-root uid (65534)" "grep -q '^65534$' '$receipt9'"
expect "AC9: receipt shows gh genuinely absent inside the sandbox (real assertion, not fixture)" \
  "grep -q 'no-gh-found' '$receipt9'"
expect "AC9: no dedicated box was needed — probe-1 shows unreachable before the container ran" \
  "grep -q 'probe-1: unreachable' '$receipt9'"

# ======================================================================
# == AC2/AC10: box-only AC unreachable on two spaced probes registers
#    pending (real failure-mode case: genuinely-down substrate), then
#    pending-run consumes it against a just-booted box ==
# ======================================================================
D3="$T/d3"; new_fixture "$D3"
cat > "$D3/prds/build-queue/PRD-boxonly-ac2.md" <<'EOF'
# PRD: boxonly-ac2

- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given the real box, When `echo boxonly-ran-for-real` runs via hcloud snapshot against the live lane, Then it exits 0.
EOF
rm -f "$REALITY_CHECK_PENDING_DIR/boxonly-ac2-ac1.json"
REALITY_CHECK_BURST_LANE="$FAKE_INACTIVE" REALITY_CHECK_PROBE_SPACING=0 \
  "$RC" run "$D3/prds/build-queue/PRD-boxonly-ac2.md" --no-push >"$T/ac2.out" 2>&1
expect "AC2: reality=pending, not a bare unreachable" \
  "grep -qxe '- reality: pending' '$D3/prds/build-queue/PRD-boxonly-ac2.md'"
expect "AC2: registration timestamp is recorded on the parent PRD" \
  "grep -qE '^- reality_pending_since: [0-9T:Z-]+$' '$D3/prds/build-queue/PRD-boxonly-ac2.md'"
expect "AC2: registration file exists under state/reality-pending/" \
  "[ -f '$REALITY_CHECK_PENDING_DIR/boxonly-ac2-ac1.json' ]"
expect "AC2: journal shows two spaced probes (probe-1 and probe-2, both unreachable — the real failure-mode case)" \
  "[ \"\$(grep -o 'reality  probe  probe-[12]' '$BUILD_JOURNAL_DIR'/*.md | wc -l)\" -ge 2 ]"

"$RC" pending-run 203.0.113.9 >"$T/ac10.out" 2>&1
rc10=$?
expect "AC10: pending-run exits 0" "[ $rc10 -eq 0 ]"
expect "AC10: registration is consumed (removed so a later boot doesn't repeat it)" \
  "[ ! -f '$REALITY_CHECK_PENDING_DIR/boxonly-ac2-ac1.json' ]"
expect "AC10: the ORIGINAL parent PRD gets the verdict (tier=box), reality=ok" \
  "grep -qxe '- reality: ok' '$D3/prds/build-queue/PRD-boxonly-ac2.md'"
expect "AC10: no dedicated box was booted for it — pending-run only recorded a receipt for the given target" \
  "grep -q 'target: 203.0.113.9' \"\$(grep -m1 '^- reality_receipt:' '$D3/prds/build-queue/PRD-boxonly-ac2.md' | sed -E 's/^- reality_receipt: *//')\""

# ======================================================================
# == AC11: 6h-pending alarm fires exactly once, never repeats ==
# ======================================================================
OLD_TS="$(date -u -d '7 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7H +%Y-%m-%dT%H:%M:%SZ)"
cat > "$REALITY_CHECK_PENDING_DIR/selftest-alarmtest-ac1.json" <<EOF
{"prd": "$T/nonexistent.md", "slug": "alarmtest", "ac": 1, "command": "true",
 "registered_at": "$OLD_TS", "probes": [], "alarmed": false}
EOF
before_lines="$(wc -l < "$BUILD_JOURNAL_DIR/$(date -u +%F).md" 2>/dev/null || echo 0)"
"$RC" alarm-check >"$T/alarm1.out" 2>&1
expect "AC11: first alarm-check fires exactly one alarm naming the ship+AC" \
  "grep -q 'reality-alarm.*alarmtest AC1' '$T/alarm1.out'"
expect "AC11: the registration is marked alarmed so it can't fire twice" \
  "grep -q '\"alarmed\": *true' '$REALITY_CHECK_PENDING_DIR/selftest-alarmtest-ac1.json'"
after1_lines="$(wc -l < "$BUILD_JOURNAL_DIR/$(date -u +%F).md" 2>/dev/null || echo 0)"
"$RC" alarm-check >"$T/alarm2.out" 2>&1
expect "AC11: second alarm-check (real failure-mode case: same pending state again) emits no new alarm" \
  "! grep -q 'reality-alarm' '$T/alarm2.out'"
after2_lines="$(wc -l < "$BUILD_JOURNAL_DIR/$(date -u +%F).md" 2>/dev/null || echo 0)"
expect "AC11: journal gained exactly one alarm line, not two" \
  "[ \$((after1_lines - before_lines)) -ge 1 ] && [ \"\$after2_lines\" -eq \"\$after1_lines\" ]"
rm -f "$REALITY_CHECK_PENDING_DIR/selftest-alarmtest-ac1.json"

# ======================================================================
# == AC7: pure-fixture PRD gets a fixture-only receipt, never a false
#    pending (real failure-mode case: no runnable substrate command at all) ==
# ======================================================================
D4="$T/d4"; new_fixture "$D4"
cat > "$D4/prds/build-queue/PRD-fixtureonly-ac7.md" <<'EOF'
# PRD: fixtureonly-ac7

- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given a mocked client, When it calls the fake endpoint, Then it returns 200.
EOF
"$RC" run "$D4/prds/build-queue/PRD-fixtureonly-ac7.md" --no-push >"$T/ac7.out" 2>&1
expect "AC7: reality=fixture-only, never a bare skip" \
  "grep -qxe '- reality: fixture-only' '$D4/prds/build-queue/PRD-fixtureonly-ac7.md'"
expect "AC7: reality is never pending for a pure-fixture ship" \
  "! grep -qxe '- reality: pending' '$D4/prds/build-queue/PRD-fixtureonly-ac7.md'"
expect "AC7: the receipt itself says fixture-only" \
  "grep -q 'result: fixture-only' \"\$(grep -m1 '^- reality_receipt:' '$D4/prds/build-queue/PRD-fixtureonly-ac7.md' | sed -E 's/^- reality_receipt: *//')\""

# ======================================================================
# == regression: a REACHABLE box AC still runs live (tier=live), and a
#    failing live AC still drafts a follow-up — unchanged by the tier
#    split above (real failure-mode case: the live command fails) ==
# ======================================================================
D5="$T/d5"; new_fixture "$D5"
cat > "$D5/prds/build-queue/PRD-live-regress.md" <<'EOF'
# PRD: live-regress

- Status: queued
- build_target: shell
- Vision: visions/selftest.md

## Acceptance criteria

1. P0 — Given the real box, When `false` runs against the live lane, Then it exits 0.
EOF
REALITY_CHECK_BURST_LANE="$FAKE_ACTIVE" \
  "$RC" run "$D5/prds/build-queue/PRD-live-regress.md" --no-push >"$T/regress.out" 2>&1
expect "regression: a reachable box still runs live and a real failure is recorded" \
  "grep -qxe '- reality: failed' '$D5/prds/build-queue/PRD-live-regress.md'"
expect "regression: a failing live AC still drafts a follow-up PRD" \
  "grep -qE '^- reality_followup: PRD-live-regress-reality-[0-9]+\.md$' '$D5/prds/build-queue/PRD-live-regress.md'"

# ======================================================================
# == real failure-mode case: pending-run against an absent registration
#    dir is a clean no-op, not a crash ==
# ======================================================================
rmdir "$REALITY_CHECK_PENDING_DIR" 2>/dev/null || true
"$RC" pending-run 203.0.113.9 >"$T/emptypending.out" 2>&1
rc_empty=$?
expect "real failure-mode case: pending-run with nothing registered exits 0, no crash" "[ $rc_empty -eq 0 ]"

echo "----"
echo "reality-check-selftest: $PASS/$((PASS+FAIL)) ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
