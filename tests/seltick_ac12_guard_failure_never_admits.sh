#!/usr/bin/env bash
# seltick_ac12_guard_failure_never_admits.sh —
# PRD-build-select-tick-deterministic AC12: at least one selftest case
# asserts a failure path — a guard exiting 1 is reported as a skip, never
# as an admission. Here: a rust-extend PRD on lane "carbon"
# (lane-predicate.sh's cargo-free roster) must be rejected by
# select-guard.sh's own lane-predicate call and must never appear in
# admitted[].
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

seltick_write_prd rustonly rust-extend /tmp/seltick-ac12-repo

out=$(seltick_run --lane carbon --format json)

if printf '%s' "$out" | "$SELTICK_JQ" -e '.admitted[] | select(.slug=="rustonly")' >/dev/null; then
  echo "FAIL AC12: rustonly (rust-extend on cargo-free lane carbon) must never be admitted" >&2
  exit 1
fi
reason=$(printf '%s' "$out" | "$SELTICK_JQ" -r '.skipped[] | select(.slug=="rustonly") | .reason')
if [ "$reason" != "cargo-bound" ]; then
  echo "FAIL AC12: expected reason=cargo-bound, got: $reason" >&2
  exit 1
fi
echo "ok  AC12: cargo-bound guard failure surfaces as a skip, never an admission"
