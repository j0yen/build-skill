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
#       build-queue/*.md (via lane-claim.sh status).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_CLAIM="$HERE/lane-claim.sh"

die() { echo "lane-status: $*" >&2; exit "${2:-4}"; }
usage() { echo "usage: lane-status.sh {tick-summary|report} ..." >&2; exit 4; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

read_lane_line() {
  local f="$1"
  head -n 80 "$f" | grep -E '^(- *Lane:|Lane:|\*\*Lane:\*\*)' | head -n1 \
    | sed -E 's/^(- *Lane:|Lane:|\*\*Lane:\*\*)[[:space:]]*//'
}

cmd_tick_summary() {
  local lane="$1" claimed="$2" skipped="$3"
  local journal="${4:-$HOME/brain/journal/build/$(date -u +%F).md}"
  mkdir -p "$(dirname "$journal")" 2>/dev/null || true
  printf '%s  lane-health  tick  claimed=%s skipped=%s  (lane=%s)\n' \
    "$(now_iso)" "$claimed" "$skipped" "$lane" >> "$journal"
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
