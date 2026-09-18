#!/usr/bin/env bash
# Fake extended-receipts.sh for routepar-selftest.sh — stands in for the
# real 17-producer fan-out. Writes two representative producer receipts
# (fake-producer-a.json, fake-producer-b.json) into the SAME
# target/autobuilder/receipts/ dir the rest of the gate uses, so this
# PRD's route-stamp sweep (which globs every *.json in that dir) has more
# than the named 8 phases to prove it generalizes.
set -uo pipefail
proj="${1:-.}"
dir="$proj/target/autobuilder/receipts"
mkdir -p "$dir"
echo '{"producer":"fake-producer-a","verdict":"pass"}' > "$dir/fake-producer-a.json"
echo '{"producer":"fake-producer-b","verdict":"pass"}' > "$dir/fake-producer-b.json"

# PRD-build-cargo-shim-recursion-guard AC5: when FAKE_SHIM_TRIPS=<n> is
# exported, run the REAL cargo-budget-bin shim n times with the depth
# already at the refusal threshold, so the gate's own exported
# $WM_CARGO_SHIM_TRIP_LOG collects n genuine trip lines written by the
# production shim (not by this fixture). Default unset = byte-identical
# behaviour for every other routepar test.
if [ "${FAKE_SHIM_TRIPS:-0}" -gt 0 ] 2>/dev/null; then
  _erfake_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
  _erfake_i=0
  while [ "$_erfake_i" -lt "${FAKE_SHIM_TRIPS}" ]; do
    WM_CARGO_SHIM_DEPTH=2 "$_erfake_root/scripts/cargo-budget-bin/cargo" --version >/dev/null 2>&1
    _erfake_i=$(( _erfake_i + 1 ))
  done
fi

exit "${FAKE_RECEIPTS_RC:-0}"
