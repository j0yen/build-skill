#!/usr/bin/env bash
# verified-completed.sh — Phase 5 archive-gate check #5 per
# PRD-build-deferred-acs.md. Classifies every AC in a PRD as
# PAIRED, DEFERRED, or MISSING, and exits non-zero when any AC is
# MISSING.
#
# Usage:
#   verified-completed.sh <PRD-path> [--paired N,N,...] [--format text|json]
#
# Inputs:
#   <PRD-path>             absolute or relative path to a PRD-*.md file.
#   --paired N,N,...       comma-separated list of AC numbers that the
#                          caller asserts are paired with a passing
#                          test. In production /build will derive this
#                          from manifest.prds[<slug>].verification keys;
#                          the script accepts it as an opaque list so
#                          test fixtures and one-off audits can drive
#                          it directly.
#   --format text|json     output format (default: text).
#
# Behavior:
#   1. Counts ACs by scanning the PRD's `## Acceptance` (or
#      `## Acceptance criteria` / `## Acceptance tests`) section for
#      lines like `^N. `.
#   2. Resolves `deferred_acs` via scan-prds.sh, scoped to the PRD's
#      parent directory.
#   3. For each AC 1..N: PAIRED if N ∈ --paired; otherwise DEFERRED if
#      N ∈ deferred_acs; otherwise MISSING.
#   4. Emits classifications on stdout. On any MISSING AC, also emits
#      `AC<N>: not paired (and not declared deferred)` lines on stderr
#      and exits 1. Exit 0 when every AC is PAIRED or DEFERRED.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-prds.sh"
JQ="${JQ:-/usr/sbin/jq}"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

prd=""
paired_csv=""
format=text
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paired) paired_csv="${2:-}"; shift 2 ;;
    --paired=*) paired_csv="${1#--paired=}"; shift ;;
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#--format=}"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "verified-completed: unknown flag $1" >&2; exit 2 ;;
    *) prd="$1"; shift ;;
  esac
done

[ -n "$prd" ] || { echo "verified-completed: PRD path required" >&2; exit 2; }
[ -r "$prd" ] || { echo "verified-completed: $prd not readable" >&2; exit 2; }
[ -x "$SCAN" ] || { echo "verified-completed: $SCAN not executable" >&2; exit 2; }
[ -x "$JQ" ] || { echo "verified-completed: jq not at $JQ" >&2; exit 2; }
case "$format" in text|json) ;; *) echo "verified-completed: bad --format $format" >&2; exit 2 ;; esac

base="$(basename "$prd")"
slug="${base#PRD-}"; slug="${slug%.md}"
prd_dir="$(cd "$(dirname "$prd")" && pwd)"

# scan-prds.sh emits the deferred_acs list verbatim (see iter-1).
json="$(PRD_DIR="$prd_dir" "$SCAN")" || {
  echo "verified-completed: scan-prds.sh failed" >&2; exit 2; }
deferred="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .deferred_acs // []' <<<"$json")"
[ -n "$deferred" ] || deferred="[]"

# Count ACs by scanning the Acceptance heading.
num_acs="$(awk '
  # Match `## Acceptance...` or `## N. Acceptance...` (any trailing words).
  /^##[[:space:]]+([[:digit:]]+\.[[:space:]]+)?Acceptance/ { in_block=1; next }
  /^##[[:space:]]/ && in_block            { in_block=0 }
  in_block && /^[[:digit:]]+\.[[:space:]]/ { n++ }
  END { print n+0 }
' "$prd")"

if [ "$num_acs" -le 0 ]; then
  echo "verified-completed: no ACs found in $prd" >&2; exit 2
fi

declare -A is_paired is_deferred
if [ -n "$paired_csv" ]; then
  IFS=',' read -ra paired_arr <<<"$paired_csv"
  for n in "${paired_arr[@]}"; do
    n="${n//[[:space:]]/}"
    case "$n" in
      ''|*[!0-9]*) continue ;;
      *) is_paired[$n]=1 ;;
    esac
  done
fi
while IFS= read -r n; do
  case "$n" in
    ''|*[!0-9]*) continue ;;
    *) is_deferred[$n]=1 ;;
  esac
done < <("$JQ" -r '.[]?' <<<"$deferred")

missing=()
results=()
for ((i=1; i<=num_acs; i++)); do
  if [ -n "${is_paired[$i]:-}" ]; then
    cls=PAIRED
  elif [ -n "${is_deferred[$i]:-}" ]; then
    cls=DEFERRED
  else
    cls=MISSING
    missing+=("$i")
  fi
  results+=("$i $cls")
done

if [ "$format" = json ]; then
  payload="$(printf '%s\n' "${results[@]}" \
    | "$JQ" -Rn --arg slug "$slug" --argjson num "$num_acs" \
        '[inputs | split(" ") | {ac:(.[0]|tonumber), status:.[1]}]
         | {slug:$slug, num_acs:$num, classifications:.,
            missing:[.[]|select(.status=="MISSING")|.ac]}')"
  printf '%s\n' "$payload"
else
  for line in "${results[@]}"; do
    n="${line%% *}"; cls="${line#* }"
    echo "AC$n: $cls"
  done
fi

if [ "${#missing[@]}" -gt 0 ]; then
  for n in "${missing[@]}"; do
    echo "AC$n: not paired (and not declared deferred)" >&2
  done
  exit 1
fi
exit 0
