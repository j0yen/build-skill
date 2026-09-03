#!/usr/bin/env bash
# archive-trailer.sh — emit the `Verified-completed:` and `Deferred:`
# trailer blocks for a PRD's archive commit message, per
# PRD-build-deferred-acs.md AC3 (iter-3).
#
# Usage:
#   archive-trailer.sh <PRD-path> \
#     [--paired N=<evidence>]... [--paired-json '{"2":"...","4":"..."}'] \
#     [--reasons-json '{"1":"...","3":"..."}']
#
# Inputs:
#   <PRD-path>            absolute or relative path to a PRD-*.md file.
#   --paired N=<evidence> repeatable: maps AC number N to a free-form
#                         evidence string (test name, smoke command,
#                         live-snapshot path). Splits on the first `=`
#                         so the evidence may contain `=`.
#   --paired-json '{...}' alternate input form: JSON object with
#                         string-encoded integer keys and evidence
#                         string values. Merged AFTER --paired flags,
#                         so JSON wins on overlap.
#   --reasons-json '{...}' optional: override the `deferred_ac_reasons`
#                         from scan-prds.sh (scan-prds today emits an
#                         empty stub `{}` since the block-list YAML
#                         dict isn't parsed yet; this flag lets callers
#                         inject reasons until that lands).
#
# Output (stdout):
#   Verified-completed:
#     AC2 — paired with <evidence>
#     AC4 — paired with <evidence>
#
#   Deferred:
#     AC1 — <reason or "(no reason given)">
#     AC3 — <reason or "(no reason given)">
#
# When `deferred_acs` is empty, the `Deferred:` block is omitted entirely.
# When no ACs are paired, the `Verified-completed:` block is still
# emitted with no body lines (so the gate caller's intent stays visible).
#
# Exit codes:
#   0  trailer emitted; every AC is paired-or-deferred.
#   1  one or more ACs are neither paired nor deferred. Trailer is NOT
#      emitted; stderr lists the gaps.
#   2  usage / setup error.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-prds.sh"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

prd=""
paired_json="{}"
reasons_json=""
declare -a paired_kv=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paired) paired_kv+=("${2:-}"); shift 2 ;;
    --paired=*) paired_kv+=("${1#--paired=}"); shift ;;
    --paired-json) paired_json="${2:-{}}"; shift 2 ;;
    --paired-json=*) paired_json="${1#--paired-json=}"; shift ;;
    --reasons-json) reasons_json="${2:-}"; shift 2 ;;
    --reasons-json=*) reasons_json="${1#--reasons-json=}"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "archive-trailer: unknown flag $1" >&2; exit 2 ;;
    *) prd="$1"; shift ;;
  esac
done

[ -n "$prd" ] || { echo "archive-trailer: PRD path required" >&2; exit 2; }
[ -r "$prd" ] || { echo "archive-trailer: $prd not readable" >&2; exit 2; }
[ -x "$SCAN" ] || { echo "archive-trailer: $SCAN not executable" >&2; exit 2; }
[ -x "$JQ" ] || { echo "archive-trailer: jq not at $JQ" >&2; exit 2; }

# Build the paired-evidence map by merging --paired flags first, then
# --paired-json on top.
paired_merged="$(
  printf '%s\n' "${paired_kv[@]+"${paired_kv[@]}"}" \
    | "$JQ" -Rn --argjson seed "$paired_json" '
        reduce inputs as $line ($seed;
          ($line | capture("^(?<k>[0-9]+)=(?<v>.*)$")) as $m
          | if $m then . + {($m.k): $m.v} else . end)' 2>/dev/null
)" || {
  echo "archive-trailer: --paired-json is not valid JSON" >&2; exit 2; }

base="$(basename "$prd")"
slug="${base#PRD-}"; slug="${slug%.md}"
prd_dir="$(cd "$(dirname "$prd")" && pwd)"

json="$(PRD_DIR="$prd_dir" "$SCAN")" || {
  echo "archive-trailer: scan-prds.sh failed" >&2; exit 2; }

deferred="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .deferred_acs // []' <<<"$json")"
[ -n "$deferred" ] || deferred="[]"

if [ -n "$reasons_json" ]; then
  reasons="$reasons_json"
else
  reasons="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .deferred_ac_reasons // {}' <<<"$json")"
  [ -n "$reasons" ] || reasons="{}"
fi

# Count ACs by scanning the Acceptance heading.
num_acs="$(awk '
  /^##[[:space:]]+([[:digit:]]+\.[[:space:]]+)?Acceptance/ { in_block=1; next }
  /^##[[:space:]]/ && in_block            { in_block=0 }
  in_block && /^[[:digit:]]+\.[[:space:]]/ { n++ }
  END { print n+0 }
' "$prd")"

if [ "$num_acs" -le 0 ]; then
  echo "archive-trailer: no ACs found in $prd" >&2; exit 2
fi

# Classify each AC.
declare -A is_deferred reason_for paired_evidence
while IFS= read -r n; do
  case "$n" in
    ''|*[!0-9]*) continue ;;
    *) is_deferred[$n]=1 ;;
  esac
done < <("$JQ" -r '.[]?' <<<"$deferred")

while IFS=$'\t' read -r k v; do
  [ -n "$k" ] || continue
  reason_for[$k]="$v"
done < <("$JQ" -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$reasons" 2>/dev/null)

while IFS=$'\t' read -r k v; do
  [ -n "$k" ] || continue
  paired_evidence[$k]="$v"
done < <("$JQ" -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$paired_merged" 2>/dev/null)

paired_lines=()
deferred_lines=()
missing=()
for ((i=1; i<=num_acs; i++)); do
  if [ -n "${paired_evidence[$i]:-}" ]; then
    paired_lines+=("  AC$i — paired with ${paired_evidence[$i]}")
  elif [ -n "${is_deferred[$i]:-}" ]; then
    r="${reason_for[$i]:-}"
    [ -n "$r" ] || r="(no reason given)"
    deferred_lines+=("  AC$i — $r")
  else
    missing+=("$i")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  for n in "${missing[@]}"; do
    echo "AC$n: not paired (and not declared deferred)" >&2
  done
  exit 1
fi

echo "Verified-completed:"
for line in "${paired_lines[@]+"${paired_lines[@]}"}"; do
  printf '%s\n' "$line"
done

if [ "${#deferred_lines[@]}" -gt 0 ]; then
  echo
  echo "Deferred:"
  for line in "${deferred_lines[@]}"; do
    printf '%s\n' "$line"
  done
fi

exit 0
