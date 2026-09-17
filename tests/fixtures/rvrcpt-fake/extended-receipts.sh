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
exit "${FAKE_RECEIPTS_RC:-0}"
