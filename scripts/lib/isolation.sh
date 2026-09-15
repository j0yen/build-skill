#!/usr/bin/env bash
# scripts/lib/isolation.sh — structural test isolation, on by default under
# a test run (PRD-build-test-isolation-by-default requirement 4).
#
# Source this and call isolation_apply as the FIRST thing run-selftests.sh
# (or any other test entrypoint) does, before sourcing or exec'ing anything
# under test. When BUILD_TEST=1, isolation_apply redirects every path a
# build-skill script defaults to production for:
#   - HOME               -> $BUILD_TEST_ROOT/home
#       Covers scripts/lib/journal.sh's production default, PRD_DIR
#       ($HOME/Documents/PRDs), and every other $HOME/... default in the
#       tree — most scripts need no other change (requirement 6).
#   - BUILD_JOURNAL_ROOT  -> $BUILD_TEST_ROOT/journal
#       Belt-and-suspenders for scripts/lib/journal.sh even if some future
#       caller stops keying off $HOME.
#   - BUILD_STATE_DIR, STATE_DIR -> $BUILD_TEST_ROOT/state
#       The generic state-dir override most scripts already read.
#   - BURST_LANE_STATE_DIR, GATE_WEDGE_STATE_DIR, GATE_BURST_STATE_DIR
#       The three writers whose STATE_DIR defaults off the repo path
#       ($SKILL_DIR/state/<name>), not $HOME — overriding HOME alone does
#       not isolate these.
#   - PRD_DIR and friends -> $BUILD_TEST_ROOT/home/Documents/PRDs
#       Pinned explicitly (as well as inheriting the HOME override) so a
#       script reading PRD_DIR directly isolates too.
#
# It also arms scripts/isolation-guard.sh UNCONDITIONALLY — no
# BURST_LANE_TEST gate to remember (requirement 4's "not opt-in"; see
# isolation-guard.sh's isolation_sentinel_on). To keep the guard able to
# recognize the REAL production roots while $HOME has been overridden for
# everything else, isolation_apply exports BUILD_TEST_REAL_HOME (the
# pre-override $HOME) — isolation-guard.sh consults it when present.
#
# A test that needs real config (the allowlist below; Technical
# considerations) gets it copied — never symlinked — into the new $HOME so
# a test can't write back into the real file even if it tries.
#
# No-op, zero cost, when BUILD_TEST is unset (production callers never pay
# for this).

BUILD_TEST_ISOLATION_CONFIG_ALLOWLIST="${BUILD_TEST_ISOLATION_CONFIG_ALLOWLIST:-.config/wm-burst/.env}"

isolation_active() { [ "${BUILD_TEST:-0}" = "1" ]; }

isolation_apply() {
  isolation_active || return 0
  if [ -z "${BUILD_TEST_ROOT:-}" ]; then
    echo "isolation.sh: BUILD_TEST=1 requires BUILD_TEST_ROOT" >&2
    return 1
  fi

  local real_home="$HOME"
  export BUILD_TEST_REAL_HOME="$real_home"

  # rustup/cargo pin to the REAL toolchain explicitly. Both default to
  # $HOME/.rustup and $HOME/.cargo when their own env vars are unset — once
  # HOME is overridden below, an unpinned rustup can't find the real
  # default toolchain at all ("no default is configured", verified: a
  # selftest that shells out to the real `cargo` for a cheap `--version`/
  # `check` broke exactly this way before this fix). Pinning here, not
  # copying, since these can be large.
  export RUSTUP_HOME="${RUSTUP_HOME:-$real_home/.rustup}"
  export CARGO_HOME="${CARGO_HOME:-$real_home/.cargo}"

  mkdir -p "$BUILD_TEST_ROOT/home" "$BUILD_TEST_ROOT/journal" "$BUILD_TEST_ROOT/state" \
           "$BUILD_TEST_ROOT/home/Documents/PRDs/build-queue" \
           "$BUILD_TEST_ROOT/home/Documents/PRDs/built-prds" 2>/dev/null || true

  # Allowlisted real config, copied (not symlinked) into the new HOME.
  local rel src dst
  for rel in $BUILD_TEST_ISOLATION_CONFIG_ALLOWLIST; do
    src="$real_home/$rel"
    [ -r "$src" ] || continue
    dst="$BUILD_TEST_ROOT/home/$rel"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true
    cp "$src" "$dst" 2>/dev/null || true
  done

  export HOME="$BUILD_TEST_ROOT/home"
  export BUILD_JOURNAL_ROOT="$BUILD_TEST_ROOT/journal"
  export BUILD_STATE_DIR="$BUILD_TEST_ROOT/state"
  export STATE_DIR="$BUILD_TEST_ROOT/state"
  export BURST_LANE_STATE_DIR="$BUILD_TEST_ROOT/state/burst-lane"
  export GATE_WEDGE_STATE_DIR="$BUILD_TEST_ROOT/state/gate-wedge"
  export GATE_BURST_STATE_DIR="$BUILD_TEST_ROOT/state/gate-burst"
  export PRD_DIR="$HOME/Documents/PRDs"

  # Arm isolation-guard.sh unconditionally (requirement 4). Legacy
  # BURST_LANE_TEST continues to work too (isolation-guard.sh checks both).
  export BUILD_TEST=1

  return 0
}
