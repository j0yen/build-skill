#!/usr/bin/env bash
# day-ledger.sh — PRD-build-day-ledger. One factual JSON record of the
# loop's day (build.day_ledger.v1), no model call, written to
# $PRD_DIR/notes/day-ledger/<date>.json and pushed through the same
# `pull --rebase --autostash` path archive-commit.sh already uses.
#
# It is a READER, not a re-deriver: ticks come from the build journal /
# journalctl claude-build.service, gates from gates-banner.sh's own
# summary line, shipped from the PRDs repo's `archive: <slug> shipped`
# commits, landings from branch-protection.json + `gh pr list`, decisions
# from state/decisions.jsonl, burst from burst-lane.sh status. Any source
# that is missing or unparseable degrades to that field's empty value
# plus a `notes: ["source-missing: <name>"]` line — this script never
# throws (req 6); only an unwritable output directory exits non-zero (2).
#
# Day boundary: the America/New_York calendar day (`tz` in the output is
# always that zone's name even though every timestamp inside stays UTC
# ISO-8601) — `--date` overrides, else derived from now (or
# $DAY_LEDGER_NOW, a testing hook, ISO-8601 UTC).
#
# identifiers[] / closure (req 4): built from the STRUCTURED fields
# (slugs, repo names, decision ids, host) plus a regex sweep of the one
# freeform field, `notes[]`, for hostnames/shas/PR numbers. The
# `sources_sha256`, `identifiers`, and `produced_at` fields are excluded
# from the sweep on purpose — they are provenance metadata, not content
# (sources_sha256's own hex digests would otherwise force themselves
# into identifiers, which defeats the point of the closure check).
#
# Usage:
#   day-ledger.sh [--date YYYY-MM-DD] [--out <path>] [--no-push]
#                 [--format json|text] [--since <date> --until <date>]
#
# Env (testing/override, mirrors gates-banner.sh's own convention):
#   DAY_LEDGER_NOW              ISO-8601 UTC timestamp to treat as "now"
#   DAY_LEDGER_HOSTNAME          override `hostname` (host field + push gate)
#   PRD_DIR                     PRDs repo (default ~/Documents/PRDs)
#   GATE_RED_SUMMARY_FILE       passed through to gates-banner.sh
#   GATES_BANNER_HOSTNAME       passed through to gates-banner.sh (default redbaron)
#   DAY_LEDGER_GATES_BANNER_BIN override scripts/gates-banner.sh path
#                                (fake/failing binary in tests, e.g. AC3)
#   DAY_LEDGER_DECISIONS_FILE   override state/decisions.jsonl path
#   DAY_LEDGER_BRANCH_PROT_FILE override state/branch-protection.json path
#   DAY_LEDGER_JOURNAL_DIR      override ~/brain/journal/build dir
#   DAY_LEDGER_JOURNALCTL_BIN   override `journalctl` (fake binary in tests)
#   DAY_LEDGER_GH_BIN           override `gh` (fake binary in tests)
#   DAY_LEDGER_BURST_LANE_BIN   override scripts/burst-lane.sh path
#   DAY_LEDGER_BURST_LANE_STATE_DIR override burst-lane's own state dir
#                                for that one status call (default: production)
#   DAY_LEDGER_MANIFEST_FILE    override state/manifest.json path
#   DAY_LEDGER_TICK_OUTCOMES_FILE override state/tick-outcomes.jsonl path
#                                (PRD-buildloop-tick-outcome-liveness R8 --
#                                source for ticks_failed/causes/
#                                longest_failed_streak)
#   DAY_LEDGER_PROD_SKILL_DIR   override the assumed production
#                                ~/.claude/skills/build root all the
#                                state-file defaults above are anchored to
#   DAY_LEDGER_GIT_BIN          override `git` (fake binary in tests)
#   DAY_LEDGER_SERVICE_ENV_BIN  override the `systemctl --user show` call,
#                                must print BUILD_BURST_ENABLED=<0|1> or nothing
#
# Exit: 0 normally (including every degraded-source case); 2 only when
# the output directory cannot be written to.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
TZ_NAME="America/New_York"
JQ="${JQ:-jq}"
# PROD_SKILL_DIR: this script reads other reporters' REAL, PRODUCTION
# state (gate-red.summary, manifest.json, decisions.jsonl,
# branch-protection.json, burst-lane's status) even when day-ledger.sh
# itself is being run from a build-skill worktree (self-mod isolation,
# PRD-build-shell-worktree-isolation) — reading is not the mutation that
# isolation guards against, and the worktree's own state/ dir is git-
# tracked-empty (runtime state lives outside the tree). Every default
# below is anchored here, NOT at $SKILL_DIR, so a worktree-isolation
# BUILD_STATE_DIR/BURST_LANE_STATE_DIR scratch override set for OTHER
# production scripts (manifest-set.sh etc, per worktree-extend.sh's own
# reminder) never blinds day-ledger's reads. Fixture tests bypass this
# entirely via the explicit DAY_LEDGER_*_FILE / GATE_RED_SUMMARY_FILE /
# DAY_LEDGER_*_BIN overrides below.
PROD_SKILL_DIR="${DAY_LEDGER_PROD_SKILL_DIR:-$HOME/.claude/skills/build}"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

log() { printf '%s\n' "day-ledger: $*" >&2; }
die() { printf '%s\n' "day-ledger: $*" >&2; exit "${2:-2}"; }

# ---- arg parsing ----------------------------------------------------
target_date=""
out_path=""
do_push=1
format="json"
since_date=""
until_date=""

while [ $# -gt 0 ]; do
  case "$1" in
    --date) target_date="${2:?--date needs YYYY-MM-DD}"; shift 2 ;;
    --out) out_path="${2:?--out needs a path}"; shift 2 ;;
    --no-push) do_push=0; shift ;;
    --format) format="${2:?--format needs json|text}"; shift 2 ;;
    --since) since_date="${2:?--since needs YYYY-MM-DD}"; shift 2 ;;
    --until) until_date="${2:?--until needs YYYY-MM-DD}"; shift 2 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

# ---- backfill mode (P2, req 11): one file per day, delegate per-day ----
if [ -n "$since_date" ] || [ -n "$until_date" ]; then
  [ -n "$since_date" ] && [ -n "$until_date" ] || die "--since and --until must be given together" 2
  d="$since_date"
  while :; do
    "$HERE/day-ledger.sh" --date "$d" ${do_push:+$([ "$do_push" = 0 ] && printf -- '--no-push')} || true
    [ "$d" = "$until_date" ] && break
    d="$(TZ="$TZ_NAME" date -d "$d +1 day" +%F)"
  done
  exit 0
fi

now_iso="${DAY_LEDGER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
if [ -z "$target_date" ]; then
  target_date="$(TZ="$TZ_NAME" date -d "$now_iso" +%F 2>/dev/null)"
  [ -n "$target_date" ] || die "could not derive --date from now=$now_iso" 2
fi

# Local day boundary [day_start_utc, day_end_utc) in epoch seconds, for
# filtering UTC-timestamped source records into this America/New_York day.
day_start_epoch="$(TZ="$TZ_NAME" date -d "$target_date 00:00:00" +%s)"
day_end_epoch="$(TZ="$TZ_NAME" date -d "$target_date 00:00:00 +1 day" +%s)"

ts_in_day() {
  # $1: an ISO-8601 UTC timestamp (or empty). Returns 0 if it falls in
  # [day_start_epoch, day_end_epoch), 1 otherwise (including unparseable).
  local ts="$1" ep
  [ -n "$ts" ] || return 1
  ep="$(date -u -d "$ts" +%s 2>/dev/null)" || return 1
  [ "$ep" -ge "$day_start_epoch" ] && [ "$ep" -lt "$day_end_epoch" ]
}

notes=()
add_note() { notes+=("$1"); }

sha_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

host="${DAY_LEDGER_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
KNOWN_HOSTS="redbaron carbon hub casper wm-apps mcphost-1"

# =======================================================================
# source: ticks (journalctl claude-build.service + the day's own journal
# file, which is already day-partitioned by filename)
# =======================================================================
ticks_started=0
declare -A dispatched_set=()
ticks_sha=""
{
  jcmd="${DAY_LEDGER_JOURNALCTL_BIN:-journalctl}"
  jout=""
  if command -v "$jcmd" >/dev/null 2>&1 || [ -x "$jcmd" ]; then
    jout="$("$jcmd" --user -u claude-build.service \
      --since "$(TZ="$TZ_NAME" date -d "$target_date 00:00:00" '+%Y-%m-%d %H:%M:%S')" \
      --until "$(TZ="$TZ_NAME" date -d "$target_date 00:00:00 +1 day" '+%Y-%m-%d %H:%M:%S')" \
      -o cat 2>/dev/null || true)"
  fi
  if [ -n "$jout" ]; then
    ticks_started="$(printf '%s\n' "$jout" | grep -c 'Starting claude-build.service' || true)"
  else
    add_note "source-missing: ticks"
  fi
  ticks_sha="$(sha_of "$jout")"

  jdir="${DAY_LEDGER_JOURNAL_DIR:-$HOME/brain/journal/build}"
  jfile="$jdir/$target_date.md"
  if [ -r "$jfile" ]; then
    while IFS= read -r slug; do
      [ -n "$slug" ] && dispatched_set["$slug"]=1
    done < <(grep -oE 'chain: [A-Za-z0-9_-]+ step' "$jfile" 2>/dev/null | awk '{print $2}'
              grep -oE '^[0-9TZ:-]+  gate-then-land  [A-Za-z0-9_-]+  ' "$jfile" 2>/dev/null | awk '{print $3}'
              grep -oE '^[0-9TZ:-]+  [A-Za-z0-9_-]+  (build tick:|chain:)' "$jfile" 2>/dev/null | awk '{print $2}')
    ticks_sha="$(sha_of "$jout$(cat "$jfile" 2>/dev/null | sha256sum)")"
  fi
}
dispatched_prds_json="$(printf '%s\n' "${!dispatched_set[@]}" | sort -u | "$JQ" -R . | "$JQ" -s '.')"
[ -n "$dispatched_prds_json" ] || dispatched_prds_json="[]"

# =======================================================================
# source: tick outcomes (PRD-buildloop-tick-outcome-liveness R8) --
# state/tick-outcomes.jsonl, tick-run.sh's own append-only history (one
# compact line per tick). ticks_failed/causes are this day's failed
# records only; longest_failed_streak reuses each record's OWN
# streak_failed (the running consecutive-failure count AT that tick,
# which tick-run.sh already computes) rather than re-deriving a run
# length from scratch -- the day's max streak_failed among its failed
# records IS the longest streak that touched this day.
# =======================================================================
ticks_failed=0
causes_json="{}"
longest_failed_streak=0
tick_outcomes_sha=""
{
  tof="${DAY_LEDGER_TICK_OUTCOMES_FILE:-$PROD_SKILL_DIR/state/tick-outcomes.jsonl}"
  if [ -r "$tof" ]; then
    tick_outcomes_sha="$(sha256sum "$tof" 2>/dev/null | cut -d' ' -f1)"
    day_result="$("$JQ" -s -c --argjson s "$day_start_epoch" --argjson e "$day_end_epoch" '
      map(select((.ts // "") as $t | $t != "" and (($t | fromdateiso8601) >= $s and ($t | fromdateiso8601) < $e))) as $day |
      {
        ticks_failed: ([$day[] | select(.outcome=="failed")] | length),
        causes: ([$day[] | select(.outcome=="failed") | (.cause // "unknown")] | group_by(.) | map({key: .[0], value: length}) | from_entries),
        longest_failed_streak: (([$day[] | select(.outcome=="failed") | (.streak_failed // 0)]) as $s2 | if ($s2|length) > 0 then ($s2|max) else 0 end)
      }' "$tof" 2>/dev/null)"
    if [ -z "$day_result" ]; then
      add_note "source-missing: tick-outcomes"
    else
      ticks_failed="$(printf '%s' "$day_result" | "$JQ" -r '.ticks_failed' 2>/dev/null)"
      causes_json="$(printf '%s' "$day_result" | "$JQ" -c '.causes' 2>/dev/null)"
      longest_failed_streak="$(printf '%s' "$day_result" | "$JQ" -r '.longest_failed_streak' 2>/dev/null)"
      [ -n "$ticks_failed" ] || ticks_failed=0
      [ -n "$causes_json" ] || causes_json="{}"
      [ -n "$longest_failed_streak" ] || longest_failed_streak=0
    fi
  else
    add_note "source-missing: tick-outcomes"
  fi
}

# =======================================================================
# source: gates (reuse gates-banner.sh's own summary line, not re-derived)
# =======================================================================
gates_green=0 gates_red=0 gates_red_slugs_json="[]" gates_oldest_red="null"
gates_sha=""
{
  banner_out=""
  gbanner="${DAY_LEDGER_GATES_BANNER_BIN:-$HERE/gates-banner.sh}"
  # Machine ledger record (day-ledger.json), not a human-facing render:
  # parses green=/red=/red_slugs: back out of gates-banner.sh's summary
  # line below, so GATES_BANNER_NO_AGE=1 keeps its PRD-build-gate-red-
  # render-age age note out of that split (the note's tokens would
  # otherwise land inside gates_red_slugs_json).
  gate_summary_path="${GATE_RED_SUMMARY_FILE:-$PROD_SKILL_DIR/state/gate-red.summary}"  # lint:gate-red-not-rendered -- machine ledger, never rendered to a human as current gate state
  if [ -x "$gbanner" ]; then
    banner_out="$(env -u BUILD_STATE_DIR \
      GATES_BANNER_HOSTNAME="${GATES_BANNER_HOSTNAME:-redbaron}" \
      GATE_RED_SUMMARY_FILE="$gate_summary_path" \
      GATES_BANNER_NO_AGE=1 \
      "$gbanner" 2>/dev/null || true)"
  fi
  gates_sha="$(sha_of "$banner_out")"
  summary_line="$(printf '%s\n' "$banner_out" | sed -n '1p')"
  if [ -z "$summary_line" ] || printf '%s' "$summary_line" | grep -q 'GATES: unknown'; then
    add_note "source-missing: gates"
  else
    gates_green="$(printf '%s' "$summary_line" | grep -oE 'green=[0-9]+' | head -1 | cut -d= -f2)"
    gates_red="$(printf '%s' "$summary_line" | grep -oE 'red=[0-9]+' | head -1 | cut -d= -f2)"
    [ -n "$gates_green" ] || gates_green=0
    [ -n "$gates_red" ] || gates_red=0
    oldest="$(printf '%s' "$summary_line" | grep -oE 'oldest-red=[^ ]+' | head -1 | cut -d= -f2)"
    if [ -n "$oldest" ] && [ "$oldest" != "none" ]; then
      gates_oldest_red="$(printf '%s' "$oldest" | "$JQ" -R .)"
    fi
    slugs_raw="$(printf '%s' "$summary_line" | sed -n 's/.*red_slugs: *//p')"
    gates_red_slugs_json="$(printf '%s\n' "$slugs_raw" | tr ' ' '\n' | sed '/^$/d' | sort -u | "$JQ" -R . | "$JQ" -s '.')"
    [ -n "$gates_red_slugs_json" ] || gates_red_slugs_json="[]"
  fi
}

# =======================================================================
# source: shipped[] (archive commits that day) + manifest cross-check
# =======================================================================
shipped_json="[]"
shipped_sha=""
{
  git_bin="${DAY_LEDGER_GIT_BIN:-git}"
  if [ -d "$PRD_DIR/.git" ] || git -C "$PRD_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    since_utc="$(date -u -d "@$day_start_epoch" +%Y-%m-%dT%H:%M:%SZ)"
    until_utc="$(date -u -d "@$day_end_epoch" +%Y-%m-%dT%H:%M:%SZ)"
    glog="$("$git_bin" -C "$PRD_DIR" log --since="$since_utc" --until="$until_utc" \
      --pretty='%s' -E --grep '^archive: .+ shipped$' 2>/dev/null || true)"
    shipped_sha="$(sha_of "$glog")"
    shipped_json="$(printf '%s\n' "$glog" | sed -n 's/^archive: \(.*\) shipped$/\1/p' | sort -u | "$JQ" -R . | "$JQ" -s '.')"
    [ -n "$shipped_json" ] || shipped_json="[]"
  else
    add_note "source-missing: shipped"
  fi

  # manifest cross-check (Open question default: archive commits win,
  # disagreement -> notes). Tolerates the known 503-record jq hiccup.
  manifest="${DAY_LEDGER_MANIFEST_FILE:-$PROD_SKILL_DIR/state/manifest.json}"
  if [ -r "$manifest" ]; then
    mship_rc=0
    mship="$("$JQ" -r '.prds[]? | select(.status=="shipped") | .slug' "$manifest" 2>/dev/null)" || mship_rc=$?
    if [ "$mship_rc" -ne 0 ]; then
      add_note "source-missing: manifest"
    elif [ -n "$mship" ]; then
      shipped_arr="$(printf '%s' "$shipped_json" | "$JQ" -r '.[]' 2>/dev/null)"
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        if ! printf '%s\n' "$shipped_arr" | grep -qxF "$s"; then
          add_note "shipped-disagreement: manifest status=shipped for $s not in archive-commit log"
        fi
      done <<< "$mship"
    fi
  else
    add_note "source-missing: manifest"
  fi
}

# =======================================================================
# source: landings[] (branch-protection.json repos, merged loop/<slug> PRs)
# =======================================================================
landings_json="[]"
landings_sha=""
{
  bp="${DAY_LEDGER_BRANCH_PROT_FILE:-$PROD_SKILL_DIR/state/branch-protection.json}"
  gh_bin="${DAY_LEDGER_GH_BIN:-gh}"
  if [ -r "$bp" ]; then
    repos="$("$JQ" -r 'keys[]?' "$bp" 2>/dev/null)"
    if [ -z "$repos" ] && [ -s "$bp" ]; then
      add_note "source-missing: branch-protection"
    fi
    entries="[]"
    ghraw_all=""
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      owner="$("$JQ" -r --arg r "$repo" '.[$r].owner // "j0yen"' "$bp" 2>/dev/null)"
      ghraw="$("$gh_bin" pr list --repo "$owner/$repo" --state merged \
        --search "head:loop/" --json number,headRefName,mergedAt 2>/dev/null)"
      if [ -z "$ghraw" ]; then
        add_note "source-missing: gh:$repo"
        continue
      fi
      ghraw_all="$ghraw_all$ghraw"
      day_entries="$(printf '%s' "$ghraw" | "$JQ" -c --arg repo "$repo" --argjson s "$day_start_epoch" --argjson e "$day_end_epoch" '
        [ .[] | select((.mergedAt | fromdateiso8601) >= $s and (.mergedAt | fromdateiso8601) < $e)
          | {repo: $repo, pr: .number, slug: (.headRefName | sub("^loop/"; ""))} ]' 2>/dev/null)"
      [ -n "$day_entries" ] || day_entries="[]"
      entries="$(printf '%s\n%s\n' "$entries" "$day_entries" | "$JQ" -s 'add')"
    done <<< "$repos"
    landings_json="$entries"
    landings_sha="$(sha_of "$ghraw_all")"
  else
    add_note "source-missing: branch-protection"
  fi
}

# =======================================================================
# source: decisions (state/decisions.jsonl by opened_ts/closed_ts)
# =======================================================================
decisions_opened_json="[]"
decisions_closed_json="[]"
decisions_sha=""
{
  df="${DAY_LEDGER_DECISIONS_FILE:-$PROD_SKILL_DIR/state/decisions.jsonl}"
  if [ -r "$df" ]; then
    decisions_sha="$(sha256sum "$df" | cut -d' ' -f1)"
    result="$("$JQ" -s -c --argjson s "$day_start_epoch" --argjson e "$day_end_epoch" '
      group_by(.id) | map(sort_by(.opened_ts, .closed_ts) | last) as $latest |
      {
        opened: [ $latest[] | select((.opened_ts // "" ) as $t | ($t != "" and (($t | fromdateiso8601) >= $s and ($t | fromdateiso8601) < $e)))
                  | {id, repo, blocks} ],
        closed: [ $latest[] | select(.status == "closed" and ((.closed_ts // "") as $t | ($t != "" and (($t | fromdateiso8601) >= $s and ($t | fromdateiso8601) < $e))))
                  | {id, repo, blocks} ]
      }' "$df" 2>/dev/null)"
    if [ -z "$result" ]; then
      add_note "source-missing: decisions"
    else
      decisions_opened_json="$(printf '%s' "$result" | "$JQ" -c '.opened')"
      decisions_closed_json="$(printf '%s' "$result" | "$JQ" -c '.closed')"
    fi
  else
    add_note "source-missing: decisions"
  fi
}

# =======================================================================
# source: burst (burst-lane.sh status + BUILD_BURST_ENABLED)
# =======================================================================
burst_box_exists="false"
burst_routing_enabled="false"
burst_sha=""
{
  bl="${DAY_LEDGER_BURST_LANE_BIN:-$HERE/burst-lane.sh}"
  bout=""
  if [ -x "$bl" ]; then
    bout="$(env -u BURST_LANE_STATE_DIR \
      BURST_LANE_STATE_DIR="${DAY_LEDGER_BURST_LANE_STATE_DIR:-$PROD_SKILL_DIR/state/burst-lane}" \
      "$bl" status 2>/dev/null || true)"
  fi
  burst_sha="$(sha_of "$bout")"
  if [ -z "$bout" ]; then
    add_note "source-missing: burst"
  elif ! printf '%s' "$bout" | grep -qi 'no active session'; then
    burst_box_exists="true"
  fi
  envcmd="${DAY_LEDGER_SERVICE_ENV_BIN:-}"
  envline=""
  if [ -n "$envcmd" ]; then
    envline="$("$envcmd" 2>/dev/null || true)"
  else
    envline="$(systemctl --user show claude-build.service -p Environment --value 2>/dev/null || true)"
  fi
  if printf '%s' "$envline" | grep -q 'BUILD_BURST_ENABLED=1'; then
    burst_routing_enabled="true"
  fi
}

# =======================================================================
# P1 req 10: operator-landed note — a merged loop/<slug> PR that day with
# no landing-pending journal line for that slug that day.
# =======================================================================
{
  jdir="${DAY_LEDGER_JOURNAL_DIR:-$HOME/brain/journal/build}"
  jfile="$jdir/$target_date.md"
  n_landings="$(printf '%s' "$landings_json" | "$JQ" 'length' 2>/dev/null || echo 0)"
  if [ "${n_landings:-0}" -gt 0 ] 2>/dev/null; then
    while IFS=$'\t' read -r repo pr slug; do
      [ -n "$slug" ] || continue
      if [ -r "$jfile" ] && grep -qF "$slug" "$jfile" 2>/dev/null && grep -q 'landing-pending' "$jfile" 2>/dev/null \
         && grep -F "$slug" "$jfile" 2>/dev/null | grep -q 'landing-pending'; then
        : # a landing-pending line exists for this slug — not operator-landed
      else
        add_note "operator-landed $repo via pr #$pr"
      fi
    done < <(printf '%s' "$landings_json" | "$JQ" -r '.[] | [.repo, .pr, .slug] | @tsv' 2>/dev/null)
  fi
}

# =======================================================================
# identifiers[] — structured fields first, THEN a regex sweep over both
# those same strings and notes[] (req 4's closure check applies its
# [0-9a-f]{7,40}/#N/hostname regexes to the WHOLE file, and a real slug
# can legitimately end in a short commit sha, e.g.
# "mcphost-gate-debt-4f1112d" — that embedded "4f1112d" run is its own
# regex match distinct from the slug string as a whole, so it needs its
# own identifiers[] entry too, not just the slug that contains it).
# =======================================================================
declare -A idset=()
add_id() { [ -n "$1" ] && idset["$1"]=1; }

for h in $KNOWN_HOSTS; do
  [ "$h" = "$host" ] && add_id "$h"
done
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$dispatched_prds_json" | "$JQ" -r '.[]?' 2>/dev/null)
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$gates_red_slugs_json" | "$JQ" -r '.[]?' 2>/dev/null)
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$shipped_json" | "$JQ" -r '.[]?' 2>/dev/null)
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$landings_json" | "$JQ" -r '.[] | (.repo, .slug, ("#" + (.pr|tostring)))' 2>/dev/null)
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$decisions_opened_json" | "$JQ" -r '.[] | (.id, .repo, (.blocks[]?))' 2>/dev/null)
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$decisions_closed_json" | "$JQ" -r '.[] | (.id, .repo, (.blocks[]?))' 2>/dev/null)

notes_text="$(printf '%s\n' "${notes[@]:-}")"
sweep_text="$(printf '%s\n' "${!idset[@]}"; printf '%s\n' "$notes_text")"
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$sweep_text" | grep -oE "$(printf '%s' "$KNOWN_HOSTS" | tr ' ' '|')")
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$sweep_text" | grep -oE '[0-9a-f]{7,40}')
while IFS= read -r v; do add_id "$v"; done < <(printf '%s' "$sweep_text" | grep -oE '#[0-9]+')

identifiers_json="$(printf '%s\n' "${!idset[@]}" | sed '/^$/d' | sort -u | "$JQ" -R . | "$JQ" -s '.')"
[ -n "$identifiers_json" ] || identifiers_json="[]"

notes_json="$(printf '%s\n' "${notes[@]:-}" | sed '/^$/d' | "$JQ" -R . | "$JQ" -s '.')"
[ -n "$notes_json" ] || notes_json="[]"

sources_sha256_json="$("$JQ" -n \
  --arg ticks "$(sha_of "${ticks_sha:-}")" \
  --arg gates "${gates_sha:-$(sha_of "")}" \
  --arg shipped "${shipped_sha:-$(sha_of "")}" \
  --arg landings "${landings_sha:-$(sha_of "")}" \
  --arg decisions "${decisions_sha:-$(sha_of "")}" \
  --arg burst "${burst_sha:-$(sha_of "")}" \
  --arg tick_outcomes "${tick_outcomes_sha:-$(sha_of "")}" \
  '{ticks:$ticks, gates:$gates, shipped:$shipped, landings:$landings, decisions:$decisions, burst:$burst, tick_outcomes:$tick_outcomes}')"

produced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

doc="$("$JQ" -n \
  --arg schema "build.day_ledger.v1" \
  --arg date "$target_date" \
  --arg tz "$TZ_NAME" \
  --arg host "$host" \
  --argjson ticks_started "${ticks_started:-0}" \
  --argjson dispatched_prds "$dispatched_prds_json" \
  --argjson gates_green "${gates_green:-0}" \
  --argjson gates_red "${gates_red:-0}" \
  --argjson gates_red_slugs "$gates_red_slugs_json" \
  --argjson gates_oldest_red "$gates_oldest_red" \
  --argjson shipped "$shipped_json" \
  --argjson landings "$landings_json" \
  --argjson decisions_opened "$decisions_opened_json" \
  --argjson decisions_closed "$decisions_closed_json" \
  --argjson burst_box_exists "$burst_box_exists" \
  --argjson burst_routing_enabled "$burst_routing_enabled" \
  --argjson notes "$notes_json" \
  --argjson identifiers "$identifiers_json" \
  --arg produced_by "day-ledger.sh" \
  --arg produced_at "$produced_at" \
  --argjson sources_sha256 "$sources_sha256_json" \
  --argjson ticks_failed "${ticks_failed:-0}" \
  --argjson causes "$causes_json" \
  --argjson longest_failed_streak "${longest_failed_streak:-0}" \
  '{
    schema: $schema, date: $date, tz: $tz, host: $host,
    ticks: {started: $ticks_started, dispatched_prds: $dispatched_prds},
    ticks_failed: $ticks_failed, causes: $causes, longest_failed_streak: $longest_failed_streak,
    gates: {green: $gates_green, red: $gates_red, red_slugs: $gates_red_slugs, oldest_red_ts: $gates_oldest_red},
    shipped: $shipped, landings: $landings,
    decisions: {opened: $decisions_opened, closed: $decisions_closed},
    burst: {box_exists: $burst_box_exists, routing_enabled: $burst_routing_enabled},
    notes: $notes, identifiers: $identifiers,
    produced_by: $produced_by, produced_at: $produced_at,
    sources_sha256: $sources_sha256
  }')"

# ---- format text (P1 req 9): 10-line human view ----------------------
if [ "$format" = "text" ]; then
  printf '%s' "$doc" | "$JQ" -r '
    "day-ledger " + .date + " (" + .tz + ", " + .host + ")",
    "gates: green=" + (.gates.green|tostring) + " red=" + (.gates.red|tostring) +
      (if (.gates.red_slugs|length) > 0 then " red_slugs=" + (.gates.red_slugs|join(",")) else "" end),
    "ticks: started=" + (.ticks.started|tostring) + " dispatched=" + (.ticks.dispatched_prds|length|tostring),
    "shipped(" + (.shipped|length|tostring) + "): " + (.shipped|join(", ")),
    ( .landings[] | "landing: " + .repo + "#" + (.pr|tostring) + " (" + .slug + ")" ),
    "decisions: opened=" + (.decisions.opened|length|tostring) + " closed=" + (.decisions.closed|length|tostring),
    "burst: box_exists=" + (.burst.box_exists|tostring) + " routing_enabled=" + (.burst.routing_enabled|tostring)
  ' 2>/dev/null | head -10
  exit 0
fi

# ---- atomic write ------------------------------------------------------
if [ -n "$out_path" ]; then
  target_file="$out_path"
else
  target_file="$PRD_DIR/notes/day-ledger/$target_date.json"
fi
target_dir="$(dirname "$target_file")"
mkdir -p "$target_dir" 2>/dev/null
if [ ! -w "$target_dir" ]; then
  die "output directory not writable: $target_dir" 2
fi
tmp_file="$(mktemp "$target_dir/.day-ledger.XXXXXX" 2>/dev/null)" || die "could not create temp file in $target_dir" 2
printf '%s\n' "$doc" > "$tmp_file" || die "write failed: $tmp_file" 2
mv -f "$tmp_file" "$target_file" || die "rename failed: $tmp_file -> $target_file" 2

log "wrote $target_file"

# ---- push (req 5) -------------------------------------------------------
# Push failures journal a real "day-ledger push-failed" line via the
# single journal writer (lib/journal.sh) — not just stderr — so
# gate-red-summary.sh and the red-gate banner can see it; a streak file
# (this script's OWN bookkeeping, honors BUILD_STATE_DIR the same as
# every other production script so a worktree selftest's scratch
# BUILD_STATE_DIR never touches the real streak) tracks consecutive
# failures and journals an extra alarm-shaped line on the second in a row
# (Technical Considerations).
push_fail() {  # $1 = short reason tag, e.g. "pull"/"commit"/"push"
  local reason="$1" streak_dir streak_file n=1
  streak_dir="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
  streak_file="$streak_dir/day-ledger-push-fail-streak"
  mkdir -p "$streak_dir" 2>/dev/null || true
  if [ -r "$streak_file" ]; then
    n="$(($(cat "$streak_file" 2>/dev/null || echo 0) + 1))"
  fi
  printf '%s\n' "$n" > "$streak_file" 2>/dev/null || true
  journal_line "day-ledger push-failed ($reason)"
  if [ "$n" -ge 2 ]; then
    journal_line "day-ledger  push-failed-repeat  blockers=day-ledger-push streak=$n"
  fi
}
push_ok() {
  local streak_dir="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
  rm -f "$streak_dir/day-ledger-push-fail-streak" 2>/dev/null || true
}

if [ "$do_push" = "1" ]; then
  git_bin="${DAY_LEDGER_GIT_BIN:-git}"
  GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")
  pull_err="$(mktemp /tmp/day-ledger.pull.XXXXXX.err 2>/dev/null || echo /tmp/day-ledger.pull.err)"
  commit_err="$(mktemp /tmp/day-ledger.commit.XXXXXX.err 2>/dev/null || echo /tmp/day-ledger.commit.err)"
  push_err="$(mktemp /tmp/day-ledger.push.XXXXXX.err 2>/dev/null || echo /tmp/day-ledger.push.err)"
  if ! "$git_bin" -C "$PRD_DIR" pull --rebase --autostash -q 2>"$pull_err"; then
    log "pull --rebase --autostash failed: $(tail -1 "$pull_err" 2>/dev/null)"
    push_fail "pull"
    rm -f "$pull_err" "$commit_err" "$push_err"
    exit 0
  fi
  "$git_bin" -C "$PRD_DIR" add "notes/day-ledger/$target_date.json" 2>/dev/null
  if "$git_bin" -C "$PRD_DIR" diff --cached --quiet 2>/dev/null; then
    log "nothing to commit (file unchanged)"
    push_ok
  elif "$git_bin" "${GIT_ID[@]}" -C "$PRD_DIR" commit -q -m "day-ledger: $target_date" 2>"$commit_err"; then
    if "$git_bin" -C "$PRD_DIR" push -q 2>"$push_err"; then
      push_ok
    else
      log "push failed: $(tail -1 "$push_err" 2>/dev/null)"
      push_fail "push"
    fi
  else
    log "commit failed: $(tail -1 "$commit_err" 2>/dev/null)"
    push_fail "commit"
  fi
  rm -f "$pull_err" "$commit_err" "$push_err"
fi

exit 0
