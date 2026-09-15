#!/usr/bin/env bash
# teardown_ac2_probe_unavailable_never_a_cause.sh — PRD-build-burst-
# teardown-evidence AC2.
#
# Given hcloud absent from PATH and a live session.json, when status, down,
# watchdog, and idle-guard each run, then session.json is unchanged, no
# .stale-* file is created, and each journals decision=keep cause=probe-
# unavailable at most once per hour.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  teardown AC2: down is a no-op decision=keep cause=probe-unavailable without hcloud" \
  "ok  teardown AC2: watchdog is a no-op decision=keep cause=probe-unavailable without hcloud" \
  "ok  teardown AC2: idle-guard is a no-op decision=keep cause=probe-unavailable without hcloud" \
  "ok  teardown AC2: session.json is byte-unchanged after all three" \
  "ok  teardown AC2: no .stale- file was created" \
  "ok  teardown AC2: probe-unavailable journaled at most once across down+watchdog+idle-guard (once-per-hour throttle)"
