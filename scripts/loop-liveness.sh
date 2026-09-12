#!/usr/bin/env bash
# loop-liveness.sh — read-only liveness check for this host's declared
# systemd --user unit set (PRD-buildloop-unit-liveness).
#
# Why: the loop's own logs carried no line about unit state, so a unit
# left inactive by a restart was invisible to every reader, human or
# agent, until someone read `systemctl` directly (2026-09-11/12:
# claude-vibeloop-measure.timer sat inactive 29h). This script is the
# read-only half of the fix — see loop-arm.sh for the operator-run
# enable+verify half.
#
# Modes:
#   (no flag)  live check: `systemctl --user is-active <unit>` per unit
#              declared for this host, print one `unit=<u> state=...`
#              line per unit, update the streak state file, then print a
#              summary — `LIVENESS ok n=<N>` (exit 0) or one
#              `LIVENESS WARN unit=<u> inactive_since=<ISO>` line per
#              currently-inactive unit (exit 1). Costs one `systemctl`
#              call per declared unit — no model call, ever.
#   --json     same live check, JSON output instead of the plain lines
#              above (P2 — a digest/consumer-friendly shape).
#   --digest   NO live check, NO systemctl calls: pure read of the streak
#              state file, printing one `LIVENESS WARN unit=<u>
#              inactive_since=<ISO>` line for every unit that has been
#              inactive for at least two consecutive (--digest-free)
#              checks in a row — the noise filter that keeps a single
#              transient blip out of the digest while still catching a
#              unit that stays down. Exit 1 if it printed anything, 0
#              otherwise. This is what a digest/rollup reader should call.
#
# A host with no lines in loop-units.txt for its name prints
# `LIVENESS unknown host=<h>` and exits 0 in every mode — no declared set
# is not an alarm (carbon, ryzen7).
#
# State file: "<unit> <first_inactive_iso> <consecutive_checks>" lines
# under $XDG_STATE_HOME/build-skill/ (default ~/.local/state/build-skill).
# An active reading deletes the unit's line entirely. Only the live-check
# modes (no flag, --json) touch this file; --digest only reads it.
#
# Env overrides (test-only hooks; production defaults unchanged):
#   LOOP_UNITS_FILE          (<skill-dir>/scripts/loop-units.txt)
#   LOOP_LIVENESS_STATE_DIR  (${XDG_STATE_HOME:-$HOME/.local/state}/build-skill)
#   LOOP_LIVENESS_STATE_FILE (<state-dir>/loop-liveness.state)
#   LOOP_LIVENESS_HOST       ($(hostname -s)) — the host block to read
#   `systemctl` itself is resolved via $PATH, not hardcoded — selftests
#   shadow it with a fake earlier on $PATH (see loop-liveness-selftest.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
UNITS_FILE="${LOOP_UNITS_FILE:-$SKILL_DIR/scripts/loop-units.txt}"
STATE_DIR="${LOOP_LIVENESS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/build-skill}"
STATE_FILE="${LOOP_LIVENESS_STATE_FILE:-$STATE_DIR/loop-liveness.state}"
HOST="${LOOP_LIVENESS_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"

mode="plain"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) mode="json"; shift ;;
    --digest) mode="digest"; shift ;;
    -h|--help)
      echo "usage: loop-liveness.sh [--json|--digest]"
      exit 0
      ;;
    *)
      echo "loop-liveness: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
same_host() { [ "${1,,}" = "${2,,}" ]; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

# --- collect this host's declared units, in file order ------------------
units=()
if [ -f "$UNITS_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | trim)"
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086
    set -- $line
    [ $# -ge 2 ] || continue
    h="$1"; shift
    same_host "$h" "$HOST" && units+=("$*")
  done < "$UNITS_FILE"
fi

if [ "${#units[@]}" -eq 0 ]; then
  if [ "$mode" = "json" ]; then
    printf '{"host":"%s","known":false,"units":[]}\n' "$HOST"
  else
    echo "LIVENESS unknown host=$HOST"
  fi
  exit 0
fi

# --- load existing streak state (unit -> "first_inactive checks") -------
declare -A old_first old_checks
if [ -f "$STATE_FILE" ]; then
  while read -r u f c; do
    [ -n "$u" ] || continue
    old_first["$u"]="$f"
    old_checks["$u"]="${c:-1}"
  done < "$STATE_FILE"
fi

# ==========================================================================
# --digest: pure read, no systemctl call, no state mutation.
# ==========================================================================
if [ "$mode" = "digest" ]; then
  warned=0
  for u in "${units[@]}"; do
    [ -n "${old_first[$u]:-}" ] || continue
    checks="${old_checks[$u]:-1}"
    [ "$checks" -ge 2 ] 2>/dev/null || continue
    echo "LIVENESS WARN unit=$u inactive_since=${old_first[$u]}"
    warned=1
  done
  [ "$warned" -eq 0 ] && exit 0
  exit 1
fi

# ==========================================================================
# Live check (plain / --json): one `systemctl --user is-active` per unit.
# ==========================================================================
now="$(ts)"
declare -A new_state new_first new_checks
bad=0
for u in "${units[@]}"; do
  st="$(systemctl --user is-active "$u" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$st" = "active" ]; then
    new_state["$u"]="active"
    continue
  fi
  bad=$((bad + 1))
  new_state["$u"]="inactive"
  if [ -n "${old_first[$u]:-}" ]; then
    new_first["$u"]="${old_first[$u]}"
    new_checks["$u"]=$(( ${old_checks[$u]:-1} + 1 ))
  else
    new_first["$u"]="$now"
    new_checks["$u"]=1
  fi
done

# --- persist streak state: only currently-inactive units keep a line ----
mkdir -p "$STATE_DIR" 2>/dev/null || true
tmp="$STATE_FILE.tmp.$$"
: > "$tmp"
for u in "${units[@]}"; do
  [ "${new_state[$u]}" = "inactive" ] || continue
  printf '%s %s %s\n' "$u" "${new_first[$u]}" "${new_checks[$u]}" >> "$tmp"
done
mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"

if [ "$mode" = "json" ]; then
  unit_items=() warn_items=()
  for u in "${units[@]}"; do
    unit_items+=("{\"unit\":\"$u\",\"state\":\"${new_state[$u]}\"}")
    [ "${new_state[$u]}" = "inactive" ] && warn_items+=("{\"unit\":\"$u\",\"inactive_since\":\"${new_first[$u]}\",\"checks\":${new_checks[$u]}}")
  done
  join_by() { local IFS=,; echo "$*"; }
  printf '{"host":"%s","known":true,"n":%d,"bad":%d,"units":[%s],"warn_units":[%s]}\n' \
    "$HOST" "${#units[@]}" "$bad" "$(join_by "${unit_items[@]}")" "$(join_by "${warn_items[@]}")"
  [ "$bad" -eq 0 ] && exit 0
  exit 1
fi

# --- plain text: one line per unit, then the summary --------------------
for u in "${units[@]}"; do
  echo "unit=$u state=${new_state[$u]}"
done

if [ "$bad" -eq 0 ]; then
  echo "LIVENESS ok n=${#units[@]}"
  exit 0
fi

for u in "${units[@]}"; do
  [ "${new_state[$u]}" = "inactive" ] || continue
  echo "LIVENESS WARN unit=$u inactive_since=${new_first[$u]}"
done
exit 1
