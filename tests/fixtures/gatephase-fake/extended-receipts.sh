#!/usr/bin/env bash
# Fake extended-receipts.sh for extend-gate-phase-timing-selftest.sh — the
# 17 real extended producers are irrelevant to phase-timing under test;
# this just sleeps/exits as scripted so the "receipts" phase gets a
# deterministic, controllable duration.
set -uo pipefail
sleep_for() { local s="${1:-0}"; [ "$s" = "0" ] || sleep "$s"; }
sleep_for "${FAKE_RECEIPTS_SLEEP:-0}"
exit "${FAKE_RECEIPTS_RC:-0}"
