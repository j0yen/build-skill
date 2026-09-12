#!/usr/bin/env bash
# Fake cargo-budget.sh for extend-gate-phase-timing-selftest.sh. The real
# cargo-budget.sh gates a slot on host memory/load and samples
# /proc/loadavg every 5s while its command runs — real, useful production
# behavior, but pure overhead for a phase-timing test whose fake
# `autobuilder`/`extended-receipts.sh` never actually invoke cargo. `run
# -- <cmd...>` execs <cmd...> directly, so a scripted sleep's own duration
# is the only time this wrapper ever adds. Overridable via extend-gate.sh's
# own documented $CARGO_BUDGET hook.
set -uo pipefail
case "${1:-}" in
  run)
    shift
    [ "${1:-}" = "--" ] && shift
    exec "$@"
    ;;
  *) exit 0 ;;
esac
