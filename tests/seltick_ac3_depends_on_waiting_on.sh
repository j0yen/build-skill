#!/usr/bin/env bash
# seltick_ac3_depends_on_waiting_on.sh —
# PRD-build-select-tick-deterministic AC3: given a queued PRD whose
# Depends-on names a PRD still in build-queue/, when select-tick.sh runs,
# then that slug is in skipped[] with reason "waiting-on" and detail
# naming the dependency.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

seltick_write_prd waited shell /tmp/seltick-ac3-waited-repo
seltick_write_prd waiter shell /tmp/seltick-ac3-waiter-repo PRD-waited.md

out=$(seltick_run --format json)

reason=$(printf '%s' "$out" | "$SELTICK_JQ" -r '.skipped[] | select(.slug == "waiter") | .reason')
detail=$(printf '%s' "$out" | "$SELTICK_JQ" -r '.skipped[] | select(.slug == "waiter") | .detail')
if [ "$reason" != "waiting-on" ]; then
  echo "FAIL AC3: expected waiter skipped reason=waiting-on, got reason=$reason: $out" >&2
  exit 1
fi
if [ "$detail" != "waited" ]; then
  echo "FAIL AC3: expected detail to name 'waited', got: $detail" >&2
  exit 1
fi
printf '%s' "$out" | "$SELTICK_JQ" -e '.admitted[] | select(.slug == "waited")' >/dev/null \
  || { echo "FAIL AC3: expected 'waited' itself admitted (nothing blocks it)" >&2; exit 1; }
echo "ok  AC3: waiter skipped waiting-on, detail names waited"
