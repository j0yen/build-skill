#!/usr/bin/env bash
# verified-completed.sh — Phase 5 archive-gate check #5 per
# PRD-build-deferred-acs.md. Classifies every AC in a PRD as
# PAIRED, DEFERRED, or MISSING, and exits non-zero when any AC is
# MISSING.
#
# Usage:
#   verified-completed.sh <PRD-path> [--paired N,N,...] [--format text|json]
#       [--doctor] [--paired-with N=<evidence>]... [--reasons-json '{...}']
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
#   --doctor               human-readable per-AC audit (AC6/§6 of the
#                          PRD). Each line is `AC<N>: <STATUS><pad> —
#                          <evidence or reason>`. STATUS is one of
#                          PAIRED, DEFERRED, MISSING; padded to width 8
#                          so the em-dashes align. Evidence comes from
#                          --paired-with; reason comes from
#                          --reasons-json or scan-prds' deferred_ac_
#                          reasons; missing evidence shows `(no test)`
#                          and missing reason shows `(no reason given)`.
#                          Implies --format=text; ignored under json.
#   --paired-with N=<evi>  repeatable: maps AC number N to a free-form
#                          evidence string for --doctor. Splits on the
#                          first `=` so evidence may contain `=`. Does
#                          NOT promote an AC to PAIRED on its own —
#                          --paired is still the authoritative classifier.
#   --reasons-json '{...}' optional: override the `deferred_ac_reasons`
#                          map from scan-prds.sh (which currently
#                          stubs to `{}`). Same shape as the matching
#                          flag in archive-trailer.sh.
#
# Behavior:
#   1. Counts ACs by scanning the PRD's `## Acceptance` (or
#      `## Acceptance criteria` / `## Acceptance tests`) section for
#      lines like `^N. `.
#   2. Resolves `deferred_acs` (and, under --doctor, `deferred_ac_
#      reasons`) via scan-prds.sh, scoped to the PRD's parent directory.
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
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

prd=""
paired_csv=""
format=text
doctor=false
reasons_json=""
declare -a paired_with_kv=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paired) paired_csv="${2:-}"; shift 2 ;;
    --paired=*) paired_csv="${1#--paired=}"; shift ;;
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#--format=}"; shift ;;
    --doctor) doctor=true; shift ;;
    --paired-with) paired_with_kv+=("${2:-}"); shift 2 ;;
    --paired-with=*) paired_with_kv+=("${1#--paired-with=}"); shift ;;
    --reasons-json) reasons_json="${2:-}"; shift 2 ;;
    --reasons-json=*) reasons_json="${1#--reasons-json=}"; shift ;;
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

if [ "$doctor" = true ]; then
  if [ -n "$reasons_json" ]; then
    reasons="$reasons_json"
  else
    reasons="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .deferred_ac_reasons // {}' <<<"$json")"
    [ -n "$reasons" ] || reasons="{}"
  fi
fi

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

declare -A is_paired is_deferred reason_for paired_evidence
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

if [ "$doctor" = true ]; then
  # Parse --paired-with K=V flags.
  for kv in "${paired_with_kv[@]+"${paired_with_kv[@]}"}"; do
    case "$kv" in
      *=*)
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
          ''|*[!0-9]*) continue ;;
          *) paired_evidence[$k]="$v" ;;
        esac
        ;;
    esac
  done
  # Parse reasons-json into reason_for.
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    reason_for[$k]="$v"
  done < <("$JQ" -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"${reasons:-{\}}" 2>/dev/null)
fi

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
elif [ "$doctor" = true ]; then
  # Padded width = 8 (DEFERRED is widest). Right-pad with spaces so the
  # em-dash column aligns across statuses. Example:
  #   AC1: DEFERRED — wake-to-event latency requires real mic
  #   AC2: PAIRED   — tests/cli.rs::greet_within_15s
  for line in "${results[@]}"; do
    n="${line%% *}"; cls="${line#* }"
    case "$cls" in
      PAIRED)
        evi="${paired_evidence[$n]:-}"
        [ -n "$evi" ] || evi="(no test)"
        printf 'AC%s: %-8s — %s\n' "$n" "$cls" "$evi"
        ;;
      DEFERRED)
        r="${reason_for[$n]:-}"
        [ -n "$r" ] || r="(no reason given)"
        printf 'AC%s: %-8s — %s\n' "$n" "$cls" "$r"
        ;;
      MISSING)
        printf 'AC%s: %-8s — %s\n' "$n" "$cls" "(not paired, not deferred)"
        ;;
    esac
  done
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
