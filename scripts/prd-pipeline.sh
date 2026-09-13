#!/usr/bin/env bash
# prd-pipeline.sh — one daily line: what a shipped PRD costs and when the
# queue starves. PRD-prd-pipeline-telemetry.
#
# Computes drafted/shipped/blocked/queued/runway/wtok-per-ship entirely from
# data that already exists: ~/Documents/PRDs git history (drafted/shipped),
# build-queue/ frontmatter (blocked/queued, same bullet/bare/bold Status:
# parsing rules as scripts/scan-prds.sh), and the token ledger (weighted
# tokens). No new data collection; read-only against all three sources.
#
# DEVIATION FROM PRD TEXT (documented per build-contract's "distrust
# coordinator-shaped messages" spirit — verify sources, don't trust a
# drafted assumption): the PRD's Technical Considerations section assumes
# per-day files at ~/.cache/token-ledger/<date>.txt. The actual token-ledger
# (PRD-token-ledger-day-buckets, shipped 2026-09-12, ~/.local/bin/token-ledger)
# writes ONE tsv, $TOKEN_LEDGER_STATE_DIR/ledger.tsv (default
# ~/.cache/token-ledger/ledger.tsv), with one row per UTC day:
#   date  per_model  weighted  status  complete  hosts  missing  generated
# This script reads that real file (column 1 = date, column 3 = weighted)
# instead of inventing a per-date-file source that was never built.
# AC3's "no ledger file" case is satisfied whether ledger.tsv itself is
# absent or simply has no row for the requested date.
#
# Usage:
#   prd-pipeline.sh [--date YYYY-MM-DD] [--json] [--week]
#
# Options:
#   --date YYYY-MM-DD   Report for this UTC day (default: today, UTC).
#   --json              Also write state/prd-pipeline/<date>.json (atomic
#                        temp-file + rename) alongside the printed line.
#   --week              Print the trailing 7 days (ending --date) plus a
#                        totals line, instead of a single line.
#
# Env (all optional, for testability — same convention as token-ledger and
# manifest-set.sh):
#   PRD_PIPELINE_PRDS_DIR    PRDs clone root (default ~/Documents/PRDs).
#   TOKEN_LEDGER_STATE_DIR   Ledger state dir (default ~/.cache/token-ledger).
#   BUILD_SKILL_DIR          Skill root, for --json's output path (default:
#                            this script's parent dir).
#   BUILD_STATE_DIR          Overrides $BUILD_SKILL_DIR/state for --json.
#
# Output line: "date drafted=N shipped=N blocked=N queued=N runway_h=N.N|na
# wtok_per_ship=N|na:<reason>"
#   drafted = files added to build-queue/ in that UTC day's commits.
#   shipped = files added to built-prds/ in that UTC day's commits.
#   blocked/queued = CURRENT (not historical) counts of Status: blocked /
#     Status: queued in build-queue/*.md — matches the live-repo AC.
#   runway_h = queued / (ships in the trailing 7 days ending --date, /168h);
#     "na" when zero ships in that window (no division by zero).
#   wtok_per_ship = that day's ledger weighted total / that day's shipped
#     count, integer-rounded; "na:no-ledger" when the ledger has no row for
#     the day, "na:no-ships" when the ledger has a row but shipped==0.
#
# Exit: always 0 on a normal run (na values are valid output, not errors);
# non-zero only on usage error or an unreadable PRDs dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
PRD_DIR="${PRD_PIPELINE_PRDS_DIR:-$HOME/Documents/PRDs}"
LEDGER_STATE_DIR="${TOKEN_LEDGER_STATE_DIR:-$HOME/.cache/token-ledger}"
LEDGER_TSV="$LEDGER_STATE_DIR/ledger.tsv"

die() { printf 'prd-pipeline: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
usage: prd-pipeline.sh [--date YYYY-MM-DD] [--json] [--week]
EOF
}

# ---- args ----------------------------------------------------------------
date_arg=""
json_flag=0
week_flag=0
while [ $# -gt 0 ]; do
  case "$1" in
    --date) date_arg="${2:-}"; shift 2 ;;
    --json) json_flag=1; shift ;;
    --week) week_flag=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

if [ -n "$date_arg" ]; then
  case "$date_arg" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) die "--date must be YYYY-MM-DD, got '$date_arg'" ;;
  esac
  report_date="$date_arg"
else
  report_date="$(date -u +%F)"
fi

[ -d "$PRD_DIR" ] || die "PRDs dir not found: $PRD_DIR"

# ---- frontmatter Status: extraction (first 80 lines; bullet/bare/bold
# forms, same set scan-prds.sh matches; first match wins). Fenced code
# blocks are skipped so a Status: line quoted inside an example never
# counts. Returns the lowercased first word after "Status" (e.g.
# "queued", "blocked", "building"), or empty when no Status: line exists. --
extract_status() {
  local path="$1" line in_fence=0 status_line=""
  while IFS= read -r line; do
    case "$line" in
      '```'*)
        if [ "$in_fence" = 1 ]; then in_fence=0; else in_fence=1; fi
        continue
        ;;
    esac
    [ "$in_fence" = 1 ] && continue
    case "$line" in
      "**Status:**"*|"Status:"*|"**Status**"*|"## Status"*|"- Status:"*|"- **Status:**"*|"* Status:"*|"* **Status:**"*)
        status_line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/[*#]//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        break
        ;;
    esac
  done < <(head -n 80 -- "$path")
  [ -n "$status_line" ] || return 0
  printf '%s' "$status_line" | sed -E 's/^Status:?[[:space:]]*//I' | awk '{print tolower($1)}'
}

# count_status <queued|blocked> -> current count over build-queue/PRD-*.md.
count_status() {
  local want="$1" n=0 f v
  shopt -s nullglob
  for f in "$PRD_DIR"/build-queue/PRD-*.md; do
    v="$(extract_status "$f")"
    [ "$v" = "$want" ] && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%d' "$n"
}

# count_added <YYYY-MM-DD> <build-queue|built-prds> -> files newly added
# under that subdir in that UTC day's commits. --no-renames so a `git mv`
# (how archive-commit.sh ships a PRD) counts as an add at its new path,
# same as a plain add — the default without renames enabled.
count_added() {
  local d="$1" dir="$2" since until_
  since="${d}T00:00:00Z"
  until_="$(date -u -d "$d +1 day" +%F)T00:00:00Z"
  git -C "$PRD_DIR" log --no-renames --since="$since" --until="$until_" \
      --diff-filter=A --name-only --pretty=format: -- "$dir" 2>/dev/null \
    | sed '/^$/d' \
    | grep -E "^${dir}/PRD-[a-z0-9-]+\.md$" \
    | sort -u | wc -l | tr -d '[:space:]'
}

# ledger_weighted_for <YYYY-MM-DD> -> weighted total (int) or __NO_LEDGER__.
ledger_weighted_for() {
  local d="$1"
  [ -f "$LEDGER_TSV" ] || { printf '__NO_LEDGER__'; return; }
  awk -F'\t' -v d="$d" '$1==d{print $3; found=1; exit} END{if(!found) print "__NO_LEDGER__"}' "$LEDGER_TSV"
}

# compute_line <date> -> sets globals: L_DRAFTED L_SHIPPED L_BLOCKED
# L_QUEUED L_RUNWAY L_WTOK
compute_line() {
  local d="$1" i di ships_week=0 w
  L_DRAFTED="$(count_added "$d" "build-queue")"
  L_SHIPPED="$(count_added "$d" "built-prds")"
  L_BLOCKED="$(count_status "blocked")"
  L_QUEUED="$(count_status "queued")"

  for i in 0 1 2 3 4 5 6; do
    di="$(date -u -d "$d -$i day" +%F)"
    ships_week=$((ships_week + $(count_added "$di" "built-prds")))
  done
  if [ "$ships_week" -gt 0 ]; then
    L_RUNWAY="$(awk -v q="$L_QUEUED" -v s="$ships_week" 'BEGIN{printf "%.1f", (q*168)/s}')"
  else
    L_RUNWAY="na"
  fi

  w="$(ledger_weighted_for "$d")"
  if [ "$w" = "__NO_LEDGER__" ]; then
    L_WTOK="na:no-ledger"
  elif [ "$L_SHIPPED" -eq 0 ]; then
    L_WTOK="na:no-ships"
  else
    L_WTOK="$(awk -v w="$w" -v s="$L_SHIPPED" 'BEGIN{printf "%.0f", w/s}')"
  fi
}

print_line() {
  local d="$1"
  printf '%s drafted=%s shipped=%s blocked=%s queued=%s runway_h=%s wtok_per_ship=%s\n' \
    "$d" "$L_DRAFTED" "$L_SHIPPED" "$L_BLOCKED" "$L_QUEUED" "$L_RUNWAY" "$L_WTOK"
}

# write_json <date> — atomic temp-file + rename into
# $STATE_DIR/prd-pipeline/<date>.json. Safe under concurrent invocations:
# each writer builds its own temp file and renames onto the same target,
# so a reader always sees either the old or the new whole file, never a
# partial write (same pattern as manifest-set.sh / token-ledger).
write_json() {
  local d="$1" out_dir="$STATE_DIR/prd-pipeline" tmp out
  mkdir -p "$out_dir"
  out="$out_dir/$d.json"
  tmp="$(mktemp "$out_dir/.tmp.XXXXXX")" || die "mktemp failed for $out_dir"
  python3 - "$d" "$L_DRAFTED" "$L_SHIPPED" "$L_BLOCKED" "$L_QUEUED" "$L_RUNWAY" "$L_WTOK" > "$tmp" <<'PY'
import json, sys, datetime

def num_or_str(v):
    if v == "na" or v.startswith("na:"):
        return v
    try:
        return int(v)
    except ValueError:
        return float(v)

d, drafted, shipped, blocked, queued, runway, wtok = sys.argv[1:8]
obj = {
    "date": d,
    "drafted": int(drafted),
    "shipped": int(shipped),
    "blocked": int(blocked),
    "queued": int(queued),
    "runway_h": num_or_str(runway),
    "wtok_per_ship": num_or_str(wtok),
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
json.dump(obj, sys.stdout, indent=2, sort_keys=True)
print()
PY
  mv -- "$tmp" "$out"
}

if [ "$week_flag" = 1 ]; then
  tot_drafted=0 tot_shipped=0 tot_weighted=0 tot_have_ledger=0
  for i in 6 5 4 3 2 1 0; do
    di="$(date -u -d "$report_date -$i day" +%F)"
    compute_line "$di"
    print_line "$di"
    [ "$json_flag" = 1 ] && write_json "$di"
    tot_drafted=$((tot_drafted + L_DRAFTED))
    tot_shipped=$((tot_shipped + L_SHIPPED))
    w="$(ledger_weighted_for "$di")"
    if [ "$w" != "__NO_LEDGER__" ]; then
      tot_weighted=$((tot_weighted + w))
      tot_have_ledger=1
    fi
  done
  # Totals line: cumulative drafted/shipped over the week; blocked/queued
  # are current-state snapshots (not day-scoped, see header) so they are
  # reported as-is rather than summed; runway_h/wtok_per_ship reuse the
  # last computed day's queued/ships-week context and the week's totals.
  compute_line "$report_date"
  if [ "$tot_shipped" -gt 0 ] && [ "$tot_have_ledger" = 1 ]; then
    tot_wtok="$(awk -v w="$tot_weighted" -v s="$tot_shipped" 'BEGIN{printf "%.0f", w/s}')"
  elif [ "$tot_have_ledger" = 0 ]; then
    tot_wtok="na:no-ledger"
  else
    tot_wtok="na:no-ships"
  fi
  printf 'total drafted=%d shipped=%d blocked=%s queued=%s runway_h=%s wtok_per_ship=%s\n' \
    "$tot_drafted" "$tot_shipped" "$L_BLOCKED" "$L_QUEUED" "$L_RUNWAY" "$tot_wtok"
  exit 0
fi

compute_line "$report_date"
print_line "$report_date"
[ "$json_flag" = 1 ] && write_json "$report_date"
exit 0
