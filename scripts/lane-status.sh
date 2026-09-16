#!/usr/bin/env bash
# lane-status.sh — lane-tagged tick health (PRD-build-second-lane-carbon
# P1 "Lane health line" + P2 "lane-status.sh"). Runnable from either box
# (RedBaron or carbon) since it only reads the shared PRD clone and the
# shared journal dir.
#
# Subcommands:
#   lane-status.sh tick-summary <lane> <claimed> <skipped> [journal-file]
#       Appends one journal line for this tick's lane contribution:
#         <ISO-ts>  lane-health  tick  claimed=<n> skipped=<n>  (lane=<lane>)
#       journal-file defaults to ~/brain/journal/build/<today>.md.
#   lane-status.sh report [--prd-dir <dir>] [--journal-dir <dir>] [--days <n>]
#       Prints: each lane's last tick-summary line (scanned back <n> days,
#       default 2), then every live claim and every stale claim found across
#       build-queue/*.md (via lane-claim.sh status), then the last 5
#       cargo-budget ledger rows (PRD-build-cargo-concurrency-budget).
#
# PRD-build-cargo-concurrency-budget (2026-09-09): `tick-summary` also
# appends this tick's `cargo-budget: peak_load=... min_avail_gb=...
# waits=... max_wait_s=...` line (via cargo-budget.sh summary's cursor —
# each call covers only the window since the previous call) right after
# the lane-health line, so the same Phase-7 parent step that already
# writes lane health also records what this tick's cargo load looked
# like. `report` additionally shows the last 5 raw ledger rows.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_CLAIM="$HERE/lane-claim.sh"
CARGO_BUDGET="${CARGO_BUDGET:-$HERE/cargo-budget.sh}"
DECISIONS="${DECISIONS:-$HERE/decisions.sh}"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
GATE_STATUS="${GATE_STATUS:-$HERE/gate-status.sh}"

die() { echo "lane-status: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: lane-status.sh {tick-summary|report} ..." >&2; exit 4; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

read_lane_line() {
  local f="$1"
  head -n 80 "$f" | grep -E '^(- *Lane:|Lane:|\*\*Lane:\*\*)' | head -n1 \
    | sed -E 's/^(- *Lane:|Lane:|\*\*Lane:\*\*)[[:space:]]*//'
}

# PRD-build-classification-durable-heal requirement 5: name any stash left
# behind in the PRDs checkout (lane-claim.sh's hardened pull autostashes a
# sibling's transient dirt, but a rebase that dies mid-flight can leave the
# stash itself un-popped) so it shows up on the standing lane-health line
# instead of sitting silent -- RedBaron carried two 2026-09-09/10 stashes
# (14 evidence files, 1 built-PRD edit) that nothing listed until an
# operator went looking by hand. Prints "<n> <oldest_age_hours>" on
# stdout; "0 0" for a non-repo or a repo with no stashes (never fatal —
# this is a health line, not a gate).
stash_stats() {
  local d="$1" n=0 oldest_h=0 now_ts ts age_h ref
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '0 0\n'; return; }
  now_ts="$(date -u +%s)"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    n=$((n + 1))
    ts="$(git -C "$d" show -s --format=%ct "$ref" 2>/dev/null || true)"
    [ -n "$ts" ] || continue
    age_h=$(( (now_ts - ts) / 3600 ))
    [ "$age_h" -gt "$oldest_h" ] && oldest_h=$age_h
  done < <(git -C "$d" stash list --format='%gd' 2>/dev/null)
  printf '%s %s\n' "$n" "$oldest_h"
}

# Journals one `stash-stale` line per stash older than STASH_STALE_HOURS
# (default 24), once per tick-summary call -- not per report, so a repeat
# `report` read never re-alarms the same stash.
journal_stale_stashes() {
  local d="$1" journal="$2" stale_hours="${STASH_STALE_HOURS:-24}"
  local now_ts ref ts age_h files message
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  now_ts="$(date -u +%s)"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    ts="$(git -C "$d" show -s --format=%ct "$ref" 2>/dev/null || true)"
    [ -n "$ts" ] || continue
    age_h=$(( (now_ts - ts) / 3600 ))
    [ "$age_h" -ge "$stale_hours" ] || continue
    files="$(git -C "$d" stash show --include-untracked --stat "$ref" 2>/dev/null | tail -n1 | sed -E 's/^[[:space:]]*//')"
    message="$(git -C "$d" show -s --format=%s "$ref" 2>/dev/null || true)"
    printf '%s  lane-health  stash-stale  (age_h=%s files=%s message="%s")\n' \
      "$(now_iso)" "$age_h" "${files:-?}" "$message" >> "$journal"
  done < <(git -C "$d" stash list --format='%gd' 2>/dev/null)
}

# PRD-build-gate-launch-survives-tick: `inflight`/`lost` gate counts for
# the tick summary, read from state/gate-inflight/*.json + gate-status.sh
# — never from a tick's own narration (that is exactly the 2026-09-15
# 16:07Z/16:12Z defect: two ticks in a row claimed "gate is running in
# the background" for a gate systemd had already lost, and nothing
# printed a number anyone could notice was wrong). Prints "<inflight>
# <lost>" on stdout; "0 0" when the gate-inflight dir is empty/absent or
# gate-status.sh is missing (never fatal — this is a health line).
gate_inflight_stats() {
  local dir="$STATE_DIR/gate-inflight" inflight=0 lost=0 f slug st
  [ -x "$GATE_STATUS" ] && [ -d "$dir" ] || { printf '0 0\n'; return; }
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .json)"
    st="$("$GATE_STATUS" "$slug" 2>/dev/null)"
    case "$st" in
      running) inflight=$((inflight + 1)) ;;
      lost)    lost=$((lost + 1)) ;;
    esac
  done
  printf '%s %s\n' "$inflight" "$lost"
}

# probe_failed_24h_stats — PRD-build-fail-loud-evidence-kept requirement 5:
# scans the journal sources a probe-failure line can land in (the current
# tick's own journal file, yesterday's file for the day-boundary edge, and
# burst-lane.sh's own named journal — the three targets scripts/lib/
# probe.sh's _probe_journal resolves to for the in-scope callers) for
# `probe  failed  (name=...)` lines whose timestamp falls within the last
# 24h, and prints "<n> <top-name>:<top-count>" (top fields empty when
# n=0). PROBE_STATUS_SOURCES overrides the file list for a selftest.
probe_failed_24h_stats() {
  local journal="$1"
  local -a sources=()
  if [ -n "${PROBE_STATUS_SOURCES:-}" ]; then
    IFS=':' read -ra sources <<<"$PROBE_STATUS_SOURCES"
  else
    sources=("$journal" \
      "$(dirname "$journal")/$(date -u -d "-1 day" +%F 2>/dev/null || date -u -v-1d +%F 2>/dev/null).md" \
      "$HOME/brain/journal/build/burst-lane.log")
  fi
  local cutoff; cutoff="$(date -u -d "-24 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  local n=0
  local -A by_name=()
  local f line ts name
  for f in "${sources[@]}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    while IFS= read -r line; do
      ts="${line%%  *}"
      [ -n "$cutoff" ] && [[ "$ts" < "$cutoff" ]] && continue
      name="$(sed -n 's/.*name=\([^ ]*\).*/\1/p' <<<"$line")"
      [ -n "$name" ] || name="unknown"
      n=$((n + 1))
      by_name["$name"]=$(( ${by_name["$name"]:-0} + 1 ))
    done < <(grep '  probe  failed  (name=' "$f" 2>/dev/null)
  done
  local top_name="" top_count=0
  for name in "${!by_name[@]}"; do
    if [ "${by_name[$name]}" -gt "$top_count" ]; then top_name="$name"; top_count="${by_name[$name]}"; fi
  done
  printf '%s %s %s\n' "$n" "${top_name:-none}" "$top_count"
}

# fixture_lines_today_stat — PRD-build-test-isolation-by-default
# requirement 8 (P2): today's fixture-shaped-line count in the production
# journal, via lint-journal-fixtures.sh --corpus (requirement 7's corpus
# lint, already built and covered by tests/isodefault_ac3 — this is a
# read-only display of that same count, never a gate). Prints "<n>" on
# stdout; "0" if the lint script is missing (never fatal — a health line).
fixture_lines_today_stat() {
  local lint="$HERE/lint-journal-fixtures.sh" n
  [ -x "$lint" ] || { printf '0\n'; return; }
  n="$("$lint" --corpus 2>/dev/null | sed -n 's/.*fixture-lines-total=\([0-9]*\).*/\1/p' | tail -n1)"
  printf '%s\n' "${n:-0}"
}

# main_push_refused_today_stat <journal-file> -> count of
# `main-push  refused` lines in today's journal (PRD-build-main-push-gate
# requirement 8 / P2) -- same "today's cumulative count" convention as
# fixture_lines_today_stat above, not a since-last-tick delta (this journal
# has no per-tick cursor to derive one from, same limitation the PROBES:
# line already lives with).
main_push_refused_today_stat() {
  local journal="$1" n
  n="$(grep -c '  main-push  refused  ' "$journal" 2>/dev/null || true)"
  printf '%s\n' "${n:-0}"
}

# branch_gates_stats <journal-file> -> "<pass> <block> <deferred_only>"
# PRD-build-branch-gate-scope-artifacts requirement 7 (P1, AC9): today's
# cumulative count of `--scope branch` gate verdicts (same "today's
# journal, not a since-last-tick delta" convention as the stats above),
# split pass vs block, plus how many of the passes carried at least one
# `deferred=<name>` producer (i.e. would have blocked on a scope artifact
# alone before this PRD) — so a day like 2026-09-15 (0 of 14 branch gates
# passing) is visible on this same health line without grepping the raw
# journal. extend-gate.sh's own gate line shape (requirement 4/8) is
# `... gate  <crate>  pass|block  (scope=branch slug=... ...)[ deferred=...]`
# — see that script's final journal_line call.
branch_gates_stats() {
  local journal="$1" pass block deferred_only
  pass="$(grep -c '  gate  .*  pass  (scope=branch ' "$journal" 2>/dev/null || true)"
  block="$(grep -c '  gate  .*  block  (scope=branch ' "$journal" 2>/dev/null || true)"
  deferred_only="$(grep '  gate  .*  pass  (scope=branch ' "$journal" 2>/dev/null | grep -c ' deferred=' || true)"
  printf '%s %s %s\n' "${pass:-0}" "${block:-0}" "${deferred_only:-0}"
}

cmd_tick_summary() {
  local lane="$1" claimed="$2" skipped="$3"
  local journal="${4:-$HOME/brain/journal/build/$(date -u +%F).md}"
  local prd_dir="${PRD_DIR:-$HOME/Documents/PRDs}"
  mkdir -p "$(dirname "$journal")" 2>/dev/null || true
  local stash_n stash_oldest_h
  read -r stash_n stash_oldest_h < <(stash_stats "$prd_dir")
  printf '%s  lane-health  tick  claimed=%s skipped=%s  (lane=%s)  stashes=%s oldest=%sh\n' \
    "$(now_iso)" "$claimed" "$skipped" "$lane" "$stash_n" "$stash_oldest_h" >> "$journal"
  journal_stale_stashes "$prd_dir" "$journal"
  if [ -x "$CARGO_BUDGET" ]; then
    local cb_line; cb_line="$("$CARGO_BUDGET" summary 2>/dev/null || true)"
    [ -n "$cb_line" ] && printf '%s\n' "$cb_line" >> "$journal"
  fi
  local gate_inflight gate_lost
  read -r gate_inflight gate_lost < <(gate_inflight_stats)
  printf '%s  lane-health  gate  inflight=%s lost=%s\n' \
    "$(now_iso)" "$gate_inflight" "$gate_lost" >> "$journal"
  # PRD-build-fail-loud-evidence-kept requirement 5: PROBES: line, plus
  # requirement 3's retention prune hooked into this same existing tick
  # cadence rather than a timer of its own.
  local probes_n probes_top_name probes_top_count
  read -r probes_n probes_top_name probes_top_count < <(probe_failed_24h_stats "$journal")
  printf '%s  lane-health  PROBES: failed_24h=%s top=%s:%s\n' \
    "$(now_iso)" "$probes_n" "$probes_top_name" "$probes_top_count" >> "$journal"
  if [ -r "$HERE/lib/probe.sh" ]; then
    # shellcheck source=lib/probe.sh
    source "$HERE/lib/probe.sh"
    probe_prune_logs >/dev/null 2>&1 || true
  fi
  # PRD-build-test-isolation-by-default requirement 8 (P2): surface
  # requirement 7's corpus-lint count on the same standing health line
  # this tick already writes, rather than leaving it something only
  # `lint-journal-fixtures.sh --corpus` by hand would show.
  local fixture_lines_today; fixture_lines_today="$(fixture_lines_today_stat)"
  printf '%s  lane-health  JOURNAL: fixture_lines_today=%s\n' \
    "$(now_iso)" "$fixture_lines_today" >> "$journal"
  # PRD-build-main-push-gate requirement 8 (P2): the tick summary counts
  # `main-push refused` lines so a red-main scare shows up on the same
  # health line ops already reads, instead of only in the raw journal.
  local main_push_refused_today; main_push_refused_today="$(main_push_refused_today_stat "$journal")"
  printf '%s  lane-health  MAIN-PUSH: refused_today=%s\n' \
    "$(now_iso)" "$main_push_refused_today" >> "$journal"
  # PRD-build-branch-gate-scope-artifacts requirement 7 (P1, AC9).
  local bg_pass bg_block bg_deferred_only
  read -r bg_pass bg_block bg_deferred_only < <(branch_gates_stats "$journal")
  printf '%s  lane-health  BRANCH-GATES: branch_gates pass=%s block=%s deferred_only=%s\n' \
    "$(now_iso)" "$bg_pass" "$bg_block" "$bg_deferred_only" >> "$journal"
  echo "appended: $journal"
}

cmd_report() {
  local prd_dir="$HOME/Documents/PRDs" journal_dir="$HOME/brain/journal/build" days=2
  while [ $# -gt 0 ]; do
    case "$1" in
      --prd-dir) prd_dir="$2"; shift 2 ;;
      --journal-dir) journal_dir="$2"; shift 2 ;;
      --days) days="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  echo "== last tick per lane (most recent lane-health line, last $days day(s)) =="
  local -A seen=()
  local d f
  for d in $(seq 0 $((days - 1))); do
    f="$journal_dir/$(date -u -d "-$d day" +%F 2>/dev/null || date -u -v-"${d}"d +%F).md"
    [ -f "$f" ] || continue
    # Scan newest-first within the file so the first hit per lane wins.
    while IFS= read -r line; do
      local lane; lane=$(sed -E 's/.*\(lane=([^)]+)\).*/\1/' <<<"$line")
      [ -n "$lane" ] || continue
      [ -n "${seen[$lane]+x}" ] && continue
      seen[$lane]=1
      echo "$lane: $line"
    done < <(grep '  lane-health  tick  ' "$f" | tac)
  done
  if [ ${#seen[@]} -eq 0 ]; then echo "(no lane-health lines found in the scanned window)"; fi

  echo
  echo "== live and stale claims (build-queue/*.md) =="
  local any=0 pf status
  for pf in "$prd_dir"/build-queue/PRD-*.md; do
    [ -f "$pf" ] || continue
    local lv; lv=$(read_lane_line "$pf")
    [ -z "$lv" ] && continue
    any=1
    status=$("$LANE_CLAIM" status "$pf" 2>/dev/null)
    echo "$(basename "$pf" .md): $status"
  done
  if [ "$any" -eq 0 ]; then echo "(no live claims)"; fi

  echo
  echo "== cargo-budget: last 5 runs (PRD-build-cargo-concurrency-budget) =="
  if [ -x "$CARGO_BUDGET" ]; then
    "$CARGO_BUDGET" last 5
  else
    echo "(cargo-budget.sh not found at $CARGO_BUDGET)"
  fi

  echo
  echo "== open decisions (PRD-build-open-decision-escalation) =="
  if [ -x "$DECISIONS" ]; then
    local dec_json dec_n dec_overdue
    dec_json="$("$DECISIONS" list --json 2>/dev/null || echo '[]')"
    dec_n="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
    dec_overdue="$(printf '%s' "$dec_json" | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if r.get("overdue")))' 2>/dev/null || echo 0)"
    echo "open-decisions=$dec_n overdue=$dec_overdue"
  else
    echo "(decisions.sh not found at $DECISIONS)"
  fi

  echo
  echo "== gate: inflight/lost (state/gate-inflight/*.json, PRD-build-gate-launch-survives-tick) =="
  local gr_inflight gr_lost
  read -r gr_inflight gr_lost < <(gate_inflight_stats)
  echo "inflight=$gr_inflight lost=$gr_lost"
  local gdir="$STATE_DIR/gate-inflight" gf gslug gst
  if [ -d "$gdir" ]; then
    for gf in "$gdir"/*.json; do
      [ -f "$gf" ] || continue
      gslug="$(basename "$gf" .json)"
      gst="$([ -x "$GATE_STATUS" ] && "$GATE_STATUS" "$gslug" 2>/dev/null || echo "?")"
      [ "$gst" = "lost" ] && echo "  lost: $gslug"
    done
  fi
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    tick-summary) [ $# -ge 3 ] || usage; cmd_tick_summary "$@" ;;
    report)       cmd_report "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
