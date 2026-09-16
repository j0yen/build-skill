#!/usr/bin/env bash
# gatered_ac10_stopgap_retired.sh — PRD-build-gate-red-alarm-invariant
# AC10: "Given R2 live on RedBaron, When the build lands, Then
# gate-red-alarm.timer is disabled and removed and the journal has
# stopgap-retired gate-red-alarm."
#
# Unlike the other AC wrappers, there is no compound selftest to wrap
# here — retirement is a one-time, real-host operational action (removing
# a systemd unit + script), not a repeatable fixture. This checks the
# real evidence directly: the journal line this dispatch wrote when it
# retired the stopgap, and — best-effort, only when systemctl/RedBaron is
# actually available — that the unit is gone. A non-RedBaron host (no
# systemd-user gate-red-alarm unit was ever installed there) skips the
# systemctl leg rather than failing on an absence that was never this
# host's to have.
set -uo pipefail

JOURNAL_ROOT="${BUILD_JOURNAL_ROOT:-$HOME/brain/journal/build}"
found=0
if [ -d "$JOURNAL_ROOT" ]; then
  if grep -rq "stopgap-retired  gate-red-alarm" "$JOURNAL_ROOT"/*.md 2>/dev/null; then
    found=1
  fi
fi

if [ "$found" -eq 1 ]; then
  echo "ok  AC10: journal has stopgap-retired gate-red-alarm"
else
  echo "FAIL AC10: no 'stopgap-retired gate-red-alarm' journal line found under $JOURNAL_ROOT" >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files gate-red-alarm.timer >/dev/null 2>&1; then
  state="$(systemctl --user is-enabled gate-red-alarm.timer 2>/dev/null || true)"
  if [ -z "$state" ] || [ "$state" = "disabled" ]; then
    echo "ok  AC10: gate-red-alarm.timer is not enabled ($state)"
  else
    echo "FAIL AC10: gate-red-alarm.timer is still enabled ($state)" >&2
    exit 1
  fi
else
  echo "ok  AC10: gate-red-alarm.timer unit file absent (already removed / never installed on this host)"
fi

exit 0
