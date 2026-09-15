#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC5: when the prove exit trap fires
# and cmd_down fails (fake hcloud delete failure), a `down-failed` line
# naming the hcloud error is journaled, and the session file is NOT
# cleared.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: down-failed journaled with the hcloud error" \
  "ok  AC5: the session file is NOT cleared"
