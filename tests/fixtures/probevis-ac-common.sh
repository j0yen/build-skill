#!/usr/bin/env bash
# probevis-ac-common.sh — shared helper for the tests/probevis_ac<N>_*.sh
# per-AC wrapper files (PRD-build-burst-probe-visibility). This PRD's own
# dedicated fixture (scripts/burst-lane-probe-visibility-selftest.sh) already
# exercises every P0 AC as a set of named `ok  <label>` assertions against
# the real burst-lane.sh code with fake hcloud/ssh/rsync — there is no
# separate, independently-implemented per-AC test body here, deliberately:
# a second, hand-duplicated implementation per AC would drift from the real
# one and prove nothing an edit to burst-lane.sh's actual logic couldn't
# silently invalidate. Instead, each wrapper runs the real dedicated fixture
# (matching burst-lane-ac-common.sh's/burstfor-ac-common.sh's own model, but
# pointed at this PRD's own smaller, fast-running fixture rather than the
# whole burst-lane-selftest.sh monolith — that fixture covers many OTHER
# PRDs' ACs too and is not this PRD's own test unit) and requires BOTH that
# it exits 0 AND that the specific labeled assertions for its AC are present
# in the output — so a future edit that silently drops or renames this AC's
# coverage fails this file too, not just a reshuffled label nobody notices.
run_probevis_suite_and_expect_labels() {  # $@ = exact "ok  <label>" lines required
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/burst-lane-probe-visibility-selftest.sh"
  [ -x "$suite" ] || { echo "FAIL: $suite not executable" >&2; return 2; }
  # PRD-build-burst-selftest-isolation requirement 1: belt-and-suspenders —
  # the fixture already self-exports this at its own top, but every
  # tests/*.sh is required to export it too, so this wrapper does not rely
  # solely on the suite it calls remembering to.
  #
  # BUILD_BURST_ENABLED=1 (PRD-build-burst-probe-visibility gap found
  # 2026-09-13): the suite's own header documents itself as run via
  # `BUILD_BURST_ENABLED=1 bash burst-lane-probe-visibility-selftest.sh`
  # because burst-lane.sh's `up`/`provision` subcommands genuinely refuse
  # under the 2026-09-11 RedBaron-local policy unless burst_configured()
  # is true (lib/burst-configured.sh) — without this the suite prints one
  # `SKIP: burst lane dormant` line and exits 0 before running any of its
  # 37 assertions, which every one of these AC wrappers then misread as
  # "suite passed, labels just missing" -> FAIL. Setting it here is safe:
  # it never reaches real infra — fresh_env() inside the suite overrides
  # PATH to tests/fixtures/burst-lane-fake (fake hcloud/ssh/rsync) before
  # `$BL up`/`$BL provision` ever runs, so this only unlocks the in-process
  # fixture proof, on every host regardless of that host's real burst
  # policy — exactly what a dormant-by-design host (RedBaron today) needs
  # for these P0, fixture-only ACs to be provable at all.
  out="$(BURST_LANE_TEST=1 BUILD_BURST_ENABLED=1 bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: burst-lane-probe-visibility-selftest.sh exited $rc" >&2
    echo "$out" | tail -20 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from burst-lane-probe-visibility-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
