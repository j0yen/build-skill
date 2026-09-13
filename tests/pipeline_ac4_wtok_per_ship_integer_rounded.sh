#!/usr/bin/env bash
# pipeline_ac4_wtok_per_ship_integer_rounded.sh — PRD-prd-pipeline-telemetry
# AC4: given a day with ledger present and >0 ships, when the script runs,
# then wtok_per_ship equals the ledger weighted total divided by ships,
# integer-rounded. Covers an exact division and a rounding case.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/prd-pipeline.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ledger="$tmp/ledger"; mkdir -p "$ledger"
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n2026-09-12\tsonnet=100\t100\tbudget off\tyes\ttest\t\t2026-09-13T00:00:00Z\n' > "$ledger/ledger.tsv"

fails=0

# exact: weighted=100 / shipped=1 -> 100
repo1="$tmp/prds1"
mkdir -p "$repo1/build-queue" "$repo1/built-prds"
git -C "$repo1" init -q
git -C "$repo1" config user.email test@example.com
git -C "$repo1" config user.name "Test"
printf 'x\n' > "$repo1/built-prds/PRD-one.md"
git -C "$repo1" add built-prds
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repo1" commit -q -m "one ship"
out1="$(PRD_PIPELINE_PRDS_DIR="$repo1" TOKEN_LEDGER_STATE_DIR="$ledger" "$SCRIPT" --date 2026-09-12)"
if printf '%s' "$out1" | grep -q 'wtok_per_ship=100'; then
  echo "ok  AC4: wtok_per_ship=100 for weighted=100/shipped=1"
else
  echo "FAIL AC4: expected wtok_per_ship=100, got: $out1"; fails=1
fi

# rounding: weighted=100 / shipped=3 -> round(33.33)=33
repo3="$tmp/prds3"
mkdir -p "$repo3/build-queue" "$repo3/built-prds"
git -C "$repo3" init -q
git -C "$repo3" config user.email test@example.com
git -C "$repo3" config user.name "Test"
for n in one two three; do printf 'x\n' > "$repo3/built-prds/PRD-$n.md"; done
git -C "$repo3" add built-prds
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repo3" commit -q -m "three ships"
out3="$(PRD_PIPELINE_PRDS_DIR="$repo3" TOKEN_LEDGER_STATE_DIR="$ledger" "$SCRIPT" --date 2026-09-12)"
if printf '%s' "$out3" | grep -q 'wtok_per_ship=33'; then
  echo "ok  AC4: wtok_per_ship=33 for weighted=100/shipped=3 (integer-rounded)"
else
  echo "FAIL AC4: expected wtok_per_ship=33, got: $out3"; fails=1
fi

exit "$fails"
