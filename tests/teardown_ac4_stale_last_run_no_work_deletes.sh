#!/usr/bin/env bash
# teardown_ac4_stale_last_run_no_work_deletes.sh — PRD-build-burst-teardown-
# evidence AC4.
#
# Given a box whose last routed run is 61 minutes old and no Rust or Python
# PRD queued, when teardown_decision() (the function `down` is meant to
# consult) runs, then the decision is delete cause=idle-no-work.
#
# NOTE (build-time scope note, matches this PRD's own build record): this
# exercises teardown_decision() directly, not `down`'s own ACTING logic —
# requirement 2's full rewiring of `down` onto this function is a follow-on
# (see the teardown block's own header comment in burst-lane-selftest.sh for
# why: a concurrent sibling PRD was editing cmd_down's own body in the same
# unisolated checkout at build time, and the rewiring needs updating several
# pre-existing hard-coded `down` assertions elsewhere in the suite in
# lockstep).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC4: decision=delete" \
  "ok  teardown AC4: cause=idle-no-work"
