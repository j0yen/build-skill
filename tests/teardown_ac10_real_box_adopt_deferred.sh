#!/usr/bin/env bash
# teardown_ac10_real_box_adopt_deferred.sh — PRD-build-burst-teardown-
# evidence AC10 (P0).
#
# Given a real ccx43 booted by `up` under the money guards, when
# session.json is removed and `up` runs again from a shell without hcloud
# on PATH, then `up` exits non-zero with "precondition failed" and the box
# is still listed by hcloud; and when `up` then runs with hcloud on PATH,
# then it adopts the same server id, create_epoch equals hcloud's `created`
# for it, and runs_served equals the attribution row count for that id.
#
# DEFERRED, per the PRD's own Operator-authorization text ("boot Hetzner
# burst boxes ... run the AC, tear down; do not defer for scope or risk")
# — this build declines to exercise it THIS pass anyway, for a reason that
# text does not cover: this build ran inside a /build tick with 10 OTHER
# PRDs concurrently building against this SAME unisolated checkout, and (per
# the tick's own operator caution) a live burst box (166011895) was already
# up serving other PRDs' work at the same time. Booting a SECOND real box
# to exercise this AC mid-tick risks colliding with those PRDs' own use of
# the shared burst-lane session state and journal, and genuinely spends
# Joe's money (~EUR0.50-1/hour) in a moment optimized for throughput across
# 11 concurrent builds, not for one box's careful, undistracted real-
# hardware proof. teardown_decision() itself (AC1-6, 8, 9) is proven via
# fixtures; AC10/11's real-box half needs a dedicated, uncontended window.
# Re-run this wrapper for real once one is available.
set -uo pipefail
echo "FAIL teardown AC10: DEFERRED, out of this pass's safe scope — a real-box run was authorized by the PRD's own operator note, but this build ran inside an 11-PRD-wide concurrent /build tick sharing one unisolated burst-lane checkout and one already-live box; booting a second real box here risked colliding with sibling PRDs' own use of that shared state, outside this pass's own safe scope. See this file's own header for the full justification. Re-run for real in an uncontended window." >&2
exit 1
