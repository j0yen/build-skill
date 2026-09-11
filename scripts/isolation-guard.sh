#!/usr/bin/env bash
# isolation-guard.sh — shared default-deny check for burst-lane scripts
# under BURST_LANE_TEST=1 (PRD-build-burst-selftest-isolation).
#
# Why this exists (docket burst-test-ambient-leak, open since 2026-09-10):
# isolation used to be "each test sets the env overrides it knows about" —
# BURST_LANE_STATE_DIR, BURST_LANE_JOURNAL, BURST_LANE_HCLOUD_BIN, and so
# on, one var per path, re-declared in every fixture. A script path added
# later (gate-tools.json, route.log, pull-sizes, the cost ledger) is not
# covered by an OLD test's override list, and a test that simply forgets
# one override falls through to the live default. On 2026-09-11 03:38Z the
# live lane read `no-session` for one call while an unrelated selftest ran
# on the same tree — a concurrent process almost certainly touched the real
# session.json. This file makes isolation a property of the SCRIPTS, not of
# each test's discipline: under the sentinel, a script refuses to touch a
# path that still resolves to a live root, no matter which override a test
# forgot.
#
# Usage (see burst-lane.sh / gate-burst.sh for the wiring): after a script
# resolves ALL of its own overridable paths and binaries (STATE_DIR,
# JOURNAL, ledgers, hcloud/ssh/rsync) but BEFORE the first mkdir/write,
# source this file and call:
#   isolation_guard_path "$STATE_DIR" "<script>"
#   isolation_guard_path "$JOURNAL"   "<script>"
#   isolation_guard_bin  "$(command -v "$HCLOUD" 2>/dev/null)" "<script>(hcloud)"
# Each call is a no-op (returns 0) when BURST_LANE_TEST is unset — zero
# runtime cost in production (Technical considerations, PRD requirement 2).
# A tripped guard prints `test-isolation: live path <path> under
# BURST_LANE_TEST` to stderr and exits 9 with NO side effect (called before
# any mkdir/write in every wired script), naming the offending path so the
# forgotten override is obvious from the failure alone.
#
# The one deliberate hole (requirement 3/4): isolation_refuse() below
# ALWAYS records the refusal into a fixed, known-good live journal path —
# never whatever $JOURNAL the calling script currently has in scope, since
# that variable might itself be the compromised one. This is what makes a
# leak "visible the day it appears" instead of silently joining everything
# else this file blocks. BURST_ISOLATION_LIVE_JOURNAL overrides that ONE
# path, for this file's own offline selftest coverage only — never set in
# production.

# Live roots a path must never resolve under while the sentinel is on
# (requirement 2, verbatim).
ISOLATION_LIVE_STATE_ROOT="$HOME/.claude/skills/build/state"
ISOLATION_LIVE_JOURNAL_ROOT="$HOME/brain/journal"
ISOLATION_LIVE_JOURNAL_FILE="${BURST_ISOLATION_LIVE_JOURNAL:-$HOME/brain/journal/build/burst-lane.log}"

isolation_sentinel_on() { [ "${BURST_LANE_TEST:-0}" = "1" ]; }

# isolation_refuse <caller> <path> — journals the refusal to the live
# journal (Requirement 3/4), prints the operator-facing message, and exits
# 9. Never returns.
isolation_refuse() {
  local caller="${1:-unknown}" path="${2:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  mkdir -p "$(dirname "$ISOLATION_LIVE_JOURNAL_FILE")" 2>/dev/null || true
  printf '%s  isolation  refused  (caller=%s path=%s)\n' "$ts" "$caller" "$path" \
    >> "$ISOLATION_LIVE_JOURNAL_FILE" 2>/dev/null || true
  echo "test-isolation: live path $path under BURST_LANE_TEST" >&2
  exit 9
}

# isolation_guard_path <path> <caller>
# Refuses (see isolation_refuse) if <path> resolves under a live root while
# the sentinel is on. No-op otherwise, and no-op on an empty path (an
# unresolved/optional path is not this function's concern).
isolation_guard_path() {
  local path="${1:-}" caller="${2:-unknown}"
  isolation_sentinel_on || return 0
  [ -n "$path" ] || return 0
  case "$path" in
    "$ISOLATION_LIVE_STATE_ROOT"|"$ISOLATION_LIVE_STATE_ROOT"/*)
      isolation_refuse "$caller" "$path" ;;
    "$ISOLATION_LIVE_JOURNAL_ROOT"|"$ISOLATION_LIVE_JOURNAL_ROOT"/*)
      isolation_refuse "$caller" "$path" ;;
  esac
  return 0
}

# isolation_guard_bin <resolved-path-or-empty> <caller>
# Refuses if the ALREADY-RESOLVED path of a hcloud/ssh/rsync binary sits
# under a real system (or this machine's real user-local) bin directory
# while the sentinel is on — a fake fixture never lives there, so a hit
# here means the fake wasn't on PATH for this call (the exact 2026-09-09
# 19:34Z / burst-test-ambient-leak failure class: "the fake ssh is not on
# PATH for that call"). Pass the output of `command -v "$BIN" 2>/dev/null`
# (empty if not found at all, which is a no-op here — a missing binary is a
# different failure). $HOME/.local/bin and $HOME/.cargo/bin are included
# because that is where THIS machine's real hcloud/cargo-installed tools
# actually live (verified: /home/jsy/.local/bin/hcloud) — /usr/bin alone
# would have missed it.
isolation_guard_bin() {
  local resolved="${1:-}" caller="${2:-unknown}"
  isolation_sentinel_on || return 0
  [ -n "$resolved" ] || return 0
  case "$resolved" in
    /usr/bin/*|/bin/*|/usr/local/bin/*|/sbin/*|/usr/sbin/*|/opt/homebrew/bin/*|"$HOME/.local/bin"/*|"$HOME/.cargo/bin"/*)
      isolation_refuse "$caller" "$resolved" ;;
  esac
  return 0
}
