#!/usr/bin/env bash
# burstvol_ac7_warm_attribution.sh —
# PRD-build-burst-persistent-volume AC7.
#
# Given a run against an empty remote target, when a second run follows against the now-existing target, then the first journals warm=false, the second journals warm=true, and its attribution.jsonl row carries warm:true.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC7: first run (empty remote target) exits 0" \
  "ok  burstvol AC7: first run journaled warm=false" \
  "ok  burstvol AC7: second run (target now exists) exits 0" \
  "ok  burstvol AC7: second run journaled warm=true" \
  "ok  burstvol AC7: attribution.jsonl's second run row carries warm:true"
