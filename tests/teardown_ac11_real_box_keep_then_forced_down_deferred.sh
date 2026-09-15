#!/usr/bin/env bash
# teardown_ac11_real_box_keep_then_forced_down_deferred.sh — PRD-build-
# burst-teardown-evidence AC11 (P0).
#
# Given the same real box after one routed `cargo test` from a worktree,
# when idle-guard runs, then the decision is keep with evidence.
# last_routed_run within the last 10 minutes and evidence.server_created
# equal to hcloud's value; then `down --force` tears it down and
# `why-down <id>` prints the keep row followed by the forced-delete row.
#
# DEFERRED — see teardown_ac10's own header for the full justification
# (concurrent 11-PRD-wide /build tick sharing one unisolated burst-lane
# checkout and one already-live box; this AC continues directly from AC10's
# same real box). Re-run for real in an uncontended window, immediately
# after AC10.
set -uo pipefail
echo "FAIL teardown AC11: DEFERRED, out of this pass's safe scope — continues from AC10's same real box, deferred for the same reason (concurrent 11-PRD-wide /build tick, shared unisolated checkout, an already-live box in use by sibling PRDs, outside this pass's own safe scope). See teardown_ac10_real_box_adopt_deferred.sh's header for the full justification. Re-run for real in an uncontended window." >&2
exit 1
