#!/usr/bin/env bash
# archive-trailer.sh — emit the `Verified-completed:` and `Deferred:`
# trailer blocks for a PRD's archive commit message, per
# PRD-build-deferred-acs.md AC3 (iter-3).
#
# Usage:
#   archive-trailer.sh <PRD-path> \
#     [--paired N=<evidence>]... [--paired-json '{"2":"...","4":"..."}'] \
#     [--reasons-json '{"1":"...","3":"..."}'] \
#     [--inherited-blocks name1,name2,...]
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
#   --inherited-blocks name1,name2,...  optional
#                         (PRD-build-gate-delta-baseline): the receipt
#                         names a `delta-pass` gate verdict named as
#                         baseline-covered debt — see extend-gate.sh's
#                         `inherited_blocks=` summary field. Comma-
#                         separated. When ABSENT (the common case as of
#                         PRD-build-inherited-blocks-delta-pass requirement
#                         3), auto-populated from the PRD's own `build_into`
#                         repo's `target/autobuilder/last-verdict.json`
#                         (extend-gate.sh's own verdict cache) — an
#                         explicit flag still wins over the auto-read.
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
#   inherited_blocks=[name1, name2]
#
#   Receipts: verdict=delta-pass inherited=2
#
# When `deferred_acs` is empty, the `Deferred:` block is omitted entirely.
# When no ACs are paired, the `Verified-completed:` block is still
# emitted with no body lines (so the gate caller's intent stays visible).
# The `inherited_blocks=[...]` line is emitted whenever the (explicit or
# auto-populated) inherited-blocks value is non-empty. The `Receipts:
# verdict=... inherited=<n>` line (requirement 3, AC4) is emitted whenever
# a verdict was resolvable — from `--inherited-blocks`'s sibling auto-read
# of `build_into`'s last-verdict.json, so it needs no separate flag.
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
  sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

prd=""
paired_json="{}"
reasons_json=""
inherited_blocks=""
declare -a paired_kv=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paired) paired_kv+=("${2:-}"); shift 2 ;;
    --paired=*) paired_kv+=("${1#--paired=}"); shift ;;
    --paired-json) paired_json="${2:-"{}"}"; shift 2 ;;
    --paired-json=*) paired_json="${1#--paired-json=}"; shift ;;
    --reasons-json) reasons_json="${2:-}"; shift 2 ;;
    --reasons-json=*) reasons_json="${1#--reasons-json=}"; shift ;;
    --inherited-blocks) inherited_blocks="${2:-}"; shift 2 ;;
    --inherited-blocks=*) inherited_blocks="${1#--inherited-blocks=}"; shift ;;
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
          ([$line | capture("^(?<k>[0-9]+)=(?<v>.*)$")] | first) as $m
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

# PRD-build-inherited-blocks-delta-pass requirement 3: `--inherited-blocks`
# is populated from attribution AUTOMATICALLY — an explicit flag still wins
# (a caller that already knows the set doesn't pay a second file read), but
# when it's absent, read the PRD's own `build_into` repo's last gate
# verdict (target/autobuilder/last-verdict.json — the same cache
# extend-gate.sh's delta path writes `inherited_blocks`/`verdict` into,
# "last-verdict.json.blocks[] already carries scope; no new producer
# output needed") and derive both the inherited-blocks list and the
# `Receipts:` verdict line from it.
verdict_val=""
build_into_val="$("$JQ" -r --arg s "$slug" '.[] | select(.slug==$s) | .build_into // empty' <<<"$json")"
if [ -n "$build_into_val" ] && [ -f "$build_into_val/target/autobuilder/last-verdict.json" ]; then
  auto_verdict_file="$build_into_val/target/autobuilder/last-verdict.json"
  if [ -z "$inherited_blocks" ]; then
    auto_inherited="$("$JQ" -r '(.inherited_blocks // []) | join(",")' "$auto_verdict_file" 2>/dev/null)"
    [ -n "$auto_inherited" ] && inherited_blocks="$auto_inherited"
  fi
  verdict_val="$("$JQ" -r '.verdict // empty' "$auto_verdict_file" 2>/dev/null)"
fi

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

if [ -n "$inherited_blocks" ]; then
  echo
  echo "inherited_blocks=[${inherited_blocks//,/, }]"
fi

# PRD-build-inherited-blocks-delta-pass requirement 3 (AC4): "the Receipts:
# line reads verdict=delta-pass inherited=<n>" — printed whenever a verdict
# was resolvable (auto from build_into's last gate, above), independent of
# whether inherited_blocks itself is empty (a plain `pass` ship still gets
# `Receipts: verdict=pass inherited=0`).
if [ -n "$verdict_val" ]; then
  n_inherited=0
  if [ -n "$inherited_blocks" ]; then
    n_inherited="$("$JQ" -rn --arg s "$inherited_blocks" '$s | split(",") | length')"
  fi
  echo
  echo "Receipts: verdict=$verdict_val inherited=$n_inherited"
fi

exit 0
