#!/usr/bin/env bash
# archive-live-ac-refusal.sh — PRD-build-live-ac-no-defer R5.
#
# verified-completed.sh --derive already classifies a loop-tooling PRD's
# `(Live` ACs as live-ac-deferred / live-ac-unproven and check #5 already
# fails generically on them (the checklist's "any AC with none of the
# three [pairings] remains a hard fail" rule doesn't distinguish WHY an AC
# is unpaired). What that generic failure does not give the archive step
# is (a) a `last_error` string distinct from an ordinary MISSING/collision
# failure, or (b) the specific `live-ac-unproven:<N>` journal line R6's
# reality check greps for. This script is that missing piece: a read-only
# wrapper around `verified-completed.sh --derive --format json`, run by
# the archive step ALONGSIDE (never instead of) the ordinary check #5 run.
#
# Usage: archive-live-ac-refusal.sh <PRD-path>
#
# Output (stdout, only on refusal — exit 1): one last_error string, e.g.
#   live-ac-unproven:3
#   live-ac-unproven:3,5
#   live-ac-deferred:2;live-ac-unproven:3
# (semicolon-joined when both kinds are present; live-ac-deferred should
# already be caught by prd-lint.sh well before a PRD reaches archive, but
# this script re-derives rather than trusting a stale lint pass.)
#
# Journals: `<ts>  <slug>  archive  refuse (<last_error>)` — via
# scripts/lib/journal.sh, honoring $ARCHIVE_LIVE_AC_JOURNAL (absolute path
# override, same convention as ARCHIVE_GATE_JOURNAL) for hermetic selftests.
#
# Caller contract (SKILL.md archive checklist): on exit 1, the branch
# agent records the printed string as the manifest `last_error` and
# leaves `status` at whatever it already was (a loop-tooling PRD only
# reaches this check once it is otherwise `built`) — it does NOT reset to
# `in_progress` the way an ordinary check #5 MISSING/collision failure
# does, because nothing else is wrong: the PRD stays `built`, re-checked
# each tick by the reality check (R6), until the named evidence appears.
#
# Exit codes:
#   0  nothing to refuse on live-ac-* grounds (the PRD may still fail
#      check #5 for other reasons — this script only speaks to the
#      live-ac-* class).
#   1  refused; stdout carries the last_error string, journal line written.
#   2  usage / setup error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VC="$HERE/verified-completed.sh"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

[ $# -ge 1 ] || { echo "usage: archive-live-ac-refusal.sh <PRD-path>" >&2; exit 2; }
prd="$1"
[ -r "$prd" ] || { echo "archive-live-ac-refusal: $prd not readable" >&2; exit 2; }
[ -x "$VC" ] || { echo "archive-live-ac-refusal: $VC not executable" >&2; exit 2; }
[ -x "$JQ" ] || { echo "archive-live-ac-refusal: jq not at $JQ" >&2; exit 2; }

base="$(basename "$prd")"
slug="${base#PRD-}"; slug="${slug%.md}"

payload="$("$VC" "$prd" --derive --format json 2>/dev/null)" || true
[ -n "$payload" ] || {
  echo "archive-live-ac-refusal: verified-completed.sh produced no output for $prd" >&2
  exit 2
}

deferred_acs="$("$JQ" -r '[.classifications[] | select(.status=="live-ac-deferred") | .ac] | join(",")' <<<"$payload" 2>/dev/null)"
unproven_acs="$("$JQ" -r '[.classifications[] | select(.status=="live-ac-unproven") | .ac] | join(",")' <<<"$payload" 2>/dev/null)"

[ -n "$deferred_acs" ] || [ -n "$unproven_acs" ] || exit 0

parts=()
[ -n "$deferred_acs" ] && parts+=("live-ac-deferred:$deferred_acs")
[ -n "$unproven_acs" ] && parts+=("live-ac-unproven:$unproven_acs")
last_error="$(IFS=';'; echo "${parts[*]}")"

journal="${ARCHIVE_LIVE_AC_JOURNAL:-$(journal_root)/$(date -u +%Y-%m-%d).md}"
journal_line --file "$journal" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  archive  refuse ($last_error)"

printf '%s\n' "$last_error"
exit 1
