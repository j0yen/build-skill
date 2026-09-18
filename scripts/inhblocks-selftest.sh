#!/usr/bin/env bash
# inhblocks-selftest.sh — PRD-build-inherited-blocks-delta-pass whole-suite
# entry point. Each of this PRD's non-live ACs (1-5, 7, 8, 9) names this
# script on its own Acceptance-criteria line so verified-completed.sh's
# whole-suite pairing rule (PRD-build-verified-completed-realbox-
# perserver R5) can pair them: the AC's own evidence is this script's exit
# code, not a dedicated per-AC test file, because most of these ACs are
# small, fast, jq/bash-level checks against the scripts named in this
# PRD's Engineering target rather than a full producer-pipeline run.
#
# Usage: inhblocks-selftest.sh
# Exit: 0 iff every assertion in tests/inhblocks_p0_acs.sh passes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/../tests/inhblocks_p0_acs.sh"
