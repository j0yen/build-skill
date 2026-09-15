#!/usr/bin/env bash
# serialization-digest.sh — PRD-build-gate-before-land requirement 7 (P1):
# one line per tick, computed entirely from the shared build journal, so
# the PRD's own two-day contention baseline (332s-3864s integration-lock
# holds, 1 mcphost PRD admitted per tick) can be re-measured the same way
# after this PRD ships:
#
#   serialization: same-target waits=<n> land_lock_hold_max=<s> gates branch=<n> main=<n> cached=<n>
#
# Fields, each read from journal lines other scripts in this pipeline
# already write (no new state, no new lock):
#   waits              count of select-guard.sh's `same-target-blocked`
#                       lines (requirement 5's admission cap turning away a
#                       same-target candidate this run) — journaled by
#                       select-guard.sh itself since requirement 7.
#   land_lock_hold_max  the largest `lock_hold=<s>s` across every gated
#                       `land`/`integrate` line worktree-extend.sh wrote
#                       (requirement 2) — 0 if none.
#   gates branch=<n>   extend-gate.sh `gate ... (scope=branch ...)` lines
#                       that were a REAL run (not a cache hit, not
#                       route-mismatch/record-baseline bookkeeping).
#   gates main=<n>     extend-gate.sh `gate ...` lines with no
#                       `scope=branch` — a real (non-cached) main-scope run.
#   cached=<n>         `gate ... (cached tree=...)` lines (requirement 4) —
#                       the metric the PRD's own success table targets
#                       "≥90% of lands" against.
#
# Usage: serialization-digest.sh [journal-file]
#   Defaults to today's shared journal ($HOME/brain/journal/build/<date>.md,
#   SERIALIZATION_DIGEST_JOURNAL overridable — same convention every other
#   script in this file reads/writes that journal with). A missing file is
#   not an error: every count is 0 (nothing ran yet today).
#
# Read-only: never writes, never takes a lock, never mutates the journal.
# Prints the line above to stdout and exits 0.
set -uo pipefail

journal="${1:-${SERIALIZATION_DIGEST_JOURNAL:-$HOME/brain/journal/build/$(date -u +%Y-%m-%d).md}}"

if [ ! -f "$journal" ]; then
  echo "serialization: same-target waits=0 land_lock_hold_max=0s gates branch=0 main=0 cached=0"
  exit 0
fi

waits="$(grep -cE '  select  .*  same-target-blocked  ' "$journal" 2>/dev/null || true)"
[ -n "$waits" ] || waits=0

land_lock_hold_max="$(grep -E '  land  .*lock_hold=[0-9]+s' "$journal" 2>/dev/null \
  | grep -oE 'lock_hold=[0-9]+s' | grep -oE '[0-9]+' \
  | sort -n | tail -1)"
[ -n "$land_lock_hold_max" ] || land_lock_hold_max=0

# Real gate runs only: exclude the cache-hit shortcut (requirement 4), and
# exclude the two other pseudo-lines extend-gate.sh's "  gate  " prefix
# also covers (route-mismatch is a guard event with no verdict of its own;
# record-baseline is a baseline write, not a verdict run).
real_gate_lines="$(grep -E '  gate  ' "$journal" 2>/dev/null \
  | grep -v 'route-mismatch' | grep -v '  record-baseline  ' | grep -v '(cached ' || true)"
gates_branch="$(printf '%s\n' "$real_gate_lines" | grep -cE 'scope=branch ' || true)"
[ -n "$gates_branch" ] || gates_branch=0
gates_total="$(printf '%s\n' "$real_gate_lines" | grep -cE '  gate  ' || true)"
[ -n "$gates_total" ] || gates_total=0
gates_main=$((gates_total - gates_branch))
[ "$gates_main" -lt 0 ] && gates_main=0

cached="$(grep -cE '  gate  .*\(cached tree=' "$journal" 2>/dev/null || true)"
[ -n "$cached" ] || cached=0

echo "serialization: same-target waits=$waits land_lock_hold_max=${land_lock_hold_max}s gates branch=$gates_branch main=$gates_main cached=$cached"
