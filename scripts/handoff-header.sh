#!/usr/bin/env bash
# handoff-header.sh — R8 of PRD-build-gate-red-alarm-invariant.
#
# Prints the current gate-red summary line (state/gate-red.summary,
# without its leading write-timestamp) so a handoff memory can be
# prefixed with it — SKILL.md's "Handoff" section names this script as
# the required first line of every handoff memory, so a human picking up
# a session mid-incident sees the gate verdict before anything else, the
# same "first screen carries the verdict" goal gates-banner.sh serves for
# a live Claude session (R5).
#
# Usage: handoff-header.sh
# Prints nothing (exit 0) if state/gate-red.summary doesn't exist yet —
# no tick has run R1 on this host. Always local — a handoff is written on
# the host doing the work, never over ssh.
#
# The printed line carries a trailing `  [age <N>m]` / `  [STALE <H>h<M>m]`
# note (lib/gate-red-age.sh) — a handoff read hours later must not mistake
# a resolved gate-red for a current one (PRD-build-gate-red-render-age).
#
# PRD-buildloop-tick-outcome-liveness R6: ALSO prints, first, a
# `LOOP: last_ok=<s> streak_failed=<n>  [<age_note>]` line from
# state/tick-outcome.json (tick-run.sh's own R1 artifact) via
# lib/loop-line.sh — silent (no line at all) if that record doesn't exist
# yet. "GATES green" and "LOOP last_ok=<recent>" are two different claims;
# a handoff must never let one stand in for the other.
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

# PRD-buildloop-tick-outcome-liveness R6: the LOOP: line is independent of
# the gate-red summary below (a missing gate-red.summary must not also
# suppress this) -- printed first so "when did the loop last succeed" is
# never buried under a gate section a reader skips.
loop_line

[ -r "$SUMMARY_FILE" ] || exit 0
summary_line="$(sed -n '1p' "$SUMMARY_FILE" | cut -d' ' -f2-)"
age_note="$(gate_red_age_note "$SUMMARY_FILE")"
echo "${summary_line}  [${age_note}]"
exit 0
