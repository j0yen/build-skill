#!/usr/bin/env bash
# pullback-ac-common.sh — shared harness for tests/pullback_ac*.sh
# (PRD-build-burst-pull-back-restore).
#
# Unlike PRD-build-burst-selftest-block-scoped-summary's blockscope_ac*.sh
# wrappers (tests/fixtures/blockscope-ac-common.sh), the pull-back ACs are
# not isolated functions this fixture can extract and re-run in a fixture
# body — they are ~14 real end-to-end cases woven inline, top to bottom,
# through the one 4500+-line scripts/burst-lane-selftest.sh, sharing state
# ($T, $BL, session.json, the fake hcloud/ssh/rsync) across hundreds of
# preceding lines. The suite has no per-case or per-block filter (see its
# own header — no argument parsing at all), so the only faithful way to
# exercise "the relevant selftest case" for a pull-back AC is to run the
# WHOLE suite once and read its combined stdout+stderr for that AC's
# specific ok/FAIL lines, exactly as `~/.claude/skills/build/scripts/
# verified-completed.sh` or a human running the suite by hand would.
#
# pullback_run_suite() does exactly that, with two things this PRD itself
# diagnosed layered on top:
#
#  1. Disk-floor override (AC1's own diagnosis, 2026-09-13): the suite's
#     worktrees land under $TMPDIR/mktemp (burst-lane-selftest.sh's own
#     fresh_env, ~line 242), which on both RedBaron and this dev box is a
#     tmpfs far smaller than do_marker_pull's default 60 GB
#     BURST_LOCAL_DISK_FLOOR_GB floor (burst-lane.sh ~line 493) — every
#     fixture pull was getting deferred by the guard rather than actually
#     exercised. burst-lane.sh already honors BURST_LOCAL_DISK_FLOOR_GB as
#     a real env override (never edited by this fixture — see the
#     Migration section of the PRD). Setting it low here is the external
#     equivalent of what AC1 asks the SUITE ITSELF to do (set the fixture
#     floor explicitly, journal the worktree filesystem/free space) — that
#     suite-side half is not implemented yet, which is exactly what
#     tests/pullback_ac1_fixture_floor_control.sh reports as a gap.
#
#  2. The teardown-sweep money guard (burst-lane.sh sweep_dirty_worktrees,
#     ~line 4993) skips every pull-back sweep entirely unless this host's
#     REAL `claude-build.path` systemd --user unit reports active — by
#     design (2026-09-11 money guard: an unattended sweep must never run
#     once the loop has stopped). This fixture never starts or stops that
#     real unit (a carbon/ryzen7 host has it deliberately inactive per
#     current build-lane policy — RedBaron only); it only reports whether
#     it's active, via pullback_loop_active(), so a wrapper whose AC
#     depends on the sweep actually running (AC8, AC10) can tell "cannot
#     verify on this host" apart from a real failure.
#
# Cache: many wrappers need the SAME full-suite run, and the suite takes
# real wall-clock minutes with no per-case filter to shorten it. Results
# are cached under a content-hash key (the suite + burst-lane.sh bytes, so
# any edit to either invalidates it) and flock-serialized so concurrent
# wrapper runs share one execution instead of each re-running the suite.
set -uo pipefail
PULLBACK_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULLBACK_SUITE="$PULLBACK_HERE/../../scripts/burst-lane-selftest.sh"
PULLBACK_BURST_LANE="$PULLBACK_HERE/../../scripts/burst-lane.sh"
[ -f "$PULLBACK_SUITE" ] || { echo "FAIL: $PULLBACK_SUITE not found" >&2; exit 2; }
[ -f "$PULLBACK_BURST_LANE" ] || { echo "FAIL: $PULLBACK_BURST_LANE not found" >&2; exit 2; }

: "${PULLBACK_FLOOR_GB:=2}"

PULLBACK_CACHE_DIR="${TMPDIR:-/tmp}/pullback-selftest-cache"
mkdir -p "$PULLBACK_CACHE_DIR" 2>/dev/null || true
_pullback_key="$(cat "$PULLBACK_SUITE" "$PULLBACK_BURST_LANE" 2>/dev/null | sha256sum | cut -c1-16)-floor${PULLBACK_FLOOR_GB}"
PULLBACK_CACHE_OUT="$PULLBACK_CACHE_DIR/$_pullback_key.out"
PULLBACK_CACHE_RC="$PULLBACK_CACHE_DIR/$_pullback_key.rc"
PULLBACK_CACHE_LOCK="$PULLBACK_CACHE_DIR/$_pullback_key.lock"

# pullback_run_suite -> sets PULLBACK_OUT (combined stdout+stderr of the
# real offline selftest) and PULLBACK_RC (its exit code).
pullback_run_suite() {
  (
    exec 209>"$PULLBACK_CACHE_LOCK"
    flock 209
    if [ ! -s "$PULLBACK_CACHE_OUT" ]; then
      BUILD_BURST_ENABLED=1 BURST_LOCAL_DISK_FLOOR_GB="$PULLBACK_FLOOR_GB" \
        bash "$PULLBACK_SUITE" > "$PULLBACK_CACHE_OUT.tmp" 2>&1
      echo $? > "$PULLBACK_CACHE_RC.tmp"
      mv "$PULLBACK_CACHE_OUT.tmp" "$PULLBACK_CACHE_OUT"
      mv "$PULLBACK_CACHE_RC.tmp" "$PULLBACK_CACHE_RC"
    fi
  )
  PULLBACK_OUT="$(cat "$PULLBACK_CACHE_OUT" 2>/dev/null)"
  PULLBACK_RC="$(cat "$PULLBACK_CACHE_RC" 2>/dev/null || echo 1)"
}

# pullback_loop_active -> rc0 iff this host's real build loop is active
# (never started/stopped by this fixture — see header).
pullback_loop_active() {
  [ "$(systemctl --user is-active claude-build.path 2>/dev/null)" = "active" ]
}
