#!/usr/bin/env bash
# sccache-assert-selftest.sh — regression coverage for sccache-assert.sh
# (PRD-build-gate-wall-clock requirement 2 / AC2). Never touches the real
# `sccache` binary or a real systemd-user unit — RedBaron's own sccache
# server is live production infrastructure other branch agents may be
# compiling against right now, so this exercises fixture stand-ins only
# (same discipline as cargo-budget-selftest.sh: validating a stall-fix
# must never be able to recreate the stall it fixes).
#
# Cases:
#   1. server already answering -> ok, no restart attempted, pid/started_at
#      read from the fake systemctl.
#   2. server unreachable, unit known to systemd -> restart via
#      `systemctl restart <unit>` (exactly once), then answers -> ok
#      "(restarted)".
#   3. server unreachable, unit NOT known to systemd -> restart via
#      `sccache --start-server` directly (self-heal path), then
#      answers -> ok "(restarted)", pid/started_at "unknown".
#   4. server unreachable and STAYS unreachable after the one restart
#      attempt -> exit 1, "sccache_unreachable" on stderr, restart
#      attempted exactly once (never a retry loop).
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

reset_fixture() {
  rm -f "$T/answering" "$T/unit-known" "$T/starts" "$T/restarts"
}

run_assert() {
  SCCACHE_BIN="$FAKE_SCCACHE" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL" \
    SCCACHE_ASSERT_UNIT="sccache-server.service" \
    "$ASSERT" --timeout 2
}

# --- case 1: already answering ------------------------------------------
reset_fixture
: > "$T/answering"
: > "$T/unit-known"
out="$(run_assert)"; rc=$?
expect "case1 exit 0"                 "[ $rc -eq 0 ]"
expect "case1 ok line"                "[[ \"$out\" == *'sccache-assert: ok pid=424242 started_at=2026-09-10T04:00:01Z'* ]]"
expect "case1 no restart attempted"   "[ ! -f '$T/restarts' ]"

# --- case 2: unreachable, unit known -> restart via systemctl -----------
reset_fixture
: > "$T/unit-known"
out="$(run_assert)"; rc=$?
expect "case2 exit 0"                 "[ $rc -eq 0 ]"
expect "case2 restarted-once"         "[ \"\$(cat '$T/restarts')\" = 1 ]"
expect "case2 no direct start-server" "[ ! -f '$T/starts' ]"
expect "case2 ok restarted line"      "[[ \"$out\" == *'(restarted)'* ]]"

# --- case 3: unreachable, unit NOT known -> self-heal via --start-server -
reset_fixture
out="$(run_assert)"; rc=$?
expect "case3 exit 0"                 "[ $rc -eq 0 ]"
expect "case3 direct-start-once"      "[ \"\$(cat '$T/starts')\" = 1 ]"
expect "case3 no systemctl restart"   "[ ! -f '$T/restarts' ]"
expect "case3 pid unknown"            "[[ \"$out\" == *'pid=unknown'* ]]"

# --- case 4: stays unreachable after the one restart attempt ------------
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
err="$(SCCACHE_BIN="$FAKE_SCCACHE" SCCACHE_ASSERT_SYSTEMCTL="$FAKE_SYSTEMCTL_NOOP" \
       SCCACHE_ASSERT_UNIT="sccache-server.service" "$ASSERT" --timeout 2 2>&1 1>/dev/null)"; rc=$?
expect "case4 exit 1"                 "[ $rc -eq 1 ]"
expect "case4 restarted-exactly-once" "[ \"\$(cat '$T/restarts')\" = 1 ]"
expect "case4 sccache_unreachable"    "[[ \"$err\" == *sccache_unreachable* ]]"

if [ "$fail" -eq 0 ]; then
  echo "sccache-assert-selftest: all cases passed"
else
  echo "sccache-assert-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
