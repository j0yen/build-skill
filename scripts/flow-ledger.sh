#!/usr/bin/env bash
# flow-ledger.sh — CLI over state/flow-ledger.jsonl (PRD-build-flow-ledger).
#
# The ledger (Requirement 1) is one JSON object per line:
#   {ts, slug, stage, lane, sha?, detail?}
# stages: queued, claimed, first_commit, gate_start, gate_verdict (detail
# carries `verdict=pass|delta-pass|block|infra`), landed, archived,
# blocked, unblocked, needs_classification. Lifecycle scripts append via
# lib/flow-ledger.sh's flow_ledger_append (one call each, at the point of
# action); this CLI is for `report` and for callers that would rather
# shell out than source the lib (e.g. a non-bash caller, or a selftest).
#
# Subcommands:
#   flow-ledger.sh append <slug> <stage> [--lane L] [--sha S] [--detail D]
#       Thin CLI wrapper over flow_ledger_append. Always exits 0
#       (Requirement 2 — a ledger write never fails the caller).
#
#   flow-ledger.sh report [--slug <s>] [--since <dur>] [--format text|json]
#       With --slug: one PRD's lead_time_h (queued->archived), wait_time_s
#       (queued->claimed + blocked->unblocked + gate_verdict->landed gaps),
#       gate_time_s (sum gate_start->gate_verdict), gate_runs, blocks
#       (Requirement 3, AC2).
#       Without --slug: aggregate over every slug with an `archived` event
#       (optionally restricted to those archived within --since, e.g. 7d/
#       24h/30m) — lead_time/wait_time/gate_time p50 and p90, and the five
#       slowest slugs by lead_time with the wait segment that dominated
#       (Requirement 3, user story "five slowest slugs with where they
#       waited"). `prds_measured` is always the count behind the medians.
#
# Env:
#   FLOW_LEDGER_FILE   override the ledger path (default: see lib/flow-ledger.sh).
#   FLOW_LEDGER_JQ     override `jq`.
#
# Exit: 0 on a normal report (including zero PRDs measured, per day-ledger.sh's
# own "never throws on an empty source" convention) or a successful append;
# 2 on a bad argument; 3 if jq itself is missing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${FLOW_LEDGER_JQ:-jq}"

# shellcheck source=lib/flow-ledger.sh
source "$HERE/lib/flow-ledger.sh"

die() { printf '%s\n' "flow-ledger: $*" >&2; exit "${2:-2}"; }
usage() { die "usage: flow-ledger.sh {append|report} ..." 2; }

command -v "$JQ" >/dev/null 2>&1 || die "jq not found ($JQ)" 3

# ---- duration parsing (--since 7d / 24h / 30m) -----------------------
since_to_epoch() {
  # $1: now_iso  $2: duration string (e.g. 7d, 24h, 30m). Prints the cutoff
  # epoch seconds, or nothing (and returns 1) on a bad duration.
  local now_ep="$1" dur="$2" n unit secs
  [[ "$dur" =~ ^([0-9]+)([dhm])$ ]] || return 1
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  case "$unit" in
    d) secs=$((n * 86400)) ;;
    h) secs=$((n * 3600)) ;;
    m) secs=$((n * 60)) ;;
  esac
  printf '%s\n' "$((now_ep - secs))"
}

# ---- the per-slug reducer (Requirement 3) -----------------------------
# Turns a slug's own event stream (sorted by ts) into
# {lead_time_h, wait_time_s, gate_time_s, gate_runs, blocks, wait_breakdown}.
# wait_breakdown labels which segment contributed each second, so the
# aggregate report can say *where* a slow PRD waited.
FLOW_REDUCE_PROGRAM='
def acc0: {
  queued:null, claimed:null, archived:null,
  wait:0, gate:0, gate_runs:0, blocks:0,
  gate_open:null, block_open:null, lgv:null,
  wait_q2c:0, wait_block:0, wait_g2l:0
};
sort_by(.ts) as $events |
reduce $events[] as $e (
  acc0;
  ($e.ts | fromdateiso8601) as $t |
  if $e.stage == "queued" then
    (if .queued == null then .queued = $t else . end)
  elif $e.stage == "claimed" then
    (if .claimed == null then
       (if .queued != null then (.wait += ($t - .queued) | .wait_q2c += ($t - .queued)) else . end) | .claimed = $t
     else . end)
  elif $e.stage == "first_commit" then .
  elif $e.stage == "gate_start" then .gate_open = $t
  elif $e.stage == "gate_verdict" then
    (if .gate_open != null then (.gate += ($t - .gate_open) | .gate_runs += 1 | .gate_open = null) else . end)
    | (if (($e.detail // "") | contains("verdict=block")) then .blocks += 1 else . end)
    | .lgv = $t
  elif $e.stage == "blocked" then .block_open = $t
  elif $e.stage == "unblocked" then
    (if .block_open != null then (.wait += ($t - .block_open) | .wait_block += ($t - .block_open) | .block_open = null) else . end)
  elif $e.stage == "landed" then
    (if .lgv != null then (.wait += ($t - .lgv) | .wait_g2l += ($t - .lgv) | .lgv = null) else . end)
  elif $e.stage == "archived" then .archived = $t
  else . end
) as $acc |
{
  lead_time_h: (if $acc.queued != null and $acc.archived != null then (($acc.archived - $acc.queued) / 3600) else null end),
  wait_time_s: $acc.wait,
  gate_time_s: $acc.gate,
  gate_runs: $acc.gate_runs,
  blocks: $acc.blocks,
  wait_breakdown: {queued_to_claimed: $acc.wait_q2c, blocked_gap: $acc.wait_block, gate_verdict_to_landed: $acc.wait_g2l}
}
'

percentile_filter='
def pct($xs; $p):
  ($xs | sort) as $s | ($s | length) as $n |
  if $n == 0 then null
  else $s[ ( ( ($p * $n) | ceil) - 1 ) as $i | (if $i < 0 then 0 elif $i > ($n - 1) then ($n - 1) else $i end) ]
  end;
'

cmd_append() {
  local slug="${1:-}" stage="${2:-}"
  [ -n "$slug" ] && [ -n "$stage" ] || usage
  shift 2
  flow_ledger_append "$slug" "$stage" "$@"
  exit 0
}

cmd_report() {
  local slug="" since="" format="text"
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:?--slug needs a value}"; shift 2 ;;
      --since) since="${2:?--since needs a value like 7d}"; shift 2 ;;
      --format) format="${2:?--format needs text|json}"; shift 2 ;;
      *) die "report: unknown argument: $1" 2 ;;
    esac
  done

  local ledger; ledger="$(flow_ledger_path)"
  local events="[]"
  if [ -r "$ledger" ]; then
    events="$("$JQ" -c '.' "$ledger" 2>/dev/null | "$JQ" -s '.' 2>/dev/null)"
    [ -n "$events" ] || events="[]"
  fi

  if [ -n "$slug" ]; then
    local slug_events row
    slug_events="$(printf '%s' "$events" | "$JQ" -c --arg s "$slug" '[.[] | select(.slug == $s)]')"
    row="$(printf '%s' "$slug_events" | "$JQ" "$FLOW_REDUCE_PROGRAM")"
    if [ "$format" = "json" ]; then
      printf '%s' "$row" | "$JQ" --arg slug "$slug" '. + {slug: $slug}'
    else
      printf '%s' "$row" | "$JQ" -r --arg slug "$slug" '
        "flow-ledger \($slug)",
        "  lead_time_h=\(.lead_time_h // "n/a")",
        "  wait_time_s=\(.wait_time_s)",
        "  gate_time_s=\(.gate_time_s)",
        "  gate_runs=\(.gate_runs)",
        "  blocks=\(.blocks)"
      '
    fi
    exit 0
  fi

  # aggregate: one row per slug that has ever appeared, filter to those with
  # an archived event (optionally within --since), then p50/p90 + top-5 slowest.
  local slugs; slugs="$(printf '%s' "$events" | "$JQ" -r '[.[].slug] | unique | .[]')"
  local now_ep; now_ep="$(date -u +%s)"
  local cutoff_ep=""
  if [ -n "$since" ]; then
    cutoff_ep="$(since_to_epoch "$now_ep" "$since")" || die "bad --since value: $since (want <n>d|<n>h|<n>m)" 2
  fi

  local rows="[]"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    local slug_events row archived_ts
    slug_events="$(printf '%s' "$events" | "$JQ" -c --arg s "$s" '[.[] | select(.slug == $s)]')"
    archived_ts="$(printf '%s' "$slug_events" | "$JQ" -r '[.[] | select(.stage == "archived") | .ts] | last // empty')"
    [ -n "$archived_ts" ] || continue
    if [ -n "$cutoff_ep" ]; then
      local arch_ep; arch_ep="$(date -u -d "$archived_ts" +%s 2>/dev/null || echo 0)"
      [ "$arch_ep" -ge "$cutoff_ep" ] || continue
    fi
    row="$(printf '%s' "$slug_events" | "$JQ" --arg slug "$s" "$FLOW_REDUCE_PROGRAM"' + {slug: $slug}')"
    rows="$(printf '%s' "$rows" | "$JQ" --argjson r "$row" '. + [$r]')"
  done <<< "$slugs"

  local summary
  summary="$(printf '%s' "$rows" | "$JQ" "$percentile_filter"'
    {
      prds_measured: length,
      lead_time_p50_h: pct([.[] | select(.lead_time_h != null) | .lead_time_h]; 0.5),
      lead_time_p90_h: pct([.[] | select(.lead_time_h != null) | .lead_time_h]; 0.9),
      wait_time_p50_s: pct([.[].wait_time_s]; 0.5),
      wait_time_p90_s: pct([.[].wait_time_s]; 0.9),
      gate_time_p50_s: pct([.[].gate_time_s]; 0.5),
      gate_time_p90_s: pct([.[].gate_time_s]; 0.9),
      slowest: (
        sort_by(-(.lead_time_h // 0)) | .[0:5] | map({
          slug: .slug, lead_time_h: .lead_time_h,
          waited_at: (.wait_breakdown | to_entries | max_by(.value) | .key)
        })
      )
    }')"

  if [ "$format" = "json" ]; then
    printf '%s\n' "$summary"
  else
    printf '%s' "$summary" | "$JQ" -r '
      "flow-ledger report (prds_measured=\(.prds_measured))",
      "  lead_time p50=\(.lead_time_p50_h // "n/a")h p90=\(.lead_time_p90_h // "n/a")h",
      "  wait_time  p50=\(.wait_time_p50_s // "n/a")s p90=\(.wait_time_p90_s // "n/a")s",
      "  gate_time  p50=\(.gate_time_p50_s // "n/a")s p90=\(.gate_time_p90_s // "n/a")s",
      (.slowest[] | "  slow: \(.slug) lead_time_h=\(.lead_time_h) waited_at=\(.waited_at)")
    '
  fi
  exit 0
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  append) cmd_append "$@" ;;
  report) cmd_report "$@" ;;
  *) usage ;;
esac
