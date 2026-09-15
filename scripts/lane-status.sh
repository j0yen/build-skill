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
