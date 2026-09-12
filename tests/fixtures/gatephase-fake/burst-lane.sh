#!/usr/bin/env bash
# Fake burst-lane.sh for extend-gate-phase-timing-selftest.sh. Phase
# timing under test cares about extend-gate.sh's OWN producer timers, not
# burst-lane's real session/routing machinery (network calls, ssh,
# hcloud) — this stub answers every subcommand extend-gate.sh calls
# (`status --json`, `route-check`, `ensure-fresh`) instantly and
# harmlessly so a run's wall-clock time is exactly the sum of its own
# scripted sleeps, never padded by unrelated real-world I/O. Overridable
# via extend-gate.sh's own documented $BURST_LANE_SH hook ("so tests/ can
# point at a fixture without touching production behavior").
set -uo pipefail
case "${1:-}" in
  status) echo '{"active":false}' ;;
  *) : ;;
esac
exit 0
