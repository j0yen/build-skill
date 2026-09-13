#!/usr/bin/env bash
# pullback_ac12_payload_aware_need_gb.sh — PRD-build-burst-pull-back-restore
# AC12.
#
# Given a fixture remote payload of 3 GB and a floor of 60, When `pull`
# runs with the size probe succeeding, Then `need_gb` is 6 and the journal
# names the payload rule; and Given the probe times out, Then `need_gb` is
# 60 and the journal names the floor rule.
#
# GAP: not implemented. do_marker_pull's disk-floor guard (burst-lane.sh
# ~line 3386-3399) only ever computes pull_need_gb as
# max(BURST_LOCAL_DISK_FLOOR_GB, this worktree's own last-observed pull
# size) — there is no remote payload size probe (no `du -s` over ssh in
# this path; the existing `du -sb` calls at burst-lane.sh lines 2400/5212/
# 5297/5312/5395 are all for other features — reality-check, root-move
# migration, workspace path-dep sync — none feed do_marker_pull's need_gb),
# no 2x-payload/2GB-floor/never-above-configured-floor rule, and no journal
# field naming which rule (payload vs floor) produced need_gb. This is a
# real, unimplemented requirement (Joe's 2026-09-13 decision in the PRD's
# Open questions), not a tmpfs or environment artifact.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
if grep -qE 'need_gb.*(rule|payload)|payload.*probe' "$BL" 2>/dev/null; then
  echo "FAIL pullback AC12: burst-lane.sh now mentions a payload/rule concept near need_gb — re-check by hand; this wrapper's grep-based gap detection may be stale and needs updating to assert the real behavior instead of a gap." >&2
  exit 1
fi
echo "FAIL pullback AC12: GAP — do_marker_pull has no remote-payload size probe or payload-aware need_gb rule (checked scripts/burst-lane.sh for a 'need_gb'+'rule'/'payload' pairing near the guard; none found), and scripts/burst-lane-selftest.sh has no fixture setting a 3 GB fake payload and asserting need_gb=6 vs a timed-out probe asserting need_gb=60 with a rule-naming journal field. Until both the implementation and a fixture exist, AC12 has no case to pair with." >&2
exit 1
