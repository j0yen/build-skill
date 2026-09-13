#!/usr/bin/env bash
# pullback_ac13_real_box_proof.sh — PRD-build-burst-pull-back-restore AC13
# (P1).
#
# Given an operator-authorized real burst box that has produced build
# artifacts, When `pull` runs, Then the artifacts arrive locally and the
# journaled byte count matches what was transferred; deferrable with
# justification only if no real box is authorized at build time.
#
# DEFERRED, per the PRD's own text: this is a P1 requirement the PRD
# itself says may be deferred "with justification only if no real box is
# authorized at build time." No real box is authorized right now — the
# real Hetzner burst box was deleted 2026-09-11 (RedBaron-local policy),
# and every case in scripts/burst-lane-selftest.sh runs the fake
# hcloud/ssh/rsync fixtures under BUILD_BURST_ENABLED=1 rather than a real
# box (see the suite's own burst_configured() gate). This wrapper reports
# that deferral explicitly (a real non-zero exit, never a tautological
# exit 0) rather than fabricating a pass — resolve it once a real box is
# authorized, by running an actual `pull` against it and comparing bytes.
set -uo pipefail
echo "FAIL pullback AC13: DEFERRED — no operator-authorized real burst box exists to prove this against (the real Hetzner box was deleted 2026-09-11; RedBaron-local policy). Per the PRD's own acceptance criterion, this P1 is deferrable with justification only, which this is. Re-run this wrapper for real once a box is authorized." >&2
exit 1
