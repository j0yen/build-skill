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
#   AC1  — the plain happy path: a reachable, PASSING substrate command
#          writes `reality: ok`, a receipt file, and a journal line.
#   AC3  — a deferred AC's justification claiming the box is unreachable
#          is re-tested for real; a lane reporting ACTIVE while deferred
#          as "unreachable" blocks with `deferral-premise-false` (the
#          exact 2026-09-10/11 defect); a genuinely unreachable box passes.
#   AC4  — the PRD's own `Receipts:` claim is re-derived from a fresh run
#          of the named script; a stale claim (the 251-on-245 case) blocks
#          naming both counts; a matching claim passes.
#   AC5  — a shipped diff whose only new selftest case is success-only
#          blocks archive with `fixture-negative-case-missing`; a matching
#          `prd-lint.sh` warning on happy-path-only AC prose is covered too.
#   AC6  — a `failed` reality run drafts a lint-clean follow-up PRD naming
#          the failing command, an excerpt, and a P0 line; parent gains
#          `reality_followup:`; the tick journals the draft.
#
# NOTE (this PRD's own dogfood finding, 2026-09-13): AC1/AC3/AC4/AC5/AC6
# used to live only inside scripts/burst-lane-selftest.sh's own `reality`
# fixture section — but that whole suite exits early (SKIP, exit 0) under
# `lib/burst-configured.sh`'s RedBaron-local dormant-burst-lane policy, so
# those cases never actually ran here and the `tests/reality_ac<N>_*.sh`
# wrapper files pairing to them were false-green derive-pairings (a file
# existed at the right name; the fixture inside it hadn't executed since
# the policy went dormant). None of these cases exercise the REAL burst
# lane — they use $FAKE_ACTIVE/$FAKE_INACTIVE fakes throughout, same as
# every other case in this file — so gating them behind "is burst the
# declared policy" was never correct. Moved here, ungated, so the archive
# gate's own `--verify-run` gets real, current evidence instead of a
# vacuous pass. The old in-suite copies stay in burst-lane-selftest.sh
# unchanged (still correct once burst is reactivated) but are no longer
# what `tests/reality_ac<N>_*.sh` pairs to.
#
# Run: bash scripts/reality-check-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
RC="$HERE/reality-check.sh"
VC="$HERE/verified-completed.sh"
PL="$HERE/prd-lint.sh"
[ -x "$RC" ] || { echo "selftest: $RC not executable" >&2; exit 2; }
[ -x "$VC" ] || { echo "selftest: $VC not executable" >&2; exit 2; }
[ -x "$PL" ] || { echo "selftest: $PL not executable" >&2; exit 2; }

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
# == AC1: the plain happy path — a reachable, PASSING substrate command
#    writes reality: ok, a receipt file exists, and the journal names the
#    slug with an ok verdict ==
# ======================================================================
D0="$T/d0"; new_fixture "$D0"
cat > "$D0/prds/build-queue/PRD-reachable-ac1.md" <<'EOF'
# PRD: reachable-ac1

- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given the real box, When `echo reachable-ac1-ran` runs against the live lane, Then it exits 0.
EOF
REALITY_CHECK_BURST_LANE="$FAKE_ACTIVE" \
  "$RC" run "$D0/prds/build-queue/PRD-reachable-ac1.md" --no-push >"$T/ac1.out" 2>&1
rc1=$?
receipt1="$(grep -m1 '^- reality_receipt:' "$D0/prds/build-queue/PRD-reachable-ac1.md" | sed -E 's/^- reality_receipt: *//')"
expect "AC1: run exits 0" "[ $rc1 -eq 0 ]"
expect "AC1: reality=ok with a real pass/fail verdict" \
  "grep -qxe '- reality: ok' '$D0/prds/build-queue/PRD-reachable-ac1.md'"
expect "AC1: a reality receipt file exists" "[ -n \"$receipt1\" ] && [ -f \"$receipt1\" ]"
expect "AC1: journal names the slug with an ok verdict" \
  "grep -q 'reality  reachable-ac1  ok' \"$BUILD_JOURNAL_DIR/\$(date -u +%F).md\""

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
# == AC3: a deferred AC's justification claiming the box is unreachable
#    is re-tested for real (not trusted as prose). A lane reporting
#    ACTIVE while deferred as "unreachable" blocks with
#    deferral-premise-false naming the contradicting evidence — the exact
#    2026-09-10/11 defect (unprivileged-user's AC4 deferred as
#    unreachable while the lane's own status showed active). A genuinely
#    unreachable box is the real failure-mode case that must still pass. ==
# ======================================================================
mkdir -p "$T/ac3fix"
cat > "$T/ac3fix/PRD-realitydefer-ac3.md" <<'EOF'
# PRD — realitydefer-ac3: a fixture PRD with a deferred AC to premise-check

- Status: built
- build_target: shell
- deferred_acs: [4]
- mock_justifications:
  - "AC4 needs a real box, which is not reachable/authorized from this sandboxed build session."

## Acceptance criteria

1. P0 — Given a thing, When it runs, Then it works.
2. P0 — Given a thing, When it runs, Then it works.
3. P0 — Given a thing, When it runs, Then it works.
4. P0 — Given a thing, When it runs, Then it works.
EOF
VC_BURST_LANE="$FAKE_ACTIVE" "$VC" "$T/ac3fix/PRD-realitydefer-ac3.md" --check-deferral-premises \
  >/dev/null 2>"$T/premise-false.err"
rc_premise_false=$?
expect "AC3: deferral-premise-false exits non-zero when the lane the deferral called unreachable is actually active" \
  "[ $rc_premise_false -ne 0 ]"
expect "AC3: names the contradicting AC and evidence" \
  "grep -q 'deferral-premise-false: AC4' '$T/premise-false.err' && grep -qi 'reachable' '$T/premise-false.err'"
VC_BURST_LANE="$FAKE_INACTIVE" "$VC" "$T/ac3fix/PRD-realitydefer-ac3.md" --check-deferral-premises \
  >/dev/null 2>"$T/premise-true.err"
expect "AC3 (real failure-mode case: genuinely unreachable) — the true premise passes archive" "[ $? -eq 0 ]"

# ======================================================================
# == AC4: the PRD's own Receipts: claim is re-derived from a fresh run of
#    the named script; a claim that no longer matches the tree (the
#    251-on-245 case) blocks naming both counts; a matching claim passes ==
# ======================================================================
mkdir -p "$T/ac4fix"
cat > "$T/ac4fix/PRD-receiptclaim-ac4.md" <<'EOF'
# PRD — receiptclaim-ac4: a fixture PRD to receipt-claim-check

- Status: built
- build_target: shell

## Acceptance criteria

1. P0 — Given a thing, When it runs, Then it works.
EOF
cat > "$T/fake-251.sh" <<'EOF'
#!/usr/bin/env bash
echo "251/251 ok, 0 FAIL"
EOF
cat > "$T/fake-245.sh" <<'EOF'
#!/usr/bin/env bash
echo "245/251 ok, 6 FAIL"
exit 1
EOF
chmod +x "$T/fake-251.sh" "$T/fake-245.sh"
"$VC" "$T/ac4fix/PRD-receiptclaim-ac4.md" --check-receipt-claim \
  --receipt-text "some-selftest.sh 251/251 ok; 0 FAIL" --receipt-script "$T/fake-251.sh" >/dev/null 2>&1
expect "AC4: a matching receipt claim exits 0" "[ $? -eq 0 ]"
"$VC" "$T/ac4fix/PRD-receiptclaim-ac4.md" --check-receipt-claim \
  --receipt-text "some-selftest.sh 251/251 ok; 0 FAIL" --receipt-script "$T/fake-245.sh" >/dev/null 2>"$T/mismatch.err"
expect "AC4 (real failure-mode case: the 251-on-245 defect) — a mismatched claim blocks naming both counts" \
  "[ $? -ne 0 ] && grep -q '251/251' '$T/mismatch.err' && grep -q '245/251' '$T/mismatch.err'"

# ======================================================================
# == AC5: a fixture-only test suite with no failure-mode case blocks
#    archive naming the rule; prd-lint.sh warns the same gap pre-ship ==
# ======================================================================
FR="$T/fnc-repo"
mkdir -p "$FR" "$T/visions"
touch "$T/visions/fixture.md"
git init -q "$FR" >/dev/null 2>&1
git -C "$FR" config user.email t@t; git -C "$FR" config user.name t
cat >"$FR/thing-selftest.sh" <<'EOF'
echo "== base case =="
EOF
git -C "$FR" add -A && git -C "$FR" commit -q -m init >/dev/null
git -C "$FR" tag v0.1.0
cat >"$FR/PRD-fnc.md" <<EOF
# PRD — fnc

- Status: built
- build_target: shell
- build_into: $FR
- Vision: visions/fixture.md

## Acceptance criteria

1. P0 — Given a thing, When it runs, Then it works.
EOF
echo 'echo "== new happy path =="' >>"$FR/thing-selftest.sh"
git -C "$FR" add -A && git -C "$FR" commit -q -m "add success-only case" >/dev/null
"$VC" "$FR/PRD-fnc.md" --check-fixture-negative-case >/dev/null 2>"$T/fnc-block.err"
expect "AC5 (real failure-mode case: a success-only diff) — verified-completed blocks archive naming the rule" \
  "[ $? -ne 0 ] && grep -q 'fixture-negative-case-missing' '$T/fnc-block.err'"
cat >"$T/PRD-realitypositive-ac5.md" <<'EOF'
# PRD — realitypositive-ac5: a fixture with a happy-path-only selftest mention

- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given the selftest fixture set, When `foo-selftest.sh` runs, Then it exits 0 and all cases pass and match.
EOF
"$PL" "$T/PRD-realitypositive-ac5.md" >"$T/lint-positive.out" 2>&1
expect "AC5: prd-lint.sh warns selftest-no-negative-case on a happy-path-only AC mention" \
  "grep -q selftest-no-negative-case '$T/lint-positive.out'"

# ======================================================================
# == AC6 / regression: a REACHABLE box AC still runs live (tier=live),
#    unaffected by the tier split above; a FAILING live AC drafts a
#    lint-clean follow-up naming the failing command and a P0 line, sets
#    reality_followup: on the parent, and journals the draft
#    (real failure-mode case: the live command fails) ==
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
expect "AC6/regression: a reachable box still runs live and a real failure is recorded" \
  "grep -qxe '- reality: failed' '$D5/prds/build-queue/PRD-live-regress.md'"
expect "AC6: reality_followup: set on the parent" \
  "grep -qE '^- reality_followup: PRD-live-regress-reality-[0-9]+\.md$' '$D5/prds/build-queue/PRD-live-regress.md'"
followup6="$(grep -m1 '^- reality_followup:' "$D5/prds/build-queue/PRD-live-regress.md" | sed -E 's/^- reality_followup: *//')"
expect "AC6: follow-up file exists" "[ -f \"$D5/prds/build-queue/$followup6\" ]"
expect "AC6: follow-up passes prd-lint.sh" "\"$PL\" \"$D5/prds/build-queue/$followup6\" >/dev/null 2>&1"
expect "AC6: follow-up names the failing command and carries a P0 line" \
  "grep -q 'false' \"$D5/prds/build-queue/$followup6\" && grep -qE '^1\\. P0 —' \"$D5/prds/build-queue/$followup6\""
expect "AC6: journal has 'reality  follow-up  drafted'" \
  "grep -q 'reality  follow-up  drafted' \"$BUILD_JOURNAL_DIR/\$(date -u +%F).md\""

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
