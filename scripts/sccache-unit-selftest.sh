#!/usr/bin/env bash
# sccache-unit-selftest.sh — regression coverage for AC1
# (PRD-build-gate-wall-clock requirement 1): the managed sccache-server
# user unit never idle-exits and its log exists and grows on a compile.
#
# Two tiers, same discipline as sccache-assert-selftest.sh's split between
# fixture and live coverage:
#
#   Tier 1 (always runs, never touches a live system): the shipped unit
#   file and sccache-install.sh are checked structurally/via a throwaway
#   install destination — safe on any box, including one with no sccache
#   installed at all.
#
#   Tier 2 (live, best-effort): if sccache-server.service is ALREADY
#   active on this box (this selftest never installs, enables, starts, or
#   restarts it — that stays a human's explicit, deliberate act per
#   sccache-install.sh's own note), verify its live environment carries
#   SCCACHE_IDLE_TIMEOUT=0, its log file exists, and one harmless compile
#   through the `sccache` client wrapper grows that log. This never
#   restarts or stops the unit, so it cannot recreate the incident it
#   guards against; it is skipped (not failed) when the unit isn't
#   installed/active, so this selftest is portable to a fresh checkout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
UNIT_SRC="$SKILL_DIR/systemd/sccache-server.service"
INSTALL_SH="$HERE/sccache-install.sh"
SYSTEMCTL="${SCCACHE_UNIT_SELFTEST_SYSTEMCTL:-systemctl --user}"
UNIT="${SCCACHE_UNIT_SELFTEST_UNIT:-sccache-server.service}"

fail=0
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then ok "$label"; else bad "$label"; fi
}

[ -f "$UNIT_SRC" ] || { echo "selftest: $UNIT_SRC not found" >&2; exit 2; }
[ -x "$INSTALL_SH" ] || { echo "selftest: $INSTALL_SH not executable" >&2; exit 2; }

# --- Tier 1: static unit-file checks ------------------------------------
expect "tier1 unit sets SCCACHE_IDLE_TIMEOUT=0" \
  "grep -q '^Environment=SCCACHE_IDLE_TIMEOUT=0\$' '$UNIT_SRC'"
expect "tier1 unit logs to a persistent SCCACHE_ERROR_LOG" \
  "grep -q '^Environment=SCCACHE_ERROR_LOG=.*server\.log\$' '$UNIT_SRC'"
expect "tier1 unit's log level covers per-compile activity (not just start/stop)" \
  "grep -q '^Environment=SCCACHE_LOG=sccache=debug\$' '$UNIT_SRC'"
expect "tier1 unit restarts on failure" \
  "grep -q '^Restart=on-failure\$' '$UNIT_SRC'"
expect "tier1 unit is user-scope (no sudo — WantedBy=default.target)" \
  "grep -q '^WantedBy=default.target\$' '$UNIT_SRC'"

# --- Tier 1: install script, isolated dest dir (never touches the real
#     ~/.config/systemd/user, never daemon-reloads/enables/starts) -------
T="$(mktemp -d "${TMPDIR:-/tmp}/sccache-unit-selftest.XXXXXX")"
trap '[ -n "${SCCACHE_UNIT_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT
DEST="$T/systemd-user"

out1="$(SCCACHE_INSTALL_SYSTEMD_USER_DIR="$DEST" "$INSTALL_SH" 2>&1)"
expect "tier1 install links the unit into an isolated dest dir" \
  "[ -L '$DEST/sccache-server.service' ]"
expect "tier1 install never enables/starts (prints the explicit follow-up)" \
  "[[ '$out1' == *'NOT enabled or started'* ]]"

out2="$(SCCACHE_INSTALL_SYSTEMD_USER_DIR="$DEST" "$INSTALL_SH" 2>&1)"
expect "tier1 install is idempotent (re-run is unchanged, not a new backup)" \
  "[[ '$out2' == *'unchanged: sccache-server.service'* ]]"

# --- Tier 2: live, best-effort, read-only + one harmless compile --------
if $SYSTEMCTL is-active --quiet "$UNIT" 2>/dev/null; then
  env_line="$($SYSTEMCTL show -p Environment --value "$UNIT" 2>/dev/null)"
  expect "tier2 live unit env carries SCCACHE_IDLE_TIMEOUT=0" \
    "[[ '$env_line' == *'SCCACHE_IDLE_TIMEOUT=0'* ]]"

  logfile="$(grep -oP '(?<=^Environment=SCCACHE_ERROR_LOG=)\S+' "$UNIT_SRC" | sed "s#%h#$HOME#")"
  expect "tier2 live server.log exists" "[ -f '$logfile' ]"

  if [ -f "$logfile" ] && command -v sccache >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    before=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    TC="$T/compile"
    mkdir -p "$TC"
    cat > "$TC/hello.rs" <<'EOF'
fn main() { println!("sccache-unit-selftest tier2 log-growth probe"); }
EOF
    sccache rustc --edition 2021 -o "$TC/hello" "$TC/hello.rs" >/dev/null 2>&1
    after=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    expect "tier2 server.log grows on a compile" "[ '$after' -gt '$before' ]"
  else
    echo "SKIP: tier2 log-growth probe (sccache/rustc not on PATH or log missing)"
  fi
else
  echo "SKIP: tier2 (sccache-server.service not active on this box — install/enable is a deliberate separate step, see sccache-install.sh)"
fi

if [ "$fail" -eq 0 ]; then
  echo "sccache-unit-selftest: all cases passed"
else
  echo "sccache-unit-selftest: FAILURES present" >&2
fi
exit "$fail"
