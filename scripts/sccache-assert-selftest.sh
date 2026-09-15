#!/usr/bin/env bash
# sccache-assert-selftest.sh — regression coverage for sccache-assert.sh
# (PRD-build-gate-wall-clock requirement 2 / AC2). Never touches the real
# `sccache` binary or a real systemd-user unit — RedBaron's own sccache
# server is live production infrastructure other branch agents may be
# compiling against right now, so this exercises fixture stand-ins only
# (same discipline as cargo-budget-selftest.sh: validating a stall-fix
# must never be able to recreate the stall it fixes). Every case below
# pins SCCACHE_ASSERT_ALIVE_CMD explicitly (rather than letting
# server_alive() fall back to a real `pgrep -x sccache`) so this selftest's
# result never depends on whether a real sccache process happens to be
# running on the box it's executed on.
#
# Cases:
#   1. server already answering -> ok, no restart attempted, pid/started_at
#      read from the fake systemctl.
#   2. server unreachable, alive-cmd false (dead), unit known to systemd ->
#      restart via `systemctl restart <unit>` (exactly once), then
#      answers -> ok "(restarted)".
#   3. server unreachable, alive-cmd false (dead), unit NOT known to
#      systemd -> restart via `sccache --start-server` directly (self-heal
#      path), then answers -> ok "(restarted)", pid/started_at "unknown".
#   4. server unreachable, alive-cmd false (dead), and STAYS unreachable
#      after the one restart attempt -> exit 1, "sccache_unreachable" on
#      stderr, restart attempted exactly once (never a retry loop).
#   5. server unreachable but ALIVE (busy, not dead) -> never restarted;
#      re-checks within --busy-wait, and reports "(busy-unconfirmed)" +
#      exit 0 if it never answers within that budget (2026-09-15 fix: a
#      saturated box's slow --show-stats used to read as "dead" and get
#      restarted, killing every concurrent gate's in-flight compile).
#   6. server unreachable, alive-cmd false (dead), two asserts run
#      concurrently -> the restart.lock serializes them: exactly one
#      restart happens (one row in restarts.log), the other reports
#      "(restarted-by-peer)"; both exit 0.
#   7. same dead-and-stays-dead semantics as case 4, exercised explicitly
#      through the new alive-cmd/lock path with its own fixture, so a
#      future edit to case 2/3/4's shared fixture can't silently stop
#      covering the "restart genuinely doesn't help" outcome.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ASSERT="$HERE/sccache-assert.sh"
[ -x "$ASSERT" ] || { echo "selftest: $ASSERT not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/sccache-assert-selftest.XXXXXX")"
trap '[ -n "${SCCACHE_ASSERT_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

# --- fake sccache: --show-stats succeeds iff $T/answering exists;
#     --start-server touches $T/answering and counts starts. -------------
FAKE_SCCACHE="$T/fake-sccache"
cat > "$FAKE_SCCACHE" <<EOF
#!/usr/bin/env bash
T="$T"
case "\$1" in
  --show-stats) [ -f "\$T/answering" ] && exit 0 || exit 1 ;;
  --start-server)
    echo \$(( \$(cat "\$T/starts" 2>/dev/null || echo 0) + 1 )) > "\$T/starts"
    : > "\$T/answering"
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_SCCACHE"

# --- fake sccache, slow variant: --show-stats always sleeps past any sane
#     --timeout and never answers, regardless of $T/answering — case 5
#     (busy) needs a --show-stats that TIMES OUT rather than one that fails
#     fast, so `timeout` itself is what turns this into "not answering".
FAKE_SCCACHE_SLOW="$T/fake-sccache-slow"
cat > "$FAKE_SCCACHE_SLOW" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --show-stats) sleep 5; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_SCCACHE_SLOW"

# --- fake systemctl: "show -p PROP --value UNIT" and "restart UNIT". ----
# UNIT_KNOWN / restart-flips-answering are controlled via files in $T so
# each case below can reconfigure them independently.
FAKE_SYSTEMCTL="$T/fake-systemctl"
cat > "$FAKE_SYSTEMCTL" <<EOF
#!/usr/bin/env bash
T="$T"
if [ "\$1" = "show" ]; then
  prop="\$3"
  if [ ! -f "\$T/unit-known" ]; then
    [ "\$prop" = "LoadState" ] && { echo "not-found"; exit 0; }
    echo ""; exit 0
  fi
  case "\$prop" in
    LoadState)             echo "loaded" ;;
    MainPID)                echo "424242" ;;
    ActiveEnterTimestamp)   echo "Thu 2026-09-10 04:00:01 UTC" ;;
  esac
  exit 0
elif [ "\$1" = "restart" ]; then
  echo \$(( \$(cat "\$T/restarts" 2>/dev/null || echo 0) + 1 )) > "\$T/restarts"
  [ -f "\$T/unit-known" ] && : > "\$T/answering"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_SYSTEMCTL"

RESTART_LOG="$T/restarts.log"
RESTART_LOCK="$T/restart.lock"

reset_fixture() {
  rm -f "$T/answering" "$T/unit-known" "$T/starts" "$T/restarts" "$RESTART_LOG" "$RESTART_LOG.lock" "$RESTART_LOCK"
}

run_assert() {
  SCCACHE_BIN="$FAKE_SCCACHE" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL" \
    SCCACHE_ASSERT_UNIT="sccache-server.service" \
    SCCACHE_ASSERT_RESTART_LOG="$RESTART_LOG" \
    SCCACHE_ASSERT_RESTART_LOCK="$RESTART_LOCK" \
    SCCACHE_ASSERT_ALIVE_CMD="false" \
    "$ASSERT" --timeout 2 --start-wait 5
}

# --- case 1: already answering ------------------------------------------
reset_fixture
: > "$T/answering"
: > "$T/unit-known"
out="$(run_assert)"; rc=$?
expect "case1 exit 0"                 "[ $rc -eq 0 ]"
expect "case1 ok line"                "[[ \"$out\" == *'sccache-assert: ok pid=424242 started_at=2026-09-10T04:00:01Z'* ]]"
expect "case1 no restart attempted"   "[ ! -f '$T/restarts' ]"
expect "case1 no restart-log line (never restarted)" "[ ! -e '$RESTART_LOG' ]"

# --- case 2: unreachable, dead, unit known -> restart via systemctl -----
reset_fixture
: > "$T/unit-known"
out="$(run_assert)"; rc=$?
expect "case2 exit 0"                 "[ $rc -eq 0 ]"
expect "case2 restarted-once"         "[ \"\$(cat '$T/restarts')\" = 1 ]"
expect "case2 no direct start-server" "[ ! -f '$T/starts' ]"
expect "case2 ok restarted line"      "[[ \"$out\" == *'(restarted)'* ]]"
expect "case2 restart-log gets exactly one line (req 8)" "[ \$(wc -l < '$RESTART_LOG') -eq 1 ]"
expect "case2 restart-log line names pid+unit" \
  "grep -qF 'pid\":\"424242' '$RESTART_LOG' && grep -qF 'sccache-server.service' '$RESTART_LOG'"

# --- case 3: unreachable, dead, unit NOT known -> self-heal via --start-server
reset_fixture
out="$(run_assert)"; rc=$?
expect "case3 exit 0"                 "[ $rc -eq 0 ]"
expect "case3 direct-start-once"      "[ \"\$(cat '$T/starts')\" = 1 ]"
expect "case3 no systemctl restart"   "[ ! -f '$T/restarts' ]"
expect "case3 pid unknown"            "[[ \"$out\" == *'pid=unknown'* ]]"
expect "case3 restart-log still records the self-heal restart" "[ \$(wc -l < '$RESTART_LOG') -eq 1 ]"

# --- case 4: dead, stays unreachable after the one restart attempt ------
reset_fixture
: > "$T/unit-known"
# override the fake systemctl restart to NOT flip answering (server truly wedged)
FAKE_SYSTEMCTL_NOOP="$T/fake-systemctl-noop"
cat > "$FAKE_SYSTEMCTL_NOOP" <<EOF
#!/usr/bin/env bash
T="$T"
if [ "\$1" = "show" ]; then
  prop="\$3"
  case "\$prop" in
    LoadState)              echo "loaded" ;;
    MainPID)                echo "424242" ;;
    ActiveEnterTimestamp)   echo "Thu 2026-09-10 04:00:01 UTC" ;;
  esac
  exit 0
elif [ "\$1" = "restart" ]; then
  echo \$(( \$(cat "\$T/restarts" 2>/dev/null || echo 0) + 1 )) > "\$T/restarts"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_SYSTEMCTL_NOOP"
reset_fixture
: > "$T/unit-known"
err="$(SCCACHE_BIN="$FAKE_SCCACHE" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL_NOOP" \
       SCCACHE_ASSERT_UNIT="sccache-server.service" SCCACHE_ASSERT_RESTART_LOG="$RESTART_LOG" \
       SCCACHE_ASSERT_RESTART_LOCK="$RESTART_LOCK" SCCACHE_ASSERT_ALIVE_CMD="false" \
       "$ASSERT" --timeout 2 --start-wait 2 2>&1 1>/dev/null)"; rc=$?
expect "case4 exit 1"                 "[ $rc -eq 1 ]"
expect "case4 restarted-exactly-once" "[ \"\$(cat '$T/restarts')\" = 1 ]"
expect "case4 sccache_unreachable"    "[[ \"$err\" == *sccache_unreachable* ]]"
expect "case4 no restart-log line (restart attempted but never answered)" "[ ! -e '$RESTART_LOG' ]"

# --- case 5: unreachable but ALIVE (busy, not dead) ----------------------
# --show-stats always times out (the slow fake sleeps past --timeout); a
# small --busy-wait keeps this fast while still exercising the full
# "never answered, still alive" path. No restart of any kind may happen.
reset_fixture
out5="$(SCCACHE_BIN="$FAKE_SCCACHE_SLOW" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL" \
        SCCACHE_ASSERT_UNIT="sccache-server.service" SCCACHE_ASSERT_RESTART_LOG="$RESTART_LOG" \
        SCCACHE_ASSERT_RESTART_LOCK="$RESTART_LOCK" SCCACHE_ASSERT_ALIVE_CMD="true" \
        "$ASSERT" --timeout 1 --busy-wait 3)"; rc5=$?
expect "case5 exit 0 (busy is not a failure)" "[ $rc5 -eq 0 ]"
expect "case5 output names it busy"           "[[ \"$out5\" == *busy* ]]"
expect "case5 no restart attempted at all"    "[ ! -f '$T/restarts' ] && [ ! -f '$T/starts' ]"
expect "case5 no restart-log line"            "[ ! -e '$RESTART_LOG' ]"

# --- case 6: dead + two concurrent asserters -> exactly one restart -----
reset_fixture
: > "$T/unit-known"
run_dead_locked() {  # $1 = output file, $2 = rc file
  SCCACHE_BIN="$FAKE_SCCACHE" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL" \
    SCCACHE_ASSERT_UNIT="sccache-server.service" SCCACHE_ASSERT_RESTART_LOG="$RESTART_LOG" \
    SCCACHE_ASSERT_RESTART_LOCK="$RESTART_LOCK" SCCACHE_ASSERT_ALIVE_CMD="false" \
    "$ASSERT" --timeout 2 --start-wait 5 > "$1" 2>&1
  echo $? > "$2"
}
( run_dead_locked "$T/case6-out-a" "$T/case6-rc-a" ) &
pid_a=$!
( run_dead_locked "$T/case6-out-b" "$T/case6-rc-b" ) &
pid_b=$!
wait "$pid_a" "$pid_b"
rc6a="$(cat "$T/case6-rc-a")"; rc6b="$(cat "$T/case6-rc-b")"
expect "case6 both asserts exit 0"      "[ \"$rc6a\" = 0 ] && [ \"$rc6b\" = 0 ]"
expect "case6 exactly one restart happened" "[ \"\$(cat '$T/restarts')\" = 1 ]"
expect "case6 exactly one restart-log row (never two)" "[ \$(wc -l < '$RESTART_LOG') -eq 1 ]"
case6_combined="$(cat "$T/case6-out-a" "$T/case6-out-b")"
expect "case6 one side restarted, the other saw restarted-by-peer" \
  "[[ \"$case6_combined\" == *'(restarted)'* ]] && [[ \"$case6_combined\" == *'(restarted-by-peer)'* ]]"

# --- case 7: dead, restart genuinely does not help -----------------------
# Same semantics as case 4 (restart attempted once, still dead -> exit 1),
# proven again through its own fixture so this outcome isn't only covered
# incidentally by case 4's shared fixture.
reset_fixture
: > "$T/unit-known"
err7="$(SCCACHE_BIN="$FAKE_SCCACHE" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL_NOOP" \
        SCCACHE_ASSERT_UNIT="sccache-server.service" SCCACHE_ASSERT_RESTART_LOG="$RESTART_LOG" \
        SCCACHE_ASSERT_RESTART_LOCK="$RESTART_LOCK" SCCACHE_ASSERT_ALIVE_CMD="false" \
        "$ASSERT" --timeout 2 --start-wait 2 2>&1 1>/dev/null)"; rc7=$?
expect "case7 exit 1"                 "[ $rc7 -eq 1 ]"
expect "case7 restarted-exactly-once" "[ \"\$(cat '$T/restarts')\" = 1 ]"
expect "case7 sccache_unreachable"    "[[ \"$err7\" == *sccache_unreachable* ]]"
expect "case7 no restart-log line"    "[ ! -e '$RESTART_LOG' ]"

if [ "$fail" -eq 0 ]; then
  echo "sccache-assert-selftest: all cases passed"
else
  echo "sccache-assert-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
