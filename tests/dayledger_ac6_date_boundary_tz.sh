#!/usr/bin/env bash
# dayledger_ac6_date_boundary_tz.sh — PRD-build-day-ledger AC6: given
# --date omitted at 2026-09-17T03:55Z on a host in America/New_York, date
# is the PRIOR local day and tz is America/New_York.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dayledger-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: date derives to the prior local day" \
  "ok  AC6: tz is America/New_York"
