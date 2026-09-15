#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC7: a corrupted verdict cache JSON is
# journaled as `verdict-cache corrupt` and removed, rather than falling
# through the tree/hash checks as a silent, cause-less miss.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC7: verdict-cache corrupt journaled" \
  "ok  AC7: the corrupt cache file is removed" \
  "ok  AC7 (structural): extend-gate.sh's real source still detects+removes a corrupt cache"
