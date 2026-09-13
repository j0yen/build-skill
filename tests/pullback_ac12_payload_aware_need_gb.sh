#!/usr/bin/env bash
# pullback_ac12_payload_aware_need_gb.sh — PRD-build-burst-pull-back-restore
# AC12.
#
# Given a fixture remote payload of 3 GB and a floor of 60, When `pull`
# runs with the size probe succeeding, Then `need_gb` is 6 and the journal
# names the payload rule; and Given the probe times out, Then `need_gb` is
# 60 and the journal names the floor rule.
#
# Implemented: burst-lane.sh's do_marker_pull now probes the remote
# payload (one bounded `du -sb` over ssh, `remote_payload_probe_bytes()`)
# before falling back to the floor/last-observed-size rule.
# scripts/burst-lane-selftest.sh's "pullback AC12" fixture exercises both
# branches against the same 60 GB floor: a fake 3 GB payload (need_gb=6,
# rule=payload) and a probe that times out (need_gb=60, rule=floor,
# unchanged from the pre-AC12 formula). The pre-existing "burstvol AC9"
# fixture (a different feature, PRD-build-burst-persistent-volume) now
# forces the probe unavailable (FAKE_SSH_PULL_PROBE_FAIL=1) so it keeps
# testing exactly the static rule it always tested.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

fail=0

for line in \
  "ok  pullback AC12: probe-succeeding pull exits 0 (deferred, not an error)" \
  "ok  pullback AC12: a 3 GB payload probe sets need_gb=6, naming the payload rule" \
  "ok  pullback AC12: probe-timeout pull exits 0 (deferred, not an error)" \
  "ok  pullback AC12: a timed-out probe leaves need_gb=60, naming the floor rule" \
  "ok  burstvol AC9: journal records pull deferred cause=local-disk free_gb=20 need_gb=87" \
  "ok  burstvol AC9: the marker stays dirty (never cleared)" \
; do
  if grep -qF "$line" <<<"$PULLBACK_OUT"; then
    echo "$line"
  else
    echo "FAIL pullback AC12: missing/failed: $line" >&2
    fail=1
  fi
done

exit $fail
