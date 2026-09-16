#!/usr/bin/env bash
# alert-deliver.sh — deliver one repo-health alarm (PRD-build-repo-health-
# invariants requirement 4).
#
# Usage:
#   alert-deliver.sh <rule> <repo> <evidence-file> [--value <n>]
#   alert-deliver.sh resolve <rule> <repo>
#
# Main form: appends one line to state/alerts.banner
#   `<ts> <repo> <rule> value=<n> — <one-line evidence>`
# (<n> from --value, or the first `value=NNN` token found in the evidence
# file, or 0 if neither is present), runs the effective NOTIFY_CMD with
# that same line on stdin, and calls `notify-send` in addition when a
# desktop session exists ($DISPLAY set) — both journaled, neither fatal.
# Idempotent per (rule, repo, UTC day): a second call for the same triple
# on the same day is a silent no-op (exit 0, nothing appended, nothing
# run) — scripts/lib/alert-marker.sh owns the marker file both this script
# and manifest-invariants.sh check.
#
# Effective NOTIFY_CMD (Operator-authorization, Joe 2026-09-15T14:41:01Z,
# scope: "default NOTIFY_CMD delivery = gh issue create ... plus
# notify-send when a desktop session exists"):
#   - $NOTIFY_CMD if set (operator's own channel, e.g. an agorabus-publish
#     wrapper or a test stub) — run as-is, banner line piped to its stdin.
#   - else, when unset AND `gh auth status` succeeds:
#     scripts/notify-gh-issue.sh <rule> <repo> <evidence-file> — the
#     shipped default, not a stub.
#   - else: no NOTIFY_CMD runs at all (journaled `notify skipped
#     (cause=no-notify-cmd-and-gh-unauthenticated)`); the banner line and
#     alarm journal line still land regardless — delivery is best-effort,
#     never blocking.
# notify-send runs as an ADDITIONAL, independent step whenever $DISPLAY is
# set, regardless of which NOTIFY_CMD ran (or whether one ran at all) —
# centralized here rather than duplicated inside notify-gh-issue.sh so a
# desktop notification never fires twice.
#
# `resolve <rule> <repo>` appends `<ts> <repo> <rule> resolved` to the
# banner (no marker interaction — resolution isn't idempotency-gated,
# a rule can resolve and re-fire the same day) for
# repo-health-banner.sh (the SessionStart hook) to suppress the
# now-stale alarm line.
#
# Exit: 0 always (a delivery step; failures are journaled, never fatal) |
#       2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
STATE_DIR="$BUILD_STATE_DIR"
BANNER="${ALERT_BANNER:-$STATE_DIR/alerts.banner}"
NOTIFY_GH_ISSUE="${NOTIFY_GH_ISSUE:-$HERE/notify-gh-issue.sh}"

# shellcheck source=lib/alert-marker.sh
source "$HERE/lib/alert-marker.sh"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

log() { printf 'alert-deliver: %s\n' "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [ "${1:-}" = "resolve" ]; then
  rule="${2:-}"; repo="${3:-}"
  [ -n "$rule" ] && [ -n "$repo" ] || die "usage: alert-deliver.sh resolve <rule> <repo>" 2
  mkdir -p "$(dirname "$BANNER")"
  printf '%s %s %s resolved\n' "$(ts)" "$repo" "$rule" >> "$BANNER"
  journal_line "$(ts)  $repo  alert-resolved  $rule  (lane=$(hostname))"
  exit 0
fi

rule="${1:-}"; repo="${2:-}"; evidence_file="${3:-}"
[ -n "$rule" ] && [ -n "$repo" ] && [ -n "$evidence_file" ] || \
  die "usage: alert-deliver.sh <rule> <repo> <evidence-file> [--value <n>]" 2
shift 3

value=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --value) value="$2"; shift 2 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

if alert_marker_exists "$rule" "$repo"; then
  log "already delivered today: rule=$rule repo=$repo (idempotent no-op)"
  exit 0
fi

evidence_line=""
[ -r "$evidence_file" ] && evidence_line="$(grep -m1 -v '^[[:space:]]*$' "$evidence_file" 2>/dev/null || true)"
evidence_line="${evidence_line:-(no evidence line)}"

if [ -z "$value" ] && [ -r "$evidence_file" ]; then
  value="$(grep -oE 'value=[0-9]+' "$evidence_file" 2>/dev/null | head -1 | cut -d= -f2)"
fi
value="${value:-0}"

now="$(ts)"
banner_line="$now $repo $rule value=$value — $evidence_line"

mkdir -p "$(dirname "$BANNER")"
printf '%s\n' "$banner_line" >> "$BANNER"

alert_marker_touch "$rule" "$repo"

# ---- NOTIFY_CMD -------------------------------------------------------
effective_cmd=""
if [ -n "${NOTIFY_CMD:-}" ]; then
  effective_cmd="$NOTIFY_CMD"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  effective_cmd="$NOTIFY_GH_ISSUE $rule $repo $evidence_file"
fi

if [ -n "$effective_cmd" ]; then
  notify_rc=0
  printf '%s\n' "$banner_line" | bash -c "$effective_cmd" >/tmp/alert-deliver-notify.$$ 2>&1 || notify_rc=$?
  journal_line "$now  $repo  notify  rc=$notify_rc  (rule=$rule cmd=\"$effective_cmd\" lane=$(hostname))"
  rm -f "/tmp/alert-deliver-notify.$$" 2>/dev/null || true
else
  journal_line "$now  $repo  notify  skipped  (rule=$rule cause=no-notify-cmd-and-gh-unauthenticated lane=$(hostname))"
fi

# ---- desktop notification, independent of NOTIFY_CMD -------------------
if [ -n "${DISPLAY:-}" ] && command -v notify-send >/dev/null 2>&1; then
  notify-send "repo-health: $repo $rule" "$evidence_line" >/dev/null 2>&1 || true
  journal_line "$now  $repo  notify-send  sent  (rule=$rule lane=$(hostname))"
fi

exit 0
