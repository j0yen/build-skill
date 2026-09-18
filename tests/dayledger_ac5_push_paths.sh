#!/usr/bin/env bash
# dayledger_ac5_push_paths.sh — PRD-build-day-ledger AC5: a fixture PRDs
# repo with a remote gains exactly one 'day-ledger: <date>' commit
# touching only that day's file; a remote ahead by one unrelated commit
# rebases and pushes cleanly; a refused push leaves the file present
# locally, journals 'day-ledger push-failed', and exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5a: normal push lands exactly one 'day-ledger: <date>' commit" \
  "ok  AC5a: commit touches only the day's ledger file" \
  "ok  AC5b: rebased onto the sibling's commit and pushed cleanly" \
  "ok  AC5c: exit code on push refusal (0)" \
  "ok  AC5c: file exists locally after a refused push" \
  "ok  AC5c: journal has 'day-ledger push-failed'"
