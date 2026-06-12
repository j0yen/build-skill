#!/usr/bin/env bash
# manifest-sidecar.sh — Branch Phase-7 sidecar writer (durability fix)
#
# Usage:
#   manifest-sidecar.sh write <slug> <key=value> [<key=value> ...]
#   manifest-sidecar.sh path  <slug>
#
# Writes a per-slug sidecar JSON to state/status/<slug>.json.  Because
# each branch owns exactly one slug, there is NO shared-file contention:
# concurrent branches write to DIFFERENT paths, eliminating the
# read-modify-write race on the shared manifest.json.
#
# The parent collects all sidecars after branches return and merges them
# into manifest.json in one serial locked pass via manifest-merge-sidecars.sh.
#
# Supported key=value pairs (for the sidecar):
#   status=<string>            e.g. shipped, in_progress, queued
#   last_action=<ISO-8601>     defaults to $(date -u +%FT%TZ)
#   last_error=<string>        cleared when omitted or empty
#   ticks_invested_delta=<n>   +N increments (applied during merge)
#   output_repo_path=<path>    only set if non-empty
#   output_repo_url=<url>      only set if non-empty
#   action=<string>            free-form description for journal
#   outcome=<string>           free-form description for journal
#
# On success: exits 0.  Sidecar is atomic (mktemp + mv within same dir).

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Allow override via environment for testing; default to skill's own state dir
STATE_DIR="${STATE_DIR:-$SKILL_DIR/state}"
STATUS_DIR="${STATUS_DIR:-$STATE_DIR/status}"
JQ="${JQ:-jq}"

cmd="${1:-}"
slug="${2:-}"

usage() { echo "usage: manifest-sidecar.sh write|path <slug> [key=value ...]" >&2; exit 2; }

[ -n "$cmd" ] || usage
[ -n "$slug" ] || usage

case "$cmd" in
  path)
    echo "$STATUS_DIR/${slug}.json"
    exit 0
    ;;
  write)
    shift 2
    ;;
  *)
    usage
    ;;
esac

mkdir -p "$STATUS_DIR"

# Defaults
now="$(date -u +%FT%TZ)"
status=""
last_action="$now"
last_error=""
ticks_delta=1
output_repo_path=""
output_repo_url=""
action=""
outcome=""

for pair in "$@"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  case "$key" in
    status)            status="$val" ;;
    last_action)       last_action="$val" ;;
    last_error)        last_error="$val" ;;
    ticks_invested_delta) ticks_delta="$val" ;;
    output_repo_path)  output_repo_path="$val" ;;
    output_repo_url)   output_repo_url="$val" ;;
    action)            action="$val" ;;
    outcome)           outcome="$val" ;;
    *)                 echo "manifest-sidecar: unknown key '$key'" >&2 ;;
  esac
done

sidecar_path="$STATUS_DIR/${slug}.json"
tmp="$(mktemp "$STATUS_DIR/.sidecar-${slug}.XXXXXXXX")"

"$JQ" -cn \
  --arg slug          "$slug" \
  --arg status        "$status" \
  --arg last_action   "$last_action" \
  --arg last_error    "$last_error" \
  --argjson ticks_delta "$ticks_delta" \
  --arg output_repo_path  "$output_repo_path" \
  --arg output_repo_url   "$output_repo_url" \
  --arg action        "$action" \
  --arg outcome       "$outcome" \
  --arg written_at    "$now" \
  '{
    slug:              $slug,
    status:            (if $status == "" then null else $status end),
    last_action:       $last_action,
    last_error:        (if $last_error == "" then null else $last_error end),
    ticks_invested_delta: $ticks_delta,
    output_repo_path:  (if $output_repo_path == "" then null else $output_repo_path end),
    output_repo_url:   (if $output_repo_url == "" then null else $output_repo_url end),
    action:            (if $action == "" then null else $action end),
    outcome:           (if $outcome == "" then null else $outcome end),
    written_at:        $written_at
  }' > "$tmp"

mv -f "$tmp" "$sidecar_path"
echo "manifest-sidecar: wrote $sidecar_path"
