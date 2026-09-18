# lib/loop-line.sh — PRD-buildloop-tick-outcome-liveness R6: the shared
# "LOOP: last_ok=<s> streak_failed=<n>  [<age_note>]" line
# handoff-header.sh and gates-banner.sh both print, derived from
# tick-run.sh's own R1 artifact ($TICK_OUTCOME_FILE, tick-outcome.json).
#
# Reuses lib/gate-red-age.sh's `gate_red_age_note` for the bracketed
# age/STALE rendering (its own header: "accepts any file with a ts key")
# by feeding it a synthetic one-line {"ts": "<last_ok_ts>"} temp file --
# tick-outcome.json's OWN `.ts` is the tick's write time, not the last
# SUCCESS time this line is about, so gate_red_age_note can't be pointed
# at the real file directly. `last_ok=<s>` itself is raw seconds (or
# `unknown`), matching R1/R3's own `last_ok_age`/`last_ok_ts` field
# naming rather than introducing a third age unit.
#
# Requires the caller to have already set $TICK_OUTCOME_FILE and $JQ, and
# to have sourced lib/gate-red-age.sh, before calling loop_line.
#
# loop_line [--no-age] — prints the LOOP: line to stdout, or prints
# nothing at all (caller decides whether that's worth a blank line) when
# $TICK_OUTCOME_FILE doesn't exist or jq is unavailable -- "no record
# yet" is silence here, same posture handoff-header.sh already takes for
# a missing gate-red.summary.

loop_line() {
  local no_age="${1:-}"
  [ -r "${TICK_OUTCOME_FILE:-}" ] || return 0
  [ -x "${JQ:-}" ] || return 0

  local streak_failed last_ok_ts
  streak_failed="$("$JQ" -r '.streak_failed // 0' "$TICK_OUTCOME_FILE" 2>/dev/null)"
  last_ok_ts="$("$JQ" -r '.last_ok_ts // empty' "$TICK_OUTCOME_FILE" 2>/dev/null)"
  case "$streak_failed" in ''|*[!0-9]*) streak_failed=0 ;; esac

  # GATE_RED_NOW (lib/gate-red-age.sh's own test-only "now" override) is
  # honored here too, for the same reason gate_red_age_s honors it: a
  # fixture pinning "now" needs BOTH this raw seconds figure and the
  # bracketed note below to agree.
  local now_epoch="${GATE_RED_NOW:-$(date -u +%s)}"
  local age_s="unknown"
  if [ -n "$last_ok_ts" ]; then
    local epoch
    epoch="$(date -u -d "$last_ok_ts" +%s 2>/dev/null)"
    [ -n "$epoch" ] && age_s=$(( now_epoch - epoch ))
  fi

  if [ "$no_age" = "--no-age" ]; then
    echo "LOOP: last_ok=${age_s} streak_failed=${streak_failed}"
    return 0
  fi

  local note="no-data"
  if [ -n "$last_ok_ts" ]; then
    local synth
    # Must be *.json (not a bare mktemp name) so gate_red_written_ts takes
    # its jq `.ts` path rather than treating this as a `.summary`-shaped
    # file and reading line 1's first token literally (which would read
    # "{" off jq's default pretty-printed output and fall back to the
    # temp file's own just-created mtime -- silently reporting "age 0m"
    # instead of the real last-success age).
    synth="$(mktemp --suffix=.json 2>/dev/null)" && {
      "$JQ" -nc --arg ts "$last_ok_ts" '{ts:$ts}' > "$synth" 2>/dev/null
      note="$(gate_red_age_note "$synth")"
      rm -f "$synth" 2>/dev/null
    }
  fi
  echo "LOOP: last_ok=${age_s} streak_failed=${streak_failed}  [${note}]"
}
