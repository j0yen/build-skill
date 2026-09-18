# lib/tick-cause.sh — one-table cause classifier for a tick's captured
# coordinator output (PRD-buildloop-tick-outcome-liveness R2).
#
# `tick-run.sh` is the only caller: it tees the coordinator child's merged
# stdout/stderr to a temp file, then sources this and calls
# `tick_cause_classify <file>` to decide what `state/tick-outcome.json`
# should say. First match wins, in this order:
#   auth-expired     Failed to authenticate|OAuth session expired|no-active-session
#   quota-saturated  the exact string `claude-build-tick.sh` already matches
#                     for its own quota-saturated.tmp marker (LIMIT_RE in
#                     ~/dotfiles/.local/bin/claude-build-tick.sh) — kept in
#                     sync here so the two classifications never disagree
#                     (SKILL.md Technical considerations).
#   other            first non-empty line of the captured output.
# `tick-lock-held` is NOT produced here — that's a structural skip
# tick-run.sh detects itself (no child ever ran), not a pattern match on
# output.
#
# Non-functional bullet: never reads more than the last 64KB of captured
# output. Evidence is truncated to 200 bytes and any `sk-ant-...`-shaped
# token is redacted before it is ever echoed or written anywhere (AC4) —
# both limits are env-overridable for selftests, never for production use.
#
# Usage (after `source`):
#   IFS=$'\t' read -r cause evidence < <(tick_cause_classify <file>)

TICK_CAUSE_MAX_BYTES="${TICK_CAUSE_MAX_BYTES:-65536}"
TICK_CAUSE_EVIDENCE_MAX="${TICK_CAUSE_EVIDENCE_MAX:-200}"
TICK_CAUSE_AUTH_RE="${TICK_CAUSE_AUTH_RE:-Failed to authenticate|OAuth session expired|no-active-session}"
TICK_CAUSE_QUOTA_RE="${TICK_CAUSE_QUOTA_RE:-You.ve hit your [a-z ]*limit}"

# _tick_cause_redact — stdin -> stdout, any sk-ant-<token> replaced with
# <redacted>. Applied to every evidence string before it leaves this file.
_tick_cause_redact() {
  sed -E 's/sk-ant-[A-Za-z0-9_-]+/<redacted>/g'
}

# _tick_cause_clean <max-bytes> — stdin -> stdout, redacted, truncated,
# trailing CR/LF stripped so evidence is one clean line.
_tick_cause_clean() {
  local max="$1"
  _tick_cause_redact | head -c "$max" | tr -d '\r' | head -n1
}

# tick_cause_classify <file> — prints "<cause>\t<evidence>" to stdout.
# A missing/unreadable file classifies as `other` with empty evidence
# rather than failing — a tick that can't even capture output is still a
# failed tick and still needs a record (R1).
tick_cause_classify() {
  local file="$1"
  local tail_text=""
  if [ -n "$file" ] && [ -r "$file" ]; then
    tail_text="$(tail -c "$TICK_CAUSE_MAX_BYTES" "$file" 2>/dev/null)"
  fi

  if printf '%s\n' "$tail_text" | grep -aqE "$TICK_CAUSE_AUTH_RE"; then
    local line
    # Parenthesized: ERE `|` has the lowest precedence, so an unparenthesized
    # "A|B|C.*" matches "A" OR "B" OR "C.*", not "(A|B|C).*" — without the
    # group, only the LAST alternative's match ever carries its trailing
    # text into evidence.
    line="$(printf '%s\n' "$tail_text" | grep -aoE "(${TICK_CAUSE_AUTH_RE}).*" | head -n1 | _tick_cause_clean "$TICK_CAUSE_EVIDENCE_MAX")"
    printf 'auth-expired\t%s\n' "$line"
    return 0
  fi

  if printf '%s\n' "$tail_text" | grep -aqE "$TICK_CAUSE_QUOTA_RE"; then
    local line
    line="$(printf '%s\n' "$tail_text" | grep -aoE "(${TICK_CAUSE_QUOTA_RE}).*" | head -n1 | _tick_cause_clean "$TICK_CAUSE_EVIDENCE_MAX")"
    printf 'quota-saturated\t%s\n' "$line"
    return 0
  fi

  local first_line
  first_line="$(printf '%s\n' "$tail_text" | grep -am1 -v '^[[:space:]]*$' | _tick_cause_clean "$TICK_CAUSE_EVIDENCE_MAX")"
  printf 'other\t%s\n' "$first_line"
}
