#!/usr/bin/env bash
# gates-banner.sh — SessionStart hook, R5 of PRD-build-gate-red-alarm-
# invariant. Installed FIRST in settings.json's SessionStart hooks list
# (ahead of token-ledger-banner.sh / repo-health-banner.sh) — the whole
# point of this PRD is that a red gate is the first thing a Claude session
# sees, not something it has to be asked about (2026-09-16: three status
# reports called a 12-tick-red loop "working" because nothing on the first
# screen said otherwise).
#
# Prints, in order:
#   0. `LOOP: last_ok=<s> streak_failed=<n>  [<age_note>]`
#      (PRD-buildloop-tick-outcome-liveness R6, via lib/loop-line.sh) from
#      state/tick-outcome.json — always local, printed even when the
#      gate-red data below is unreachable (they're independent claims).
#      Silent (no line) if that record doesn't exist yet.
#   1. the current gate-red summary line (from gate-red-summary.sh's own
#      state/gate-red.summary, read locally on RedBaron, over ssh with a
#      4s connect timeout elsewhere, cached 10 min in
#      ~/.cache/gate-red.summary so a burst of session starts elsewhere
#      doesn't open an ssh connection per session);
#   2. `PRDs shipped last 24h: <n>` (scripts/shipped-count.sh, same
#      local/remote/cache path, one ssh round trip combined with #1);
#   3. when red > 0, the fixed sentence `RED GATES PRESENT — lead every
#      status with this.` (goal 3 — a Claude session reading this must
#      lead its answer with it, not bury it).
#
# Fail-open, same posture as decisions-banner.sh/repo-health-banner.sh:
# an unreachable RedBaron (no fresh cache, ssh fails) prints exactly
# `GATES: unknown (redbaron unreachable)` and exits 0 within a few
# seconds — never blocks a session start.
#
# Env (testing/override):
#   GATES_BANNER_HOSTNAME       override `hostname` (is-this-RedBaron check)
#   GATES_BANNER_REDBARON_HOST  ssh target when not on RedBaron (default: redbaron)
#   GATES_BANNER_SSH_TIMEOUT    ssh -o ConnectTimeout seconds (default: 4)
#   GATES_BANNER_CACHE          override ~/.cache/gate-red.summary path
#   GATES_BANNER_CACHE_TTL      cache freshness window, seconds (default: 600)
#   GATES_BANNER_SSH_BIN        override the `ssh` binary (fake ssh in tests)
#   GATES_BANNER_NO_AGE         set (any value) to suppress the age/STALE
#                                suffix and STALE line below (and the new
#                                LOOP: line's own bracketed age note) — for
#                                a machine caller (day-ledger.sh) that
#                                parses this script's own summary line
#                                back apart (green=/red=/red_slugs:) and
#                                would have the age note's tokens land in
#                                its red_slugs split otherwise.
#
# gate-red-age.sh's note/threshold env (GATE_RED_NOW, GATE_RED_STALE_AFTER_S)
# apply here too -- see lib/gate-red-age.sh.
#
# Exit: always 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
SUMMARY_FILE="${GATE_RED_SUMMARY_FILE:-$STATE_DIR/gate-red.summary}"
TICK_OUTCOME_FILE="${TICK_OUTCOME_FILE:-$STATE_DIR/tick-outcome.json}"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
# shellcheck source=lib/gate-red-age.sh
source "$HERE/lib/gate-red-age.sh"
# shellcheck source=lib/loop-line.sh
source "$HERE/lib/loop-line.sh"

HOSTNAME_VAL="${GATES_BANNER_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
REDBARON_HOST="${GATES_BANNER_REDBARON_HOST:-redbaron}"
SSH_TIMEOUT="${GATES_BANNER_SSH_TIMEOUT:-4}"
CACHE_FILE="${GATES_BANNER_CACHE:-$HOME/.cache/gate-red.summary}"
CACHE_TTL="${GATES_BANNER_CACHE_TTL:-600}"
SSH_BIN="${GATES_BANNER_SSH_BIN:-ssh}"
SHIPPED_SCRIPT_REL=".claude/skills/build/scripts/shipped-count.sh"

is_redbaron() {
  [ "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" = "redbaron" ]
}

cache_fresh() {
  [ -f "$CACHE_FILE" ] || return 1
  local age now mtime
  now="$(date +%s)"
  mtime="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)"
  age=$(( now - mtime ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL" ]
}

summary_line=""
shipped_n=""
age_file=""

landing_pending_lines=""

if is_redbaron "$HOSTNAME_VAL"; then
  if [ -r "$SUMMARY_FILE" ]; then
    summary_line="$(sed -n '1p' "$SUMMARY_FILE" | cut -d' ' -f2-)"
    age_file="$SUMMARY_FILE"
  fi
  shipped_n="$("$HERE/shipped-count.sh" 2>/dev/null || echo 0)"
  # PRD-build-main-push-gate-pr-path requirement 9 (P1, AC12): the
  # landing-pending data only exists as real state ON the machine that
  # ran the landing (RedBaron) -- the remote/cached branch below does not
  # yet carry it (documented scope note, not an oversight: mcphost
  # landings, this feature's only live user today, only ever happen on
  # RedBaron).
  landing_pending_lines="$("$HERE/landing-pending-summary.sh" 2>/dev/null || true)"
else
  if cache_fresh; then
    summary_line="$(sed -n '1p' "$CACHE_FILE" 2>/dev/null | cut -d' ' -f2-)"
    shipped_n="$(sed -n '2p' "$CACHE_FILE" 2>/dev/null)"
    age_file="$CACHE_FILE"
  else
    tmp="$(mktemp "${TMPDIR:-/tmp}/gates-banner-remote.XXXXXX")"
    remote_cmd="cat \$HOME/.claude/skills/build/state/gate-red.summary 2>/dev/null; echo; \$HOME/$SHIPPED_SCRIPT_REL 2>/dev/null || echo 0"
    if timeout "$((SSH_TIMEOUT + 2))" "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
         -o StrictHostKeyChecking=accept-new "$REDBARON_HOST" "$remote_cmd" > "$tmp" 2>/dev/null; then
      # $tmp's shape from $remote_cmd: line 1 = the remote summary file's
      # raw content (already `<ts> GATES(...)` on one line), line 2 = the
      # blank separator from the bare `echo`, line 3 = the shipped count.
      summary_line="$(sed -n '1p' "$tmp" | cut -d' ' -f2-)"
      shipped_n="$(sed -n '3p' "$tmp")"
      if [ -n "$summary_line" ]; then
        mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
        {
          printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$summary_line"
          printf '%s\n' "${shipped_n:-0}"
        } > "$CACHE_FILE" 2>/dev/null || true
        age_file="$CACHE_FILE"
      fi
    fi
    rm -f "$tmp"
  fi
fi

# PRD-buildloop-tick-outcome-liveness R6: printed regardless of gate-red
# reachability below -- tick-outcome.json is a separate local artifact, and
# "GATES: unknown (redbaron unreachable)" must not also silence a LOOP
# line this host can actually answer. GATES_BANNER_NO_AGE suppresses the
# bracketed age note the same way it does for the gate-red line below.
if [ -n "${GATES_BANNER_NO_AGE:-}" ]; then
  loop_line --no-age
else
  loop_line
fi

if [ -z "$summary_line" ]; then
  echo "GATES: unknown (redbaron unreachable)"
  exit 0
fi

if [ -n "${GATES_BANNER_NO_AGE:-}" ]; then
  echo "$summary_line"
else
  age_note="$(gate_red_age_note "$age_file")"
  echo "${summary_line}  [${age_note}]"
  if gate_red_is_stale "$age_file"; then
    written_ts="$(gate_red_written_ts "$age_file")"
    [ -n "$written_ts" ] || written_ts="unknown"
    echo "STALE gate-red state: written ${written_ts}, ${age_note} — do not report these counts as current"
  fi
fi
echo "PRDs shipped last 24h: ${shipped_n:-0}"
red_n="$(printf '%s' "$summary_line" | grep -oE 'red=[0-9]+' | head -1 | cut -d= -f2)"
if [ -n "$red_n" ] && [ "$red_n" -gt 0 ] 2>/dev/null; then
  echo "RED GATES PRESENT — lead every status with this."
fi

if [ -n "$landing_pending_lines" ]; then
  lp_n="$(printf '%s\n' "$landing_pending_lines" | sed -n '1p' | cut -d= -f2)"
  if [ -n "$lp_n" ] && [ "$lp_n" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$landing_pending_lines"
  fi
fi

exit 0
