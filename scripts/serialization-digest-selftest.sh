#!/usr/bin/env bash
# serialization-digest-selftest.sh — PRD-build-gate-before-land
# requirement 7 (P1) / AC12: select-guard.sh journals same-target
# admit/block decisions, and serialization-digest.sh reads that journal
# (plus extend-gate.sh's and worktree-extend.sh's own existing lines)
# into one `serialization: ...` summary line.
#
#   Part 1 — select-guard.sh: a same-target-cap block/admit each write
#     exactly one journal line, with the fields serialization-digest.sh
#     depends on (target=, cap=, source=).
#   Part 2 — serialization-digest.sh: a hand-built journal fixture with a
#     KNOWN mix of select/gate/land lines produces the exact expected
#     counts (fast, deterministic — no need to re-derive the fixture from
#     real gate/land runs; those journal LINE SHAPES are already exercised
#     for real by extend-gate-scope-selftest.sh, gate-verdict-tree-cache-
#     selftest.sh, and worktree-extend-gated-land-selftest.sh).
#   Part 3 — a missing/empty journal reads as all-zero, never an error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELECT_GUARD="$HERE/select-guard.sh"
DIGEST="$HERE/serialization-digest.sh"
[ -x "$SELECT_GUARD" ] || { echo "selftest: $SELECT_GUARD not executable" >&2; exit 2; }
[ -x "$DIGEST" ] || { echo "selftest: $DIGEST not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/serialization-digest-selftest.XXXXXX")"
trap '[ -n "${SERIALIZATION_DIGEST_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

# =========================================================================
# Part 1: select-guard.sh journals same-target admit/block
# =========================================================================
echo "=== Part 1: select-guard.sh same-target journal lines ==="
PRD_DIR="$T/prds"
mkdir -p "$PRD_DIR/build-queue"
cat > "$PRD_DIR/build-queue/PRD-sgd-a.md" <<'EOF'
# PRD — sgd-a
- Status: queued
- build_into: /tmp/sgd-fixture-repo
- build_target: rust-extend
EOF
JOURNAL1="$T/journal1.md"

# Cap=1 (default), one target already admitted this tick -> the second
# candidate on the same build_into is blocked.
out1="$(env SELECT_GUARD_JOURNAL="$JOURNAL1" "$SELECT_GUARD" sgd-a "$(hostname)" "$PRD_DIR" 0 "/tmp/sgd-fixture-repo" 2>&1)"
rc1=$?
expect "Part1: select-guard exits 1 (blocked by same-target cap)" "[ $rc1 -eq 1 ]"
blocked_line="$(grep 'same-target-blocked' "$JOURNAL1" 2>/dev/null || true)"
expect "Part1: a same-target-blocked journal line was written" "[ -n \"$blocked_line\" ]"
expect "Part1: blocked line names the target and cap" \
  "printf '%s' \"$blocked_line\" | grep -q 'target=/tmp/sgd-fixture-repo cap=1'"

# No prior admissions this tick -> admitted (same-target check passes;
# lane-predicate itself will likely then skip on a nonexistent repo, but
# that happens AFTER the same-target journal write we're testing).
JOURNAL2="$T/journal2.md"
env SELECT_GUARD_JOURNAL="$JOURNAL2" "$SELECT_GUARD" sgd-a "$(hostname)" "$PRD_DIR" 0 "" >/dev/null 2>&1 || true
admit_line="$(grep 'same-target-admit' "$JOURNAL2" 2>/dev/null || true)"
expect "Part1: a same-target-admit journal line was written" "[ -n \"$admit_line\" ]"

# =========================================================================
# Part 2: serialization-digest.sh reads a fixture journal
# =========================================================================
echo "=== Part 2: serialization-digest.sh fixture journal ==="
FIXTURE="$T/fixture-journal.md"
cat > "$FIXTURE" <<'EOF'
2026-09-14T10:00:00Z  select  prdA  same-target-blocked  (target=/repo/x cap=1 source=local admitted_this_tick=1)
2026-09-14T10:00:05Z  select  prdB  same-target-blocked  (target=/repo/x cap=1 source=local admitted_this_tick=1)
2026-09-14T10:00:10Z  select  prdC  same-target-admit  (target=/repo/y cap=1 source=local admitted_this_tick=1)
2026-09-14T10:05:00Z  gate  repo-x  block  (scope=branch slug=prdA head=aaa base=bbb gate: no-summary-line wall=10s lock_wait=0s cargo=burst:0/local:1)
2026-09-14T10:06:00Z  gate  repo-x  pass  (scope=branch slug=prdB head=ccc base=ddd gate: no-summary-line wall=12s lock_wait=0s cargo=burst:0/local:1)
2026-09-14T10:07:00Z  gate  repo-x  pass  (head=eee base=fff gate: no-summary-line wall=200s lock_wait=0s cargo=burst:0/local:1)
2026-09-14T10:08:00Z  gate  repo-x  pass  (cached tree=abc123 from=branch slug=prdB)
2026-09-14T10:08:05Z  gate  route-mismatch  (intended=burst burst=0 local=1 cause=shim-not-first)
2026-09-14T10:08:10Z  gate  repo-x  record-baseline  (head=eee base=fff gate: no-summary-line wall=1s lock_wait=0s cargo=burst:0/local:1)
2026-09-14T10:09:00Z  land  prdB  (gated_at=ddd main=ddd lock_hold=3s)
2026-09-14T10:10:00Z  land  prdC  (gated_at=fff main=fff lock_hold=27s)
2026-09-14T10:11:00Z  land  prdD  (gated_at=xyz main=xyz lock_hold=9s)
EOF
out2="$("$DIGEST" "$FIXTURE")"
rc2=$?
echo "  $out2"
expect "Part2: digest exits 0" "[ $rc2 -eq 0 ]"
expect "Part2: waits=2 (two same-target-blocked lines)" "printf '%s' \"$out2\" | grep -q 'waits=2 '"
expect "Part2: land_lock_hold_max=27s (max of 3/27/9)" "printf '%s' \"$out2\" | grep -q 'land_lock_hold_max=27s '"
expect "Part2: gates branch=2 (two scope=branch, non-cached, real runs)" "printf '%s' \"$out2\" | grep -q 'branch=2 '"
expect "Part2: gates main=1 (one non-cached main-scope run; route-mismatch/record-baseline excluded)" "printf '%s' \"$out2\" | grep -q 'main=1 '"
expect "Part2: cached=1 (one (cached tree=...) line)" "printf '%s' \"$out2\" | grep -q 'cached=1$'"

# =========================================================================
# Part 3: missing journal -> all zero, not an error
# =========================================================================
echo "=== Part 3: missing journal file ==="
out3="$("$DIGEST" "$T/does-not-exist.md")"
rc3=$?
expect "Part3: digest exits 0 on a missing journal" "[ $rc3 -eq 0 ]"
expect "Part3: all-zero line" "[ \"$out3\" = 'serialization: same-target waits=0 land_lock_hold_max=0s gates branch=0 main=0 cached=0' ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "serialization-digest-selftest: ALL PASS"
  exit 0
else
  echo "serialization-digest-selftest: assertion(s) FAILED"
  exit 1
fi
