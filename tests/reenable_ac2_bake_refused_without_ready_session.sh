#!/usr/bin/env bash
# reenable_ac2_bake_refused_without_ready_session.sh — PRD-build-burst-dispatch-reenable AC2.
#
# Given a session with gate_ready=false or no session, When `bake` runs,
# Then it exits 3, writes nothing, and journals `bake refused (cause=...)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC2a: bake exits 3 with no active session" \
  "ok  reenable AC2a: no snapshot.json was written" \
  "ok  reenable AC2a: journal names the refusal cause" \
  "ok  reenable AC2b setup: session is gate_ready=false after up" \
  "ok  reenable AC2b: bake exits 3 when gate_ready=false" \
  "ok  reenable AC2b: no snapshot.json was written" \
  "ok  reenable AC2b: journal names the refusal cause"
