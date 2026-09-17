#!/usr/bin/env bash
# gate-red-summary.sh — R1 of PRD-build-gate-red-alarm-invariant.
#
# Aggregates the last GATE_RED_WINDOW_H hours (default 3) of the build
# journal into ONE line naming green count, red count, blocker families
# with counts, the oldest red timestamp, and the still-red slugs — the
# aggregate that did not exist on 2026-09-16 when six mcphost branches
# went gate-red for 7h20m with nothing anywhere saying so (see this PRD's
# TL;DR). Supersedes the 2026-09-16 stopgap `~/.local/bin/gate-red-alarm.sh`
# (R7 retires it once this is wired into select-tick.sh via R2); this
# script reproduces that stopgap's aggregation logic, made testable and
# durable (JSON twin, parse-skip counting, atomic writes).
#
# Journal line shapes this reads (see build-contract.md's "Technical
# considerations" for the PRD, and the real journal for ground truth):
#   <ts>  gate-then-land  <slug>  gate-block attempt=<n> blockers=<csv>
#   <ts>  <slug>  verify-gate-red-unchanged  blocked-not-retried  (...)
#   <ts>  gate-then-land  <slug>  landed attempt=<n> ...
#   <ts>  <slug>  archive  archived  (...)
#   <ts>  gate  <crate>  <pass|block>  (scope=main slug=<S> head=<M> ...) pinned=landing
#   <ts>  gate  <crate>  <pass|block>  (scope=main slug=main-health head=<N> ...) main-health
# The last two (PRD-build-main-verdict-pinned-to-landing R9) are
# extend-gate.sh's own journal_line, not gate-then-land's — tracked under
# a slug@sha7 (or repo@sha7 main-health) composite key so a block at one
# M is never conflated with a pass at a different M for the same slug.
# Continuation lines with no leading timestamp (`  ACTION: ...`) are
# skipped and counted in `parse_skipped` — never fatal (AC3).
#
# A slug seen both red and green in the window counts as green ONLY if
# its green line is strictly newer than its red line (requirement R1).
# Blocker family counts are over every `blockers=<csv>` token in ANY
# gate-block-shaped line in the window, regardless of whether that slug's
# later line turned it green — this matches the stopgap's behavior and
# AC1's worked example (a slug that gate-blocked and later landed still
# contributes to the family tally, it just doesn't appear in red_slugs).
#
# Usage:
#   gate-red-summary.sh [--window-h N] [--now ISO_TS]
#
# Env:
#   GATE_RED_WINDOW_H   default window in hours (default 3); --window-h overrides.
#   GATE_RED_NOW        same as --now, for deterministic tests; --now overrides.
#   BUILD_JOURNAL_ROOT  journal directory (see lib/journal.sh); test isolation knob.
#   BUILD_STATE_DIR     where gate-red.summary / gate-red.json are written.
#
# Writes (atomic: tempfile + rename):
#   $BUILD_STATE_DIR/gate-red.summary   "<ts> <one-line summary>"
#   $BUILD_STATE_DIR/gate-red.json      {ts, window_h, green, red, families,
#                                        oldest_red, red_slugs, parse_skipped}
#
# Prints the summary line (without the leading write-ts) on stdout.
#
# Exit: 0 always on a well-formed invocation (a malformed journal line is
#       skipped, not fatal — non-functional requirement) | 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
STATE_DIR="$BUILD_STATE_DIR"
SUMMARY_FILE="${GATE_RED_SUMMARY_FILE:-$STATE_DIR/gate-red.summary}"
JSON_FILE="${GATE_RED_JSON_FILE:-$STATE_DIR/gate-red.json}"
JQ="${JQ:-jq}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

usage() { echo "usage: gate-red-summary.sh [--window-h N] [--now ISO_TS]" >&2; exit 2; }

window_h="${GATE_RED_WINDOW_H:-3}"
now_override="${GATE_RED_NOW:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --window-h) window_h="${2:-}"; shift 2 ;;
    --now) now_override="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "gate-red-summary: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$window_h" in
  ''|*[!0-9]*) echo "gate-red-summary: --window-h/GATE_RED_WINDOW_H must be a positive integer" >&2; exit 2 ;;
esac

now="${now_override:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
since="$(date -u -d "$now - ${window_h} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
if [ -z "$since" ]; then
  echo "gate-red-summary: could not compute window start from --now=$now" >&2
  exit 2
fi

root="$(journal_root)"

# Walk every day-stamped journal file that could hold a line in [since, now]
# (inclusive on both ends; since/now share the day-file's YYYY-MM-DD name).
since_day="${since%%T*}"
now_day="${now%%T*}"
days=()
d="$since_day"
guard=0
while :; do
  days+=("$d")
  [ "$d" = "$now_day" ] && break
  d="$(date -u -d "$d + 1 day" +%F 2>/dev/null)" || break
  guard=$((guard + 1))
  [ "$guard" -gt 400 ] && break
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gate-red-summary.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

raw_lines="$work_dir/raw.txt"
: > "$raw_lines"
for d in "${days[@]}"; do
  f="$root/$d.md"
  [ -r "$f" ] && cat "$f" >> "$raw_lines"
done

# Filter to [since, now], tagging skipped (no leading ISO ts) lines separately.
filtered="$work_dir/filtered.txt"
skip_marker="$work_dir/skipped.count"
awk -v since="$since" -v now="$now" '
  /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
    ts = $1
    if (ts >= since && ts <= now) print
    next
  }
  { skipped++ }
  END { print skipped+0 > "'"$skip_marker"'" }
' "$raw_lines" > "$filtered"
parse_skipped="$(cat "$skip_marker" 2>/dev/null || echo 0)"
[ -z "$parse_skipped" ] && parse_skipped=0

# One classification pass: red/green per slug (newest wins per the rule
# above), blocker family counts, and the oldest red line's timestamp
# (first red-pattern line encountered — the journal is append-only
# chronological, so first-encountered is oldest).
class_out="$work_dir/class.txt"
awk '
  function fam_add(csv,    n, arr, i) {
    n = split(csv, arr, ",")
    for (i = 1; i <= n; i++) if (arr[i] != "") fam_count[arr[i]]++
  }
  {
    ts = $1
    # PRD-build-reviewer-receipt-primary R6/R10: a family name can now be
    # "<producer>:<reason>" (e.g. reviewer-agent:must-ac-failing-at-head)
    # — the char class here used to stop at the first `:`, silently
    # truncating every reason-qualified name back to the bare producer.
    if (match($0, /blockers=[A-Za-z0-9,_:-]+/)) {
      fam_add(substr($0, RSTART + 9, RLENGTH - 9))
    }
    is_red = 0
    slug = ""
    if ($2 == "gate-then-land" && $4 ~ /^gate-block/) { is_red = 1; slug = $3 }
    else if ($3 ~ /^verify-gate-red/) { is_red = 1; slug = $2 }
    if (is_red && slug != "") {
      if (!(slug in red_ts) || ts > red_ts[slug]) red_ts[slug] = ts
      if (oldest_red == "") oldest_red = ts
      seen[slug] = 1
      next
    }
    is_green = 0
    gslug = ""
    if ($2 == "gate-then-land" && ($4 == "landed" || $4 == "gate-pass" || $4 == "land")) { is_green = 1; gslug = $3 }
    else if ($3 == "archive" && $4 == "archived") { is_green = 1; gslug = $2 }
    if (is_green && gslug != "") {
      if (!(gslug in green_ts) || ts > green_ts[gslug]) green_ts[gslug] = ts
      seen[gslug] = 1
    }
    # PRD-build-main-verdict-pinned-to-landing R9/AC11: extend-gate.sh
    # writes its OWN "gate <crate> <outcome> (...)" line (see extend-gate.sh
    # journal_line call, scope_prefix + journal_suffix) — a third shape
    # this classifier never recognized before (only gate-then-land/
    # verify-gate-red/archive lines, above). A pinned main-scope run
    # ($2=="gate", trailing " pinned=landing") or a bare-HEAD main-health
    # run (trailing " main-health") is tracked under a composite key so a
    # block at a *different* M is never attributed to this M (AC11 "never
    # attributed to S"), and a main-health red is keyed by repo@sha7 per
    # R6, not by the "main-health" sentinel slug alone.
    if ($2 == "gate" && match($0, /slug=[^ ]+/)) {
      pin_slug = substr($0, RSTART + 5, RLENGTH - 5)
      pin_head7 = ""
      if (match($0, /head=[^ ]+/)) pin_head7 = substr(substr($0, RSTART + 5, RLENGTH - 5), 1, 7)
      pin_is_mainhealth = ($0 ~ / main-health$/)
      pin_is_pinned = ($0 ~ / pinned=landing$/)
      if ((pin_is_mainhealth || pin_is_pinned) && pin_head7 != "") {
        pin_key = pin_is_mainhealth ? ($3 "@" pin_head7 " main-health") : (pin_slug "@" pin_head7)
        if ($4 == "block") {
          if (!(pin_key in red_ts) || ts > red_ts[pin_key]) red_ts[pin_key] = ts
          if (oldest_red == "") oldest_red = ts
          seen[pin_key] = 1
        } else if ($4 == "pass") {
          if (!(pin_key in green_ts) || ts > green_ts[pin_key]) green_ts[pin_key] = ts
          seen[pin_key] = 1
        }
      }
    }
  }
  END {
    green_n = 0
    for (s in seen) {
      isgreen = 0
      if (s in green_ts) {
        if (!(s in red_ts)) isgreen = 1
        else if (green_ts[s] > red_ts[s]) isgreen = 1
      }
      if (isgreen) { green_n++ }
      else { print "RED_SLUG\t" s }
    }
    print "COUNT_GREEN\t" green_n
    print "OLDEST_RED\t" oldest_red
    for (f in fam_count) print "FAM\t" f "\t" fam_count[f]
  }
' "$filtered" > "$class_out"

red_slugs="$(awk -F'\t' '$1=="RED_SLUG"{print $2}' "$class_out" | sort -u)"
red_n="$(printf '%s\n' "$red_slugs" | grep -c . || true)"
[ -z "$red_slugs" ] && red_n=0
green_n="$(awk -F'\t' '$1=="COUNT_GREEN"{print $2}' "$class_out")"
green_n="${green_n:-0}"
oldest_red="$(awk -F'\t' '$1=="OLDEST_RED"{print $2}' "$class_out")"

# Families sorted by count desc, then name asc, for a deterministic line.
fam_sorted="$(awk -F'\t' '$1=="FAM"{printf "%s\t%s\n", $3, $2}' "$class_out" | sort -t$'\t' -k1,1nr -k2,2)"
fam_display=""
fam_json="{}"
if [ -n "$fam_sorted" ]; then
  fam_display="$(printf '%s\n' "$fam_sorted" | awk -F'\t' '{printf "%s x%s ", $2, $1}' | sed 's/ $//')"
  fam_json="$(printf '%s\n' "$fam_sorted" | awk -F'\t' '{printf "%s\t%s\n", $2, $1}' | "$JQ" -R -s '
    split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): (.[1] | tonumber)}) | add // {}
  ')"
fi
[ -z "$fam_display" ] && fam_display="none"

red_slugs_display="$(printf '%s\n' "$red_slugs" | grep -c . >/dev/null; printf '%s' "$red_slugs" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
red_slugs_json="$(printf '%s\n' "$red_slugs" | "$JQ" -R -s 'split("\n") | map(select(length > 0))')"

oldest_display="${oldest_red:-none}"

summary_line="GATES(${window_h}h): green=${green_n} red=${red_n} blockers: ${fam_display} oldest-red=${oldest_display} red_slugs: ${red_slugs_display}"

write_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$STATE_DIR"

tmp_summary="$(mktemp "$STATE_DIR/.gate-red.summary.XXXXXX")"
printf '%s %s\n' "$write_ts" "$summary_line" > "$tmp_summary"
mv -f "$tmp_summary" "$SUMMARY_FILE"

tmp_json="$(mktemp "$STATE_DIR/.gate-red.json.XXXXXX")"
"$JQ" -n \
  --arg ts "$write_ts" \
  --argjson window_h "$window_h" \
  --argjson green "$green_n" \
  --argjson red "$red_n" \
  --argjson families "$fam_json" \
  --arg oldest_red "$oldest_display" \
  --argjson red_slugs "$red_slugs_json" \
  --argjson parse_skipped "$parse_skipped" \
  '{ts:$ts, window_h:$window_h, green:$green, red:$red, families:$families,
    oldest_red:$oldest_red, red_slugs:$red_slugs, parse_skipped:$parse_skipped}' \
  > "$tmp_json"
mv -f "$tmp_json" "$JSON_FILE"

printf '%s\n' "$summary_line"
exit 0
