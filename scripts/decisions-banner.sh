#!/usr/bin/env bash
# decisions-banner.sh — SessionStart hook: print open operator decisions
# (PRD-build-open-decision-escalation requirement 5). Silent (no output,
# exit 0) when there is nothing open — same posture as the sibling
# repo-health-banner.sh hook it is installed right after.
#
# Fleet note (Technical considerations): state/decisions.jsonl is
# node-local; RedBaron is the lane, so RedBaron's ledger is canonical.
# When $DECISIONS_REMOTE is set (e.g. `redbaron`), this hook reads THAT
# host's ledger over ssh instead of the local one — fail-open: an
# unreachable host prints exactly `decisions: <host> unreachable` and
# still exits 0 within a few seconds (never blocks a session start on a
# hung ssh).
#
# Exit: always 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
DECISIONS_SH="${DECISIONS_SH:-$HERE/decisions.sh}"
REMOTE_STATE_REL="${DECISIONS_REMOTE_STATE_REL:-.claude/skills/build/state/decisions.jsonl}"
SSH_TIMEOUT="${DECISIONS_SSH_TIMEOUT:-4}"

if [ -n "${DECISIONS_REMOTE:-}" ]; then
  tmp="$(mktemp "${TMPDIR:-/tmp}/decisions-remote-XXXXXX.jsonl")"
  if timeout "$((SSH_TIMEOUT + 1))" ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
       -o StrictHostKeyChecking=accept-new "$DECISIONS_REMOTE" \
       "cat \$HOME/$REMOTE_STATE_REL" > "$tmp" 2>/dev/null; then
    DECISIONS_FILE="$tmp" "$DECISIONS_SH" list
  else
    echo "decisions: $DECISIONS_REMOTE unreachable"
  fi
  rm -f "$tmp"
  exit 0
fi

out="$("$DECISIONS_SH" list 2>/dev/null || true)"
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
