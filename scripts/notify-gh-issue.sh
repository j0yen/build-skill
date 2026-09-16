#!/usr/bin/env bash
# notify-gh-issue.sh — the shipped default NOTIFY_CMD (PRD-build-repo-
# health-invariants requirement 6b; Operator-authorization, Joe
# 2026-09-15T14:41:01Z: "default NOTIFY_CMD delivery = gh issue create in
# j0yen/prds ... ship this as the default notifier, not a stub").
#
# Usage: notify-gh-issue.sh <rule> <repo> <evidence-file>
#
# Runs `gh issue create -R j0yen/prds --label alarm --title "[alarm]
# <repo> <rule> <day>" --body-file <evidence-file>`. Idempotent per
# (repo, rule, UTC day): searches OPEN issues in j0yen/prds for that exact
# title first — a hit means today's issue already exists, so this exits 0
# without creating a second one. Journals `notify gh-issue url=<url>` (a
# newly created issue) or `notify gh-issue existing url=<url>` (found, not
# created) via scripts/lib/journal.sh.
#
# Called by alert-deliver.sh with the banner line already on stdin (this
# script ignores stdin — the evidence FILE is the body, not the banner
# line, since the PRD's evidence includes the CI run id and 10+ journal
# lines, which the one-line banner never carries). alert-deliver.sh has
# already handled the desktop `notify-send` call and the per-day
# idempotency marker; this script only owns the gh-issue-specific
# idempotency check (issue title) because that has to hit the network to
# be trustworthy — a stale local marker could disagree with the operator
# having closed and reopened an issue by hand.
#
# The `alarm` label is created on first use if it doesn't already exist on
# j0yen/prds (gh issue create fails outright on an unknown label).
#
# Exit: 0 on success (created or already-existing) or when `gh` is
#       unavailable/unauthenticated (best-effort, never fatal to the
#       caller — alert-deliver.sh already journals the rc) | 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-$(cd "$HERE/.." && pwd)/state}"
REPO="${NOTIFY_GH_ISSUE_REPO:-j0yen/prds}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

rule="${1:-}"; repo="${2:-}"; evidence_file="${3:-}"
[ -n "$rule" ] && [ -n "$repo" ] && [ -n "$evidence_file" ] || {
  echo "usage: notify-gh-issue.sh <rule> <repo> <evidence-file>" >&2
  exit 2
}

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "notify-gh-issue: gh not available/authenticated — skipping" >&2
  exit 0
fi

day="$(date -u +%F)"
title="[alarm] $repo $rule $day"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# PLAIN listing, never `--search` — `gh issue list --search` hits GitHub's
# full-text search index, which is eventually consistent (observed
# directly during this PRD's own build: a title created milliseconds
# earlier was invisible to --search on the very next call, producing a
# real duplicate issue, #4/#5 in j0yen/prds, closed by hand). A plain
# `gh issue list` (no --search) reads the issues API directly, sorted by
# creation, with no separate index to lag — filtering client-side on the
# exact title is slower per-call at scale but correct, and this repo's
# alarm-issue volume is at most a few per day.
existing_url="$(gh issue list -R "$REPO" --state open --limit 100 \
  --json title,url --jq ".[] | select(.title == \"$title\") | .url" 2>/dev/null | head -1)"

if [ -n "$existing_url" ]; then
  journal_line "$now  $repo  notify  gh-issue existing url=$existing_url  (rule=$rule)"
  exit 0
fi

# Best-effort: create the `alarm` label if it doesn't exist yet (a fresh
# j0yen/prds has never needed it before this PRD).
gh label create alarm -R "$REPO" --color "d93f0b" --description "repo-health alarm (PRD-build-repo-health-invariants)" >/dev/null 2>&1 || true

body_file="$evidence_file"
[ -r "$body_file" ] || body_file="$(mktemp)"
if [ "$body_file" != "$evidence_file" ]; then
  printf 'No evidence file was readable at delivery time (%s).\n' "$evidence_file" > "$body_file"
fi

url="$(gh issue create -R "$REPO" --label alarm --title "$title" --body-file "$body_file" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  journal_line "$now  $repo  notify  gh-issue url=$url  (rule=$rule)"
else
  journal_line "$now  $repo  notify  gh-issue-failed  (rule=$rule rc=$rc err=\"$(printf '%s' "$url" | tr '\n' ' ' | head -c200)\")"
fi

[ "$body_file" != "$evidence_file" ] && rm -f "$body_file"
exit 0
