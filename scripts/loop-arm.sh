#!/usr/bin/env bash
# loop-arm.sh — operator-run: enable+start every unit THIS HOST declares in
# loop-units.txt, then verify with loop-liveness.sh and print its table
# (PRD-buildloop-unit-liveness).
#
# This is the ONLY arming step for the buildloop's units — SKILL.md's
# restart/re-arm text and carbon-lane-install.sh both call this instead of
# a standalone `systemctl --user enable --now <unit...>`, so a restart can
# no longer silently drop one (2026-09-11: it did — see loop-units.txt's
# header). Operator-run only: the tick path NEVER starts a unit itself
# (standing rule) and this script is never invoked from a tick.
#
# Touches no unit outside the declared set: exactly one
# `systemctl --user enable --now <unit1> <unit2> ...` call naming every
# unit this host declares, nothing else.
#
# Exit 0: every declared unit active after arming (or nothing declared).
# Exit 1: `loop-liveness.sh` still reports a WARN after arming.
# Exit 2: `systemctl enable --now` itself failed to run at all (not on
#         PATH, etc) — arming did not happen.
#
# Env overrides (test-only hooks; production defaults unchanged): same as
# loop-liveness.sh — LOOP_UNITS_FILE, LOOP_LIVENESS_STATE_DIR/_FILE,
# LOOP_LIVENESS_HOST. `systemctl` is resolved via $PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
UNITS_FILE="${LOOP_UNITS_FILE:-$SKILL_DIR/scripts/loop-units.txt}"
HOST="${LOOP_LIVENESS_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
LIVENESS="$HERE/loop-liveness.sh"

same_host() { [ "${1,,}" = "${2,,}" ]; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

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
  echo "loop-arm: no declared units for host=$HOST — nothing to arm"
  exit 0
fi

echo "loop-arm: enabling ${#units[@]} declared unit(s) for host=$HOST: ${units[*]}"
if ! command -v systemctl >/dev/null 2>&1; then
  echo "loop-arm: systemctl not on PATH — cannot arm" >&2
  exit 2
fi

if ! systemctl --user enable --now "${units[@]}"; then
  echo "loop-arm: systemctl enable --now reported a failure — checking what actually came up" >&2
fi

echo "loop-arm: verifying —"
"$LIVENESS"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "loop-arm: one or more declared units still inactive after arming" >&2
  exit 1
fi
echo "loop-arm: all declared units active"
exit 0
