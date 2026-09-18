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
#
# PRD-buildloop-tick-outcome-liveness R9: on the build host only
# (LOOP_ARM_BUILD_HOST, default redbaron), also checks `systemctl --user
# show-environment` for CLAUDE_CODE_OAUTH_TOKEN and prints a WARNING line
# (stderr, never the value itself) when it's absent — visibility only,
# does not affect this script's exit code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
UNITS_FILE="${LOOP_UNITS_FILE:-$SKILL_DIR/scripts/loop-units.txt}"
HOST="${LOOP_LIVENESS_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
LIVENESS="$HERE/loop-liveness.sh"
# PRD-buildloop-tick-outcome-liveness R9: RedBaron is the fleet's always-on
# Rust build machine (SKILL.md) -- the ONLY host where the loop's own
# `claude -p /build` invocations need a live OAuth session in the user
# manager environment. Overridable for selftests.
LOOP_ARM_BUILD_HOST="${LOOP_ARM_BUILD_HOST:-redbaron}"

same_host() { [ "${1,,}" = "${2,,}" ]; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

# check_oauth_token — R9: warns (stderr, exit code unaffected -- this is
# visibility, not a new failure mode this script blocks arming on) when
# CLAUDE_CODE_OAUTH_TOKEN is absent from `systemctl --user show-
# environment` on the build host. Never prints the value itself, even in
# the "present" case -- only ever tests for the KEY via grep.
check_oauth_token() {
  same_host "$HOST" "$LOOP_ARM_BUILD_HOST" || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  if ! systemctl --user show-environment 2>/dev/null | grep -q '^CLAUDE_CODE_OAUTH_TOKEN='; then
    echo "loop-arm: WARNING CLAUDE_CODE_OAUTH_TOKEN not present in the user manager environment (systemctl --user show-environment) — the loop's own claude invocations will fail to authenticate" >&2
  fi
}
check_oauth_token

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
