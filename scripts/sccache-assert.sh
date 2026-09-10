#!/usr/bin/env bash
# sccache-assert.sh — gate precondition for every step that sets
# RUSTC_WRAPPER=sccache (PRD-build-gate-wall-clock requirement 2). Fixes
# the 2026-09-10 incident: the sccache server restarted mid-request while
# compiles were in flight, and the orphaned client processes waited on it
# forever — nothing in the gate itself noticed for 60+ minutes. This
# script is the "never run a compile against a server that does not
# answer" guard.
#
# Usage:
#   sccache-assert.sh [--unit <name>] [--timeout <secs>]
#
# On success, prints exactly one line to STDOUT:
#   sccache-assert: ok pid=<n|unknown> started_at=<iso|unknown>
# and exits 0. <n>/<iso> are read from the managed systemd-user unit
# (MainPID / ActiveEnterTimestamp) when it is installed — "unknown" when
# it isn't (a box without sccache-server.service installed yet, or a
# test): sccache actually answering is what gates the compile, unit
# bookkeeping is best-effort and never a hard dependency.
#
# On failure, prints `sccache-assert: sccache_unreachable ...` to STDERR
# and exits 1 — the caller must fail the step closed, never run a compile
# against a server it could not prove was up.
#
# Sequence: `sccache --show-stats` within --timeout (default 5s). On
# failure: restart ONCE — `systemctl --user restart <unit>` if the unit
# is known to systemd, else `sccache --start-server` directly (self-heals
# a box where this PRD's unit isn't installed yet) — then re-check within
# --timeout again. Still failing -> exit 1. Never retries more than once;
# a repeat failure is "unreachable", not a retry loop.
#
# Env overrides (test-only hooks; production defaults unchanged):
#   SCCACHE_BIN               (sccache)
#   SCCACHE_ASSERT_SYSTEMCTL  ("systemctl --user") — point at a fake
#                             single-path script in tests (it is invoked
#                             as "$SCCACHE_ASSERT_SYSTEMCTL show -p ... "
#                             / "... restart <unit>"; a single path with
#                             no embedded spaces works exactly like the
#                             two-word production default)
#   SCCACHE_ASSERT_UNIT       (sccache-server.service)
#   SCCACHE_ASSERT_RESTART_LOG (<skill-dir>/state/sccache-assert/restarts.log)
#                             — PRD-build-gate-wall-clock requirement 8: one
#                             flock-appended NDJSON line per SUCCESSFUL
#                             restart (never for a plain "ok", never for a
#                             sccache_unreachable failure — that already has
#                             its own journal line from the caller), so
#                             gate-wedge-rollup.sh can count "sccache
#                             restarts by the assert path" without re-deriving
#                             it from ledger pid deltas.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"

SCCACHE_BIN="${SCCACHE_BIN:-sccache}"
SYSTEMCTL="${SCCACHE_ASSERT_SYSTEMCTL:-systemctl --user}"
UNIT="${SCCACHE_ASSERT_UNIT:-sccache-server.service}"
RESTART_LOG="${SCCACHE_ASSERT_RESTART_LOG:-$SKILL_DIR/state/sccache-assert/restarts.log}"
timeout_s=5

usage() { echo "usage: sccache-assert.sh [--unit <name>] [--timeout <secs>]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --unit)    UNIT="${2:?sccache-assert: --unit needs a value}"; shift 2 ;;
    --timeout) timeout_s="${2:?sccache-assert: --timeout needs a value}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

die() { echo "sccache-assert: $1" >&2; exit "${2:-1}"; }

check_answering() {
  timeout "$timeout_s" "$SCCACHE_BIN" --show-stats >/dev/null 2>&1
}

unit_known() {
  local ls
  ls="$($SYSTEMCTL show -p LoadState --value "$UNIT" 2>/dev/null)"
  [ -n "$ls" ] && [ "$ls" != "not-found" ]
}

# Prints "<pid> <iso>" — "unknown" for either field it cannot determine.
server_identity() {
  local pid started iso
  pid="$($SYSTEMCTL show -p MainPID --value "$UNIT" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "0" ] || pid="unknown"
  started="$($SYSTEMCTL show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null)"
  iso="unknown"
  if [ -n "$started" ] && [ "$started" != "n/a" ]; then
    iso="$(date -u -d "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  fi
  printf '%s %s\n' "$pid" "$iso"
}

restart_once() {
  if unit_known; then
    $SYSTEMCTL restart "$UNIT" >/dev/null 2>&1
  else
    "$SCCACHE_BIN" --start-server >/dev/null 2>&1
  fi
}

# Appends one NDJSON line to $RESTART_LOG under flock — best-effort, never
# fails the assert if the log directory can't be created/written (a
# read-only or missing state dir must not turn a successful restart into a
# failed step).
log_restart() {
  local pid="$1" iso="$2"
  mkdir -p "$(dirname "$RESTART_LOG")" 2>/dev/null || return 0
  (
    flock -x 201 2>/dev/null || exit 0
    printf '{"ts":"%s","unit":"%s","pid":"%s","started_at":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$UNIT" "$pid" "$iso" >> "$RESTART_LOG"
  ) 201>>"$RESTART_LOG.lock" 2>/dev/null || true
}

if check_answering; then
  read -r pid iso <<<"$(server_identity)"
  echo "sccache-assert: ok pid=$pid started_at=$iso"
  exit 0
fi

echo "sccache-assert: sccache did not answer within ${timeout_s}s — restarting once" >&2
restart_once
sleep 1

if check_answering; then
  read -r pid iso <<<"$(server_identity)"
  echo "sccache-assert: ok pid=$pid started_at=$iso (restarted)"
  log_restart "$pid" "$iso"
  exit 0
fi

die "sccache_unreachable — restart attempted, server still not answering within ${timeout_s}s" 1
