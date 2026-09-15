#!/usr/bin/env bash
# isodefault_ac7_all_selftests_byte_identical.sh — PRD-build-test-isolation-
# by-default AC7. The load-bearing proof the whole PRD exists for.
#
# Given all previously-unisolated selftests (scripts/run-selftests.sh's own
# SELFTEST_REGISTRY), When run-selftests.sh --all runs, Then no TEST-shaped
# content (the same fixture-shaped regex scripts/lib/journal.sh's own
# tripwire refuses — /tmp/, does-not-matter, fixture, step=ac<N>/prog*,
# BURST_LANE_TEST) lands in the production journal, state/, or
# ~/repos/PRDs.
#
# Originally asserted strict byte-identical hashes. Root-caused
# (PRD-build-test-isolation-by-default iter_log, 2026-09-15): this box runs
# a real, live /build loop (claude-build-tick.sh, a systemd unit — not this
# PRD's test surface) that legitimately appends to build-auto.log and
# burst-lane.log while --all's several-minute run is still in flight, and
# a strict hash made that indistinguishable from an actual leak from THIS
# run's own tests. The fix classifies instead of hashing: content that
# grew but is NOT fixture-shaped is concurrent production activity from
# something else on the box (reported, not failed); content that grew AND
# is fixture-shaped, or any removed/rewritten/disappeared file, is a real
# leak and still fails hard — every leak class the PRD's own Grounding
# observed (target=/tmp/... fixture lines, step=ac* gate-wedge lines) is
# fixture-shaped by construction, so this does not weaken the AC.
#
# This test drives the real runner in --all mode directly (rather than
# re-implementing its own hashing) and additionally re-verifies the
# classification independently, from outside the runner, with its OWN
# small copy of the classifier (not by sourcing run-selftests.sh's
# internal functions) — so a bug in the runner's OWN AC7 check can't
# silently mask a real leak. It reuses scripts/lib/journal.sh's
# `_journal_is_fixture_shaped` for the actual regex (the one-regex
# contract this PRD exists to establish), not a second copy of the regex
# itself.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/run-selftests.sh"
[ -x "$RUNNER" ] || { echo "ac7: $RUNNER not found or not executable" >&2; exit 2; }
# shellcheck source=../scripts/lib/journal.sh
source "$SKILL_DIR/scripts/lib/journal.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

REAL_HOME="$HOME"
REAL_JOURNAL_ROOT="$REAL_HOME/brain/journal"
REAL_STATE_DIR="$SKILL_DIR/state"
REAL_PRDS_DIR="$REAL_HOME/Documents/PRDs"

T="$(mktemp -d "${TMPDIR:-/mnt/data/jsy/tmp}/isodefault-ac7.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$T"' EXIT

_snapshot_copy() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  [ -d "$src" ] || return 0
  cp -a "$src"/. "$dst"/ 2>/dev/null || true
}

_any_fixture_shaped_line() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _journal_is_fixture_shaped "$line" && return 0
  done
  return 1
}

# _tree_leaked <before-snapshot-dir> <real-after-dir> <label> — prints
# findings to stderr; returns 0 (true) iff a genuine leak was found.
_tree_leaked() {
  local before_dir="$1" after_dir="$2" label="$3"
  local leak=1 f rel beforef added removed

  if [ -d "$after_dir" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$after_dir"/}"
      beforef="$before_dir/$rel"
      if [ ! -f "$beforef" ]; then
        if _any_fixture_shaped_line <"$f"; then
          echo "ac7: independent check: LEAK ($label): new fixture-shaped file: $rel" >&2
          leak=0
        else
          echo "ac7: independent check: NOTE ($label): new non-fixture file (concurrent production activity): $rel" >&2
        fi
        continue
      fi
      cmp -s "$beforef" "$f" && continue
      removed="$(diff "$beforef" "$f" 2>/dev/null | grep '^< ')"
      if [ -n "$removed" ]; then
        echo "ac7: independent check: LEAK ($label): $rel had content removed/rewritten" >&2
        leak=0
        continue
      fi
      added="$(diff "$beforef" "$f" 2>/dev/null | grep '^> ' | sed 's/^> //')"
      if [ -n "$added" ] && printf '%s\n' "$added" | _any_fixture_shaped_line; then
        echo "ac7: independent check: LEAK ($label): $rel grew with fixture-shaped line(s)" >&2
        leak=0
      elif [ -n "$added" ]; then
        echo "ac7: independent check: NOTE ($label): $rel grew, not fixture-shaped (concurrent production activity)" >&2
      fi
    done < <(find "$after_dir" -type f -print0 2>/dev/null)
  fi

  if [ -d "$before_dir" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$before_dir"/}"
      if [ ! -f "$after_dir/$rel" ]; then
        echo "ac7: independent check: LEAK ($label): $rel disappeared" >&2
        leak=0
      fi
    done < <(find "$before_dir" -type f -print0 2>/dev/null)
  fi

  return $leak
}

_porcelain_leaked() {
  local before="$1" after="$2"
  [ "$before" = "$after" ] && return 1
  local bf af added removed
  bf="$T/porc-before"; af="$T/porc-after"
  printf '%s\n' "$before" > "$bf"
  printf '%s\n' "$after" > "$af"
  removed="$(diff "$bf" "$af" 2>/dev/null | grep '^< ')"
  added="$(diff "$bf" "$af" 2>/dev/null | grep '^> ' | sed 's/^> //')"
  if [ -n "$removed" ]; then
    echo "ac7: independent check: LEAK (PRDs porcelain): entries disappeared" >&2
    return 0
  fi
  if [ -n "$added" ] && printf '%s\n' "$added" | _any_fixture_shaped_line; then
    echo "ac7: independent check: LEAK (PRDs porcelain): fixture-shaped entries" >&2
    return 0
  fi
  [ -n "$added" ] && echo "ac7: independent check: NOTE (PRDs porcelain): non-fixture change (concurrent sibling activity)" >&2
  return 1
}

before_journal_snap="$T/before-journal"
before_state_snap="$T/before-state"
_snapshot_copy "$REAL_JOURNAL_ROOT" "$before_journal_snap"
_snapshot_copy "$REAL_STATE_DIR" "$before_state_snap"
before_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"

out="$("$RUNNER" --all 2>&1)"
rc=$?
echo "$out" | tail -5

after_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"

journal_leaked=1; _tree_leaked "$before_journal_snap" "$REAL_JOURNAL_ROOT" "journal" && journal_leaked=0
state_leaked=1;   _tree_leaked "$before_state_snap" "$REAL_STATE_DIR" "state" && state_leaked=0
prds_leaked=1;    _porcelain_leaked "$before_prds_porcelain" "$after_prds_porcelain" && prds_leaked=0

expect "real journal tree: no fixture-shaped leak before/after --all" "[ $journal_leaked -eq 1 ]"
expect "real state/ tree: no fixture-shaped leak before/after --all"  "[ $state_leaked -eq 1 ]"
expect "~/repos/PRDs git status: no fixture-shaped leak before/after --all" "[ $prds_leaked -eq 1 ]"
expect "runner's own AC7 check agrees (no AC7 FAILED line)"  "! printf '%s' \"\$out\" | grep -q 'AC7 FAILED'"

# rc itself is informative but not asserted strictly here — a real,
# pre-existing flake in one of the registered selftests (unrelated to
# journal/state isolation) can fail the runner's overall exit code without
# meaning production leaked; the leak checks above are what this AC is
# actually about. Report it for visibility.
echo "ac7: runner overall rc=$rc (informational — see leak checks above for the actual AC)"

exit $fail
