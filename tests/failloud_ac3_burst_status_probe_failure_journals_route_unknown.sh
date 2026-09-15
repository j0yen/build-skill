#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC3: a failing `burst-lane.sh status
# --json` never silently defaults extend-gate.sh's routing to local — it
# journals `probe failed (name=burst-status ...)` and `route unknown
# (cause=probe-failed)`. Also asserts the real extend-gate.sh source still
# contains this conversion, and covers select-guard.sh's own half of the
# same probe shape (Grounding's select-guard.sh:220-223).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: a failed status probe never silently defaults to local" \
  "ok  AC3: probe failed (name=burst-status) is journaled" \
  "ok  AC3: route unknown (cause=probe-failed) is journaled" \
  "ok  AC3 (structural): extend-gate.sh's real source still wraps the status probe with probe_run" \
  "ok  AC3 (structural): extend-gate.sh's real source still journals route unknown on probe failure" \
  "ok  select-guard.sh: probe_run wraps the burst status probe" \
  "ok  select-guard.sh: a failed probe journals cap-local (cause=probe-failed)"
