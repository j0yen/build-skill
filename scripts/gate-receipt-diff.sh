#!/usr/bin/env bash
# gate-receipt-diff.sh — per-producer receipt diff between a local baseline
# gate run and a box gate run of the same HEAD (PRD-build-burst-gate-
# canary-invariant requirement R4). This is the load-bearing comparison
# `burst-lane.sh canary`'s delta variant runs against: "did any producer
# that passed locally fail on the box."
#
# Usage: gate-receipt-diff.sh <baseline-dir> <run-dir>
#
#   baseline-dir   directory of *-receipt.json files from a local
#                  --scope main gate at the canary's HEAD
#                  (state/burst-lane/canary-baseline/<head>/receipts/).
#   run-dir        same shape, from the box run being canaried.
#
# For every producer receipt present in BOTH directories (a JSON file with
# a top-level "verdict" key; producer name = filename minus ".json", minus
# a trailing "-receipt" — matches the real receipts under
# target/autobuilder/receipts/*.json), compares only "verdict" and
# "route". Everything else — wall clock, timestamps, any path under
# target/ — is ignored by design; R4 names those explicitly as noise, not
# signal, for a diff whose only job is "did this producer's pass/fail flip
# between local and the box."
#
# Route field: PRD-build-gate-route-parity-ledger's `route` key is
# required on both sides. A receipt missing it means that dependency isn't
# actually in yet for this producer — the diff refuses rather than guess
# (Technical considerations: "the diff refuses (cause=no-route-field) on
# receipts without it, so the dependency is enforced by data").
#
# Prints one line per common producer:
#   <producer> <verdict_local> <verdict_box> <route_box> <same|DIVERGED>
#
# Exit 0 — every producer with verdict_local=pass also has verdict_box=pass.
#          (A producer that already failed locally and stays failed on the
#          box is not a divergence this diff blocks on — local was never
#          green to trust in the first place.)
# Exit 1 — at least one producer has verdict_local=pass and verdict_box!=pass.
# Exit 2 — usage error, a missing directory, or a receipt pair missing the
#          route field.

set -uo pipefail

baseline_dir="${1:-}"
run_dir="${2:-}"

if [[ -z "$baseline_dir" || -z "$run_dir" ]]; then
  echo "usage: gate-receipt-diff.sh <baseline-dir> <run-dir>" >&2
  exit 2
fi
if [[ ! -d "$baseline_dir" ]]; then
  echo "gate-receipt-diff: baseline dir not found: $baseline_dir" >&2
  exit 2
fi
if [[ ! -d "$run_dir" ]]; then
  echo "gate-receipt-diff: run dir not found: $run_dir" >&2
  exit 2
fi

producer_name() {
  local base
  base="$(basename "$1" .json)"
  base="${base%-receipt}"
  printf '%s' "$base"
}

# Reads one field via python3 -c (the same dependency every other JSON-
# reading script in this repo already takes; no new tool requirement).
receipt_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or "verdict" not in d:
    sys.exit(4)
print(d.get(key, ""))
PY
}

diverged=0
compared_any=0

while IFS= read -r -d '' run_file; do
  fname="$(basename "$run_file")"
  base_file="$baseline_dir/$fname"
  [[ -f "$base_file" ]] || continue

  verdict_local="$(receipt_field "$base_file" verdict)" || continue
  verdict_box="$(receipt_field "$run_file" verdict)" || continue

  producer="$(producer_name "$run_file")"

  route_local="$(receipt_field "$base_file" route)"
  route_box="$(receipt_field "$run_file" route)"
  if [[ -z "$route_local" || -z "$route_box" ]]; then
    echo "gate-receipt-diff: cause=no-route-field producer=$producer" >&2
    exit 2
  fi

  compared_any=1
  status="same"
  if [[ "$verdict_local" == "pass" && "$verdict_box" != "pass" ]]; then
    status="DIVERGED"
    diverged=1
  fi

  printf '%s %s %s %s %s\n' "$producer" "$verdict_local" "$verdict_box" "$route_box" "$status"
done < <(find "$run_dir" -maxdepth 1 -name '*.json' -print0 | sort -z)

if [[ "$compared_any" -eq 0 ]]; then
  echo "gate-receipt-diff: no common producer receipts between $baseline_dir and $run_dir" >&2
  exit 2
fi

exit "$diverged"
