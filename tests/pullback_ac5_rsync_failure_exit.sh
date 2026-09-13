#!/usr/bin/env bash
# pullback_ac5_rsync_failure_exit.sh — PRD-build-burst-pull-back-restore
# AC5.
#
# Given a transfer whose underlying rsync fails, When `pull` runs, Then
# `pull` exits non-zero and journals the failure cause.
#
# GAP: scripts/burst-lane-selftest.sh's FAKE_RSYNC_FAIL knob is exercised
# twice — "burstdisk AC3" (~line 928) for `run`'s rsync-UP, and "gatebox
# AC5" (~line 1739) for `gate`'s rsync-up — but never against an explicit
# `pull`'s rsync-DOWN. do_marker_pull's own real-failure branch (rsync ran,
# box/dir exist, transfer itself failed -> marker left dirty, rc1,
# journaled) is described in burst-lane.sh's own header comment above
# do_marker_pull but has no fixture proving it. This is a real,
# unimplemented coverage gap, not a tmpfs or environment artifact.
set -uo pipefail
echo "FAIL pullback AC5: GAP — no fixture in scripts/burst-lane-selftest.sh sets FAKE_RSYNC_FAIL for an explicit \`pull\` (rsync-down). The two existing FAKE_RSYNC_FAIL cases (burstdisk AC3 ~line 928, gatebox AC5 ~line 1739) both fail rsync-UP paths (run/gate), never pull's rsync-down. Until such a fixture exists (dirty marker + real session + FAKE_RSYNC_FAIL=1 pull -> assert rc!=0, marker still dirty, journal names the rsync failure cause), AC5 has no case to pair with." >&2
exit 1
