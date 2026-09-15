#!/usr/bin/env bash
# sccache-assert.sh — gate precondition for every step that sets
# RUSTC_WRAPPER=sccache (PRD-build-gate-wall-clock requirement 2). Fixes
# the 2026-09-10 incident: the sccache server restarted mid-request while
# compiles were in flight, and the orphaned client processes waited on it
# forever — nothing in the gate itself noticed for 60+ minutes. This
# script is the "never run a compile against a server that does not
# answer" guard.
#
# 2026-09-15 ("busy is not dead"): under a saturated box (8 concurrent
# cargo gates, the server unit running at Nice=10/CPUWeight=50 so it
# starved first) `--show-stats` timing out at 5s meant BUSY, not dead —
# but the old flow restarted the server on ANY timeout, killing every
# in-flight compile of every concurrent gate. Two asserters did exactly
# that at 12:33:08Z/12:33:09Z the same day: each restarted the unit, the
# second killing the first's fresh server. This version never restarts a
# server whose process is still alive; it only restarts one that is
# actually gone, and does that restart under a lock so two concurrent
# asserters can't double-restart / restart each other's fresh server.
#
# Usage:
#   sccache-assert.sh [--unit <name>] [--timeout <secs>] [--busy-wait <secs>] [--start-wait <secs>]
#
# On success, prints exactly one line to STDOUT:
#   sccache-assert: ok pid=<n|unknown> started_at=<iso|unknown>[ (suffix)]
# and exits 0. <n>/<iso> are read from the managed systemd-user unit
# (MainPID / ActiveEnterTimestamp) when it is installed — "unknown" when
# it isn't (a box without sccache-server.service installed yet, or a
# test): sccache actually answering is what gates the compile, unit
# bookkeeping is best-effort and never a hard dependency. The optional
# suffix names which path produced the ok:
#   (busy Ns)            — didn't answer at first, but answered after Ns of
#                          busy-waiting on a server that was already alive.
#   (busy-unconfirmed)   — still alive after the full --busy-wait budget but
#                          never answered; NEVER restarted (see above).
#   (restarted-by-peer)  — was dead; another concurrent assert had already
#                          restarted it by the time this one got the lock.
#   (restarted)          — was dead; this process restarted it.
#
# On failure, prints `sccache-assert: sccache_unreachable ...` to STDERR
# and exits 1 — the caller must fail the step closed, never run a compile
# against a server it could not prove was up.
#
# Sequence: `sccache --show-stats` within --timeout (default 20s). If that
# doesn't answer, check whether the server PROCESS is alive:
#   ALIVE (just slow to answer) -> re-check every 5s up to --busy-wait
#     (default 60s); never restarted — see header for why.
#   DEAD (no process at all) -> take an exclusive lock (state dir below),
#     re-check once more inside it (a sibling assert may have just fixed
#     it), restart ONCE if still dead, then poll every 1s up to
#     --start-wait (default 30s — a cold start walks the whole cache
#     directory). Still not answering -> exit 1. Never retries more than
#     one restart attempt; a repeat failure is "unreachable", not a retry
#     loop.
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
#   SCCACHE_ASSERT_ALIVE_CMD  (unset) — a command string `server_alive`
#                             evaluates instead of its own MainPID/pgrep
#                             check when set (exit 0 = alive); same style
#                             as SCCACHE_ASSERT_SYSTEMCTL, for tests that
#                             need to fake "server is/isn't alive" without
#                             a real sccache process on the test box.
#   SCCACHE_ASSERT_RESTART_LOG (<skill-dir>/state/sccache-assert/restarts.log)
#                             — PRD-build-gate-wall-clock requirement 8: one
#                             flock-appended NDJSON line per SUCCESSFUL
#                             restart (never for a plain "ok", never for a
#                             sccache_unreachable failure — that already has
#                             its own journal line from the caller), so
#                             gate-wedge-rollup.sh can count "sccache
#                             restarts by the assert path" without re-deriving
#                             it from ledger pid deltas.
#   SCCACHE_ASSERT_RESTART_LOCK (<skill-dir>/state/sccache-assert/restart.lock)
#                             — flock path serializing the DEAD-path restart
#                             between concurrent asserters (2026-09-15 fix
#                             for the double-restart incident above).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"

SCCACHE_BIN="${SCCACHE_BIN:-sccache}"
SYSTEMCTL="${SCCACHE_ASSERT_SYSTEMCTL:-systemctl --user}"
UNIT="${SCCACHE_ASSERT_UNIT:-sccache-server.service}"
RESTART_LOG="${SCCACHE_ASSERT_RESTART_LOG:-$SKILL_DIR/state/sccache-assert/restarts.log}"
RESTART_LOCK="${SCCACHE_ASSERT_RESTART_LOCK:-$SKILL_DIR/state/sccache-assert/restart.lock}"
timeout_s=20
busy_wait_s=60
start_wait_s=30

usage() { echo "usage: sccache-assert.sh [--unit <name>] [--timeout <secs>] [--busy-wait <secs>] [--start-wait <secs>]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --unit)       UNIT="${2:?sccache-assert: --unit needs a value}"; shift 2 ;;
    --timeout)    timeout_s="${2:?sccache-assert: --timeout needs a value}"; shift 2 ;;
    --busy-wait)  busy_wait_s="${2:?sccache-assert: --busy-wait needs a value}"; shift 2 ;;
    --start-wait) start_wait_s="${2:?sccache-assert: --start-wait needs a value}"; shift 2 ;;
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

# True when the server PROCESS is alive, regardless of whether it has
# answered a --show-stats call yet — the busy-vs-dead distinction this
# whole rewrite exists to make (see header). Prefers the managed unit's own
# MainPID (a live pid there is authoritative); falls back to `pgrep -x
# sccache` only when the unit itself isn't known to systemd (a box without
# the unit installed). Overridable via SCCACHE_ASSERT_ALIVE_CMD for tests
# that can't rely on a real sccache process/unit on the test box.
server_alive() {
  if [ -n "${SCCACHE_ASSERT_ALIVE_CMD:-}" ]; then
    eval "$SCCACHE_ASSERT_ALIVE_CMD"
    return $?
  fi
  if unit_known; then
    local pid
    pid="$($SYSTEMCTL show -p MainPID --value "$UNIT" 2>/dev/null)"
    [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null
  else
    pgrep -x sccache >/dev/null 2>&1
  fi
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

if server_alive; then
  # BUSY, not dead: on a saturated box --show-stats can time out just
  # because the server hasn't gotten a scheduler slice yet, not because
  # it's gone (2026-09-15 incident — see header). Restarting here would
  # kill every concurrent gate's in-flight compile, so this path NEVER
  # restarts; it only waits, re-checking every 5s (capped to the
  # remaining budget so a small --busy-wait in tests doesn't overshoot).
  elapsed=0
  while [ "$elapsed" -lt "$busy_wait_s" ]; do
    step=5
    remaining=$((busy_wait_s - elapsed))
    [ "$remaining" -lt "$step" ] && step="$remaining"
    sleep "$step"
    elapsed=$((elapsed + step))
    if check_answering; then
      read -r pid iso <<<"$(server_identity)"
      echo "sccache-assert: ok pid=$pid started_at=$iso (busy ${elapsed}s)"
      exit 0
    fi
  done
  read -r pid iso <<<"$(server_identity)"
  echo "sccache-assert: ok pid=$pid started_at=$iso (busy-unconfirmed)"
  echo "sccache-assert: warning — sccache process is alive but did not answer --show-stats within ${busy_wait_s}s of busy-waiting; proceeding WITHOUT restarting it (a live server is never restarted here — see header)" >&2
  exit 0
fi

# DEAD: no process at all. Lock so two concurrent asserters can't restart
# each other's fresh server (the double-restart failure mode above) —
# mkdir -p first since $RESTART_LOCK's directory may not exist on a fresh
# box.
mkdir -p "$(dirname "$RESTART_LOCK")" 2>/dev/null || true
exec 201>>"$RESTART_LOCK"
flock -x 201

# A sibling assert may have already restarted it while we waited on the
# lock — check again before restarting a second time.
if check_answering; then
  read -r pid iso <<<"$(server_identity)"
  echo "sccache-assert: ok pid=$pid started_at=$iso (restarted-by-peer)"
  exit 0
fi

echo "sccache-assert: sccache did not answer within ${timeout_s}s and no process is alive — restarting once" >&2
restart_once

start_elapsed=0
while [ "$start_elapsed" -lt "$start_wait_s" ] && ! check_answering; do
  sleep 1
  start_elapsed=$((start_elapsed + 1))
done

if check_answering; then
  read -r pid iso <<<"$(server_identity)"
  echo "sccache-assert: ok pid=$pid started_at=$iso (restarted)"
  log_restart "$pid" "$iso"
  exit 0
fi

die "sccache_unreachable — restart attempted, server still not answering within ${timeout_s}s" 1
