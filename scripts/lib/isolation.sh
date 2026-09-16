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

  # Fallback git identity — HOME moving means $HOME/.gitconfig (global
  # user.name/user.email) is gone, so ANY git operation under test that
  # needs to author a commit WITHOUT its own explicit `-c user.name=...
  # -c user.email=...` on that exact invocation dies with "unable to
  # auto-detect email address". Most fixture helpers pass -c explicitly
  # (archive-commit-selftest.sh's gc(), requeue-prd.sh's real Joe Yen
  # identity), but `git pull --rebase --autostash` creates its own
  # intermediate autostash-pop commit with no caller-supplied -c at all —
  # root-caused via a direct repro: archive-commit-selftest.sh's
  # MANBACKFILL AC7 fixture failed deterministically (3/3, not
  # intermittently as first suspected) under run-selftests.sh with
  # "Committer identity unknown" from exactly that rebase step, not from
  # any push/rebase timing race. Written as a plain global .gitconfig
  # (lowest git config precedence) rather than GIT_AUTHOR_*/GIT_COMMITTER_*
  # env vars — env vars WIN OVER a caller's own `-c user.name=...` (verified
  # directly: `git -c user.name="Config Name" commit` still authors as the
  # env var's name when GIT_AUTHOR_NAME is set), which silently broke
  # requeue-prd-selftest.sh's own "commit identity is Joe Yen" assertion
  # when tried. A .gitconfig only supplies the fallback a caller with no
  # identity opinion of its own falls through to; -c always still wins.
  if [ ! -f "$BUILD_TEST_ROOT/home/.gitconfig" ]; then
    git config --file "$BUILD_TEST_ROOT/home/.gitconfig" user.name "build-skill-test" 2>/dev/null || true
    git config --file "$BUILD_TEST_ROOT/home/.gitconfig" user.email "build-skill-test@localhost" 2>/dev/null || true
  fi

  export HOME="$BUILD_TEST_ROOT/home"
  export BUILD_JOURNAL_ROOT="$BUILD_TEST_ROOT/journal"
  export BUILD_STATE_DIR="$BUILD_TEST_ROOT/state"
  export STATE_DIR="$BUILD_TEST_ROOT/state"
  export BURST_LANE_STATE_DIR="$BUILD_TEST_ROOT/state/burst-lane"
  export GATE_WEDGE_STATE_DIR="$BUILD_TEST_ROOT/state/gate-wedge"
  export GATE_BURST_STATE_DIR="$BUILD_TEST_ROOT/state/gate-burst"
  export PRD_DIR="$HOME/Documents/PRDs"

  # select-tick.sh's BUILD_SUBAGENT_LIMIT (PRD-build-tick-under-dispatch-
  # ledger requirement 5, default 20 in production) would otherwise clamp
  # -- and journal `cap-clamped` -- on every isolated selftest that uses
  # BUILD_MAX_BRANCHES > 20 without an opinion of its own on the subagent
  # cap, which is every select-tick.sh selftest written before this PRD
  # existed. Neutralized here the same way every other production default
  # is neutralized for a test run: a test that actually wants to exercise
  # the clamp (see tests/udl_ac5_cap_clamped_subagent_limit.sh) sets
  # BUILD_SUBAGENT_LIMIT itself on that one call, which still wins (a
  # per-command env prefix always overrides an exported ambient value for
  # that command's own environment).
  export BUILD_SUBAGENT_LIMIT="${BUILD_SUBAGENT_LIMIT:-999999}"

  # Arm isolation-guard.sh unconditionally (requirement 4). Legacy
  # BURST_LANE_TEST continues to work too (isolation-guard.sh checks both).
  export BUILD_TEST=1

  return 0
}

# selftest_init — PRD-build-journal-single-writer requirement 3: the one
# prelude line a `scripts/*selftest*.sh` or `tests/*.sh` file sources
# before running anything under test, replacing each file's own hand-
# rolled `BUILD_TEST_ROOT="$(mktemp -d ...)"; export BUILD_TEST=1; export
# BUILD_TEST_ROOT; isolation_apply` block (the exact four lines
# run-selftests.sh itself already carries) with a single call. Mints a
# fresh per-run BUILD_TEST_ROOT (same /mnt/data/jsy/tmp/bs-test.XXXXXX
# convention run-selftests.sh uses — real disk, never /tmp tmpfs; see
# self_selftest_tmpfs_disk_guard), sets BUILD_TEST=1 and BUILD_TEST_ROOT,
# then delegates to isolation_apply for BUILD_JOURNAL_ROOT,
# BUILD_TEST_REAL_HOME, and the rest of the override set documented
# above. Idempotent: a caller that already exported BUILD_TEST_ROOT
# itself (e.g. run-selftests.sh, which still does its own setup so every
# test it execs inherits ONE shared root instead of each test minting a
# throwaway of its own) is left alone — selftest_init only mints a root
# when none is set yet, so a selftest sourcing this AS WELL AS being
# invoked through run-selftests.sh still shares run-selftests.sh's root
# rather than silently isolating itself into a second one.
#
# Returns non-zero (and prints to stderr) on mktemp failure; a caller
# should treat that as fatal, same as isolation_apply's own failure mode.
selftest_init() {
  if [ -z "${BUILD_TEST_ROOT:-}" ]; then
    BUILD_TEST_ROOT="$(mktemp -d "${TMPDIR:-/mnt/data/jsy/tmp}/bs-test.XXXXXX")" || {
      echo "isolation.sh: selftest_init: mktemp -d failed" >&2
      return 1
    }
    export BUILD_TEST_ROOT
  fi
  export BUILD_TEST=1
  isolation_apply || return 1

  # PRD-build-journal-single-writer requirement 6 (P1 nudge): one
  # `journal  test-run  (via=direct|runner name=<file>)` line per test that
  # sources this prelude, landing under $BUILD_JOURNAL_ROOT (the test
  # root isolation_apply just set — never production; journal_line is
  # already sourced by every caller of this file's convention, but source
  # it defensively here too so a bare `source isolation.sh; selftest_init`
  # with no other sourcing still works). RUN_SELFTESTS_RUNNER=1 is set by
  # run-selftests.sh around each test it invokes (see that script); a test
  # invoked any other way (a coordinator running one selftest directly, a
  # human at a shell) is "direct". scripts/tick-selftest-summary.sh reads
  # these lines back to derive the tick summary's `selftests direct=<n>
  # runner=<n>` field (SKILL.md's dispatch-nudge doc).
  if ! command -v journal_line >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/journal.sh" 2>/dev/null || true
  fi
  if command -v journal_line >/dev/null 2>&1; then
    local via="direct"
    [ "${RUN_SELFTESTS_RUNNER:-0}" = "1" ] && via="runner"
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  journal  test-run  (via=$via name=${0##*/})"
  fi
  return 0
}
