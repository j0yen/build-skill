# lib/gate-red-age.sh — shared gate-red state age helpers.
#
# gate-red.summary (`<ts> <one-line summary>`) and gate-red.json (`.ts`)
# both carry the wall-clock instant gate-red-summary.sh WROTE them, but
# every human-facing renderer of that state (gates-banner.sh,
# handoff-header.sh, gate-red-tick.sh's ALARM/resolve text) used to print
# the summary bare, with the write-ts stripped or buried in a field a
# human never looks at. Joe read a red as current for 2h on 2026-09-17
# after it had already resolved (see PRD-build-gate-red-render-age).
# This lib gives every renderer a one-line way to say how old the state
# it's showing is, and to say STALE past a threshold, instead of each
# renderer re-deriving that logic (and re-making the same mistake).
#
# Sourced, no side effects on source (no `set -e`/`set -u` changes here —
# a caller's own `set -uo pipefail` stays in force; every function below
# is written to tolerate that).
#
# Functions:
#   gate_red_written_ts <file>
#     Prints the ISO-8601 Z timestamp the state in <file> was written at,
#     or nothing (and a non-zero return) if it can't be determined.
#     `.summary`-shaped files (anything not ending `.json`): the first
#     whitespace-separated field of line 1, if it parses as ISO-8601 Z.
#     `.json` files: the `.ts` field via jq. Missing file, unparsable
#     content, or (for .json) no jq on $PATH -> empty/1.
#
#   gate_red_age_s <file> [now_epoch]
#     Prints the number of seconds between `now_epoch` (or $GATE_RED_NOW,
#     or `date +%s`) and <file>'s written ts. Falls back to the file's
#     own mtime when no ts parses. Prints -1 (and does not error) when
#     <file> doesn't exist.
#
#   gate_red_age_note <file> [now_epoch]
#     Prints `age <N>m` when the age is at or under the staleness
#     threshold (env GATE_RED_STALE_AFTER_S, default 900 = 15min), else
#     `STALE <H>h<M>m` (or `STALE <N>m` under an hour). Prints `no-data`
#     when <file> is missing (age -1).
#
#   gate_red_is_stale <file> [now_epoch]
#     Exit 0 (true) when the state is stale OR missing; exit 1 otherwise.
#
# Env:
#   GATE_RED_NOW             epoch seconds to treat as "now" (tests only;
#                             an explicit `now_epoch` arg wins over this).
#   GATE_RED_STALE_AFTER_S   staleness threshold in seconds (default 900).

GATE_RED_AGE_STALE_AFTER_S_DEFAULT=900

# gate_red_written_ts <file>
gate_red_written_ts() {
  local file="${1:-}"
  [ -n "$file" ] && [ -e "$file" ] || return 1
  local ts
  case "$file" in
    *.json)
      command -v jq >/dev/null 2>&1 || return 1
      ts="$(jq -r '.ts // empty' "$file" 2>/dev/null)"
      ;;
    *)
      local line
      line="$(sed -n '1p' "$file" 2>/dev/null)"
      ts="${line%%[[:space:]]*}"
      ;;
  esac
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z)
      printf '%s\n' "$ts"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# gate_red_age_s <file> [now_epoch]
gate_red_age_s() {
  local file="${1:-}" now="${2:-${GATE_RED_NOW:-}}"
  [ -n "$now" ] || now="$(date -u +%s)"
  [ -n "$file" ] && [ -e "$file" ] || { echo -1; return 0; }

  local ts epoch=""
  ts="$(gate_red_written_ts "$file" 2>/dev/null)"
  if [ -n "$ts" ]; then
    epoch="$(date -u -d "$ts" +%s 2>/dev/null)"
  fi
  if [ -z "$epoch" ]; then
    epoch="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)"
  fi
  if [ -z "$epoch" ]; then
    echo -1
    return 0
  fi
  echo $(( now - epoch ))
}

# gate_red_age_note <file> [now_epoch]
gate_red_age_note() {
  local file="${1:-}" now="${2:-}"
  local threshold="${GATE_RED_STALE_AFTER_S:-$GATE_RED_AGE_STALE_AFTER_S_DEFAULT}"
  local age
  age="$(gate_red_age_s "$file" "$now")"
  if [ "$age" -lt 0 ]; then
    echo "no-data"
    return 0
  fi
  if [ "$age" -le "$threshold" ]; then
    echo "age $(( age / 60 ))m"
    return 0
  fi
  local h m
  h=$(( age / 3600 ))
  m=$(( (age % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then
    echo "STALE ${h}h${m}m"
  else
    echo "STALE ${m}m"
  fi
}

# gate_red_is_stale <file> [now_epoch]
gate_red_is_stale() {
  local file="${1:-}" now="${2:-}"
  local threshold="${GATE_RED_STALE_AFTER_S:-$GATE_RED_AGE_STALE_AFTER_S_DEFAULT}"
  local age
  age="$(gate_red_age_s "$file" "$now")"
  [ "$age" -lt 0 ] && return 0
  [ "$age" -gt "$threshold" ]
}
