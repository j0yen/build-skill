#!/usr/bin/env bash
# ticklock_ac6_headless_launcher_routes_through_tick_run.sh —
# PRD-build-tick-lock-held AC6.
#
# Given the real RedBaron lane with an automatic tick running, When
# `BUILD_TICK_ARGS="run <one queued slug>" ~/.local/bin/claude-build-headless.sh`
# is invoked, Then it exits without starting a coordinator and the journal
# has `tick-lock-held` naming the automatic tick's pid; and When the
# automatic tick ends, Then the same command starts a coordinator whose
# `tick-run.sh --status` pid equals its `claude -p` process's pid.
#
# A selftest cannot safely drive the REAL RedBaron automatic tick (that
# would race a live coordinator on shared state) or a real `claude`
# process. Two things ARE checked here, deterministically:
#   1. structural — claude-build-tick.sh (dotfiles) execs tick-run.sh
#      rather than calling `claude -p` directly (requirement 2's one-line
#      change), so every entry path — timer or manual — shares the one
#      lock-holding entrypoint.
#   2. functional equivalent — with CLAUDE_BIN swapped for a fake
#      long-running binary, two overlapping tick-run.sh launches reproduce
#      exactly the "second exits without starting a coordinator, first's
#      pid becomes both the holder pid and the running process's pid"
#      shape AC6 describes, without touching the real lane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/tick-run.sh"
DOTFILES_TICK="$HOME/dotfiles/.local/bin/claude-build-tick.sh"

fail=0

if [ -f "$DOTFILES_TICK" ]; then
  if grep -qE '(^|[^/])tick-run\.sh\b' "$DOTFILES_TICK"; then
    echo "ok  AC6: claude-build-tick.sh execs tick-run.sh"
  else
    echo "FAIL: claude-build-tick.sh does not reference tick-run.sh — requirement 2 not wired"
    fail=1
  fi
else
  echo "FAIL: $DOTFILES_TICK not found — cannot verify requirement 2 wiring"
  fail=1
fi

TMP="$(mktemp -d)"
trap 'kill "${BGPID:-0}" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
export BUILD_STATE_DIR="$TMP/state"
export TICK_RUN_JOURNAL="$TMP/journal.md"
mkdir -p "$BUILD_STATE_DIR"

FAKE_CLAUDE="$TMP/fake-claude"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$FAKE_CLAUDE"

# "automatic tick" already running, via the default (no `--`) coordinator
# path, exactly like the real launcher's `tick-run.sh` call would.
CLAUDE_BIN="$FAKE_CLAUDE" BUILD_TICK_ARGS="run some-slug" "$SCRIPT" &
BGPID=$!
sleep 1

# "manual batch" arriving mid-tick, same entrypoint.
manual_out="$(CLAUDE_BIN="$FAKE_CLAUDE" BUILD_TICK_ARGS="run some-slug" "$SCRIPT" 2>&1)"
manual_rc=$?

if [ "$manual_rc" -eq 75 ] && printf '%s' "$manual_out" | grep -q "pid=$BGPID"; then
  echo "ok  AC6: overlapping launch refuses (rc=75), names the automatic tick's pid"
else
  echo "FAIL: overlapping launch gave rc=$manual_rc out=$manual_out"
  fail=1
fi

if grep -qE "tick-lock-held \(pid=$BGPID" "$TICK_RUN_JOURNAL"; then
  echo "ok  AC6: journal names the automatic tick's pid"
else
  echo "FAIL: journal missing tick-lock-held for pid=$BGPID"
  fail=1
fi

status_pid="$(CLAUDE_BIN="$FAKE_CLAUDE" "$SCRIPT" --status | grep -oE 'pid=[0-9]+' | cut -d= -f2)"
if [ "$status_pid" = "$BGPID" ]; then
  echo "ok  AC6: --status pid equals the running coordinator process's pid"
else
  echo "FAIL: --status pid=$status_pid, want $BGPID"
  fail=1
fi

exit "$fail"
