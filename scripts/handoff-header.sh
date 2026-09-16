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
# Exit: always 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
SUMMARY_FILE="${GATE_RED_SUMMARY_FILE:-$STATE_DIR/gate-red.summary}"

[ -r "$SUMMARY_FILE" ] || exit 0
sed -n '1p' "$SUMMARY_FILE" | cut -d' ' -f2-
exit 0
