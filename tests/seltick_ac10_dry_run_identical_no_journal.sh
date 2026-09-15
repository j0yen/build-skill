#!/usr/bin/env bash
# seltick_ac10_dry_run_identical_no_journal.sh —
# PRD-build-select-tick-deterministic AC10: given --dry-run, when it runs,
# then the JSON equals the non-dry-run's JSON and no journal line is
# written.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

seltick_write_prd dryrun shell /tmp/seltick-ac10-repo

real_out=$(seltick_run --format json)
n_after_real=$(grep -c '  select-tick  ' "$JOURNAL")
if [ "$n_after_real" -ne 1 ]; then
  echo "FAIL AC10: expected the real run to journal 1 line, got $n_after_real" >&2
  exit 1
fi

dry_out=$(seltick_run --format json --dry-run)
n_after_dry=$(grep -c '  select-tick  ' "$JOURNAL")
if [ "$n_after_dry" -ne 1 ]; then
  echo "FAIL AC10: --dry-run must not add a journal line, count now $n_after_dry" >&2
  exit 1
fi
if [ "$real_out" != "$dry_out" ]; then
  echo "FAIL AC10: --dry-run JSON differs from a real run's JSON" >&2
  echo "--- real ---" >&2; echo "$real_out" >&2
  echo "--- dry ---" >&2; echo "$dry_out" >&2
  exit 1
fi
echo "ok  AC10: --dry-run JSON identical to a real run's, no extra journal line"
