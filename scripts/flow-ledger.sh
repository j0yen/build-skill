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
#   flow-ledger.sh report [--slug <s>] [--since <dur>] [--by-target] [--format text|json]
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
#       --by-target (P2 requirement 8, AC9): the same aggregate, computed
#       once per `build_into` group instead of once overall -- each
#       slug's build_into comes from state/manifest.json
#       (FLOW_LEDGER_MANIFEST_FILE overrides); a slug missing from the
#       manifest, or with no build_into recorded, groups under "unknown".
#
#   flow-ledger.sh backfill [--since <dur>] [--prd-dir <dir>]
#       Requirement 6 (P1): for every PRD archived within --since (default
#       14d) -- read the same way day-ledger.sh's own shipped[] source
#       already does, `git log --grep '^archive: .+ shipped$'` in
#       --prd-dir -- reconstructs the `archived` event from that commit's
#       own sha+timestamp, and (from the now-archived file's own
#       frontmatter) `queued` from `Drafted: <date>` and `claimed` from
#       `Lane: <host> <ts>`, every one marked `detail: source=backfill`
#       and skipped when that slug already has a REAL event for that
#       stage (idempotent -- a repeat run never duplicates). Known scope
#       limit: `gate_start`/`gate_verdict` are NOT reconstructed -- no
#       journal line before this PRD shipped reliably maps a gate run back
#       to a PRD slug (gate journal lines are keyed by crate/repo name);
#       a backfilled slug's gate_runs/gate_time_s read 0, honestly, rather
#       than a guess. lead_time_h (queued->archived, the one AC7 checks)
#       is unaffected by this gap.
#
# Env:
#   FLOW_LEDGER_FILE   override the ledger path (default: see lib/flow-ledger.sh).
#   FLOW_LEDGER_JQ     override `jq`.
#   FLOW_LEDGER_MANIFEST_FILE  override state/manifest.json path (--by-target's
#                      only source for a slug's build_into; a slug missing
#                      from the manifest, or with no build_into, groups
#                      under "unknown").
#
# Exit: 0 on a normal report (including zero PRDs measured, per day-ledger.sh's
# own "never throws on an empty source" convention) or a successful append;
# 2 on a bad argument; 3 if jq itself is missing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="${FLOW_LEDGER_JQ:-jq}"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
MANIFEST_FILE="${FLOW_LEDGER_MANIFEST_FILE:-${BUILD_STATE_DIR:-$SKILL_DIR/state}/manifest.json}"

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
  local slug="" since="" format="text" since_epoch="" until_epoch="" by_target=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="${2:?--slug needs a value}"; shift 2 ;;
      --since) since="${2:?--since needs a value like 7d}"; shift 2 ;;
      --format) format="${2:?--format needs text|json}"; shift 2 ;;
      # day-ledger.sh's own day-window call (Requirement 4, AC5): an exact
      # [since_epoch, until_epoch) range instead of a --since duration
      # relative to now, so a --date backfill matches day-ledger's own
      # America/New_York day boundary exactly. Internal, undocumented in
      # the usage header above on purpose -- CLI users get --since.
      --since-epoch) since_epoch="${2:?--since-epoch needs an epoch seconds value}"; shift 2 ;;
      --until-epoch) until_epoch="${2:?--until-epoch needs an epoch seconds value}"; shift 2 ;;
      # P2 requirement 8 / AC9: group the aggregate report by build_into.
      --by-target) by_target=1; shift ;;
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
  # an archived event (optionally within --since, or the exact
  # [--since-epoch, --until-epoch) window day-ledger.sh uses), then p50/p90
  # + top-5 slowest.
  local slugs; slugs="$(printf '%s' "$events" | "$JQ" -r '[.[].slug] | unique | .[]')"
  local now_ep; now_ep="$(date -u +%s)"
  local cutoff_ep="$since_epoch"
  if [ -z "$cutoff_ep" ] && [ -n "$since" ]; then
    cutoff_ep="$(since_to_epoch "$now_ep" "$since")" || die "bad --since value: $since (want <n>d|<n>h|<n>m)" 2
  fi

  local rows="[]"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    local slug_events row archived_ts
    slug_events="$(printf '%s' "$events" | "$JQ" -c --arg s "$s" '[.[] | select(.slug == $s)]')"
    archived_ts="$(printf '%s' "$slug_events" | "$JQ" -r '[.[] | select(.stage == "archived") | .ts] | last // empty')"
    [ -n "$archived_ts" ] || continue
    if [ -n "$cutoff_ep" ] || [ -n "$until_epoch" ]; then
      local arch_ep; arch_ep="$(date -u -d "$archived_ts" +%s 2>/dev/null || echo 0)"
      [ -z "$cutoff_ep" ] || [ "$arch_ep" -ge "$cutoff_ep" ] || continue
      [ -z "$until_epoch" ] || [ "$arch_ep" -lt "$until_epoch" ] || continue
    fi
    row="$(printf '%s' "$slug_events" | "$JQ" --arg slug "$s" "$FLOW_REDUCE_PROGRAM"' + {slug: $slug}')"
    rows="$(printf '%s' "$rows" | "$JQ" --argjson r "$row" '. + [$r]')"
  done <<< "$slugs"

  local summary_program='
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
    }'

  if [ "$by_target" -eq 1 ]; then
    # P2 requirement 8 / AC9: attach each row's build_into from the
    # manifest (a slug missing from the manifest, or with no build_into
    # recorded, groups under "unknown" rather than being dropped), then
    # compute the same per-target percentile summary the plain aggregate
    # above computes overall, once per group.
    local manifest_json="{}"
    if [ -r "$MANIFEST_FILE" ]; then
      manifest_json="$("$JQ" -c '.' "$MANIFEST_FILE" 2>/dev/null)"
      [ -n "$manifest_json" ] || manifest_json="{}"
    fi
    local targets_json
    targets_json="$("$JQ" -n --argjson m "$manifest_json" '
      ($m.prds // {}) as $p |
      (if ($p | type) == "array" then $p else ($p | to_entries | map(.value)) end)
      | map({key: .slug, value: (.build_into // "unknown")}) | from_entries')"
    local by_target_json
    by_target_json="$(printf '%s' "$rows" | "$JQ" --argjson targets "$targets_json" "$percentile_filter"'
      map(. + {build_into: ($targets[.slug] // "unknown")})
      | group_by(.build_into)
      | map({
          key: .[0].build_into,
          value: ('"$summary_program"')
        })
      | from_entries')"
    if [ "$format" = "json" ]; then
      printf '%s\n' "$by_target_json"
    else
      printf '%s' "$by_target_json" | "$JQ" -r '
        to_entries[] |
        "== \(.key) (prds_measured=\(.value.prds_measured)) ==",
        "  lead_time p50=\(.value.lead_time_p50_h // "n/a")h p90=\(.value.lead_time_p90_h // "n/a")h"
      '
    fi
    exit 0
  fi

  local summary
  summary="$(printf '%s' "$rows" | "$JQ" "$percentile_filter$summary_program")"

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

cmd_backfill() {
  local since="14d" prd_dir="${PRD_DIR:-$HOME/Documents/PRDs}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:?--since needs a value like 14d}"; shift 2 ;;
      --prd-dir) prd_dir="${2:?--prd-dir needs a path}"; shift 2 ;;
      *) die "backfill: unknown argument: $1" 2 ;;
    esac
  done

  { [ -d "$prd_dir/.git" ] || git -C "$prd_dir" rev-parse --git-dir >/dev/null 2>&1; } \
    || die "backfill: not a git repo: $prd_dir" 2

  local now_ep; now_ep="$(date -u +%s)"
  local cutoff_ep; cutoff_ep="$(since_to_epoch "$now_ep" "$since")" \
    || die "bad --since value: $since (want <n>d|<n>h|<n>m)" 2
  local cutoff_iso; cutoff_iso="$(date -u -d "@$cutoff_ep" +%Y-%m-%dT%H:%M:%SZ)"

  local ledger; ledger="$(flow_ledger_path)"
  local existing="[]"
  if [ -r "$ledger" ]; then
    existing="$("$JQ" -c '.' "$ledger" 2>/dev/null | "$JQ" -s '.' 2>/dev/null)"
    [ -n "$existing" ] || existing="[]"
  fi
  # Idempotent (Requirement 6): a slug that already has a REAL event for a
  # stage is left alone -- backfill only fills gaps, never overwrites, and
  # a repeat run over the same window is a no-op.
  has_stage() {  # $1=slug $2=stage
    printf '%s' "$existing" | "$JQ" -e --arg s "$1" --arg st "$2" \
      'any(.[]; .slug == $s and .stage == $st)' >/dev/null 2>&1
  }

  local archived_n=0 queued_n=0 claimed_n=0
  local glog
  glog="$(git -C "$prd_dir" log --since="$cutoff_iso" --date=iso-strict --pretty='%H|%aI|%s' \
    -E --grep '^archive: .+ shipped$' 2>/dev/null || true)"
  while IFS='|' read -r sha aidate subj; do
    [ -n "$subj" ] || continue
    local slug; slug="$(printf '%s' "$subj" | sed -n 's/^archive: \(.*\) shipped$/\1/p')"
    [ -n "$slug" ] || continue
    local ts; ts="$(date -u -d "$aidate" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    [ -n "$ts" ] || continue

    if ! has_stage "$slug" "archived"; then
      flow_ledger_append "$slug" "archived" --sha "$sha" --detail "source=backfill" --ts "$ts"
      archived_n=$((archived_n + 1))
    fi

    local f="$prd_dir/built-prds/PRD-$slug.md"
    [ -f "$f" ] || continue

    if ! has_stage "$slug" "queued"; then
      local drafted; drafted="$(grep -m1 -E '^-? *Drafted: *[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
      if [ -n "$drafted" ]; then
        local qts; qts="$(date -u -d "${drafted}T00:00:00Z" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
        if [ -n "$qts" ]; then
          flow_ledger_append "$slug" "queued" --detail "source=backfill" --ts "$qts"
          queued_n=$((queued_n + 1))
        fi
      fi
    fi

    if ! has_stage "$slug" "claimed"; then
      local lane_line; lane_line="$(grep -m1 -E '^-? *Lane: *[^ ]+ +[0-9TZ:.-]+' "$f" 2>/dev/null)"
      if [ -n "$lane_line" ]; then
        local lane_host; lane_host="$(printf '%s' "$lane_line" | sed -E 's/^-? *Lane: *([^ ]+).*/\1/')"
        local lane_ts_raw; lane_ts_raw="$(printf '%s' "$lane_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z')"
        if [ -n "$lane_ts_raw" ]; then
          local cts; cts="$(date -u -d "$lane_ts_raw" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
          if [ -n "$cts" ]; then
            flow_ledger_append "$slug" "claimed" --lane "$lane_host" --detail "source=backfill" --ts "$cts"
            claimed_n=$((claimed_n + 1))
          fi
        fi
      fi
    fi
  done <<< "$glog"

  printf 'flow-ledger backfill: archived=%d queued=%d claimed=%d (since=%s)\n' \
    "$archived_n" "$queued_n" "$claimed_n" "$since"
  exit 0
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  append) cmd_append "$@" ;;
  report) cmd_report "$@" ;;
  backfill) cmd_backfill "$@" ;;
  *) usage ;;
esac
