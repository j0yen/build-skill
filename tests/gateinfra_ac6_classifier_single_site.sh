#!/usr/bin/env bash
# tests/gateinfra_ac6_classifier_single_site.sh — PRD-build-gate-finalize-
# verdict-split AC6.
#
# Given both the receipt path and the stdout path in run_reviewer(), When
# either sees a finalize exit, Then both call the same classifier
# function (classify_finalize_exit), and a grep for the
# `_reviewer_infra_kind="finalize-rejected"` assignment in extend-gate.sh
# returns exactly one site (the shared _mark_finalize_refusal helper).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EG="$HERE/../scripts/extend-gate.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

n_assign="$(grep -c '_reviewer_infra_kind="finalize-rejected"' "$EG")"
expect "AC6: exactly one finalize-rejected assignment site" "[ '$n_assign' -eq 1 ]"

n_calls="$(grep -c 'classify_finalize_exit "\$receipt" "\$head_now"\|classify_finalize_exit "\$out" "\$head_now"' "$EG")"
expect "AC6: both the receipt-path and stdout-path finalize call sites invoke classify_finalize_exit" \
  "[ '$n_calls' -eq 2 ]"

n_fn_def="$(grep -c '^classify_finalize_exit() {' "$EG")"
expect "AC6: classify_finalize_exit is defined exactly once" "[ '$n_fn_def' -eq 1 ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac6_classifier_single_site: ALL PASS"
else
  echo "gateinfra_ac6_classifier_single_site: assertion(s) FAILED"
fi
exit "$fail"
