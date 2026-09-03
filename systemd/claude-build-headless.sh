#!/usr/bin/env bash
# Launcher for the /build timer: one PRD-tick per firing, never overlapping.
set -uo pipefail
STATE="$HOME/.claude/skills/build/state"
LOG="$HOME/brain/journal/build-auto.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
[ -f "$STATE/paused" ] && { echo "$(ts) launcher: paused (state/paused present)" >> "$LOG"; exit 0; }
if systemctl --user is-active --quiet claude-build-work.service; then
  echo "$(ts) launcher: tick already running (claude-build-work.service active)" >> "$LOG"; exit 0
fi
echo "$(ts) launcher: starting tick" >> "$LOG"
exec systemd-run --user --unit=claude-build-work --collect --quiet \
  -p RuntimeMaxSec=1800 -p WorkingDirectory="$HOME" \
  -p StandardOutput="append:$LOG" -p StandardError="append:$LOG" \
  --setenv=HOME="$HOME" --setenv=CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 --setenv=PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  "$HOME/.local/bin/claude" -p "/build" --model sonnet --dangerously-skip-permissions --output-format text
