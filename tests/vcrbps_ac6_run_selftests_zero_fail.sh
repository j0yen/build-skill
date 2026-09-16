#!/usr/bin/env bash
# vcrbps_ac6_run_selftests_zero_fail.sh — PRD-build-verified-completed-
# realbox-perserver AC6.
#
# Given tests/vcrbps_ac*.sh fixtures covering the flat-only, per-server-
# only, both-present, and neither-present cases plus one whole-suite-AC
# pairing case, When scripts/run-selftests.sh scripts/vcrbps-selftest.sh
# runs, Then 0 FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
out="$(bash "$REPO/scripts/run-selftests.sh" scripts/vcrbps-selftest.sh 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "$out" | tail -60 >&2
  echo "FAIL: run-selftests.sh scripts/vcrbps-selftest.sh exited $rc" >&2
  exit 1
fi
if ! grep -qE 'vcrbps-selftest: pass=[0-9]+ fail=0' <<<"$out"; then
  echo "$out" | tail -60 >&2
  echo "FAIL: vcrbps-selftest.sh did not report fail=0" >&2
  exit 1
fi
echo "ok  AC6 run-selftests.sh scripts/vcrbps-selftest.sh reports 0 FAIL"
