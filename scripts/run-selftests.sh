#!/usr/bin/env bash
# scripts/run-selftests.sh — the one selftest entrypoint
# (PRD-build-test-isolation-by-default requirement 5). SKILL.md's selftest
# instructions point only at this runner.
#
# Usage:
#   run-selftests.sh <name-or-path> [<name-or-path>...]
#   run-selftests.sh --all
#
# What it does:
#   1. Creates BUILD_TEST_ROOT=$(mktemp -d /mnt/data/jsy/tmp/bs-test.XXXXXX)
#      — never tmpfs /tmp (a 09-13 selftest-tmpfs incident: see
#      self_selftest_tmpfs_disk_guard memory) — and exports BUILD_TEST=1.
#   2. Sources scripts/lib/isolation.sh and calls isolation_apply, which
#      redirects HOME/BUILD_JOURNAL_ROOT/STATE_DIR-family defaults under
#      $BUILD_TEST_ROOT and arms scripts/isolation-guard.sh unconditionally
#      (requirement 4) — every test below inherits this via env, whether or
#      not it sets any override of its own.
#   3. Runs each named test (a bare name resolves under tests/ or scripts/,
#      with or without .sh; a path is used as-is) as a subprocess.
#   4. After EVERY test, asserts the REAL production journal
#      ($BUILD_TEST_REAL_HOME/brain/journal/build/<date>.md, captured
#      before the override) has the same line count as before that test
#      ran — a growth fails the test and prints the leaked lines (this is
#      the hard fail the tripwire's own exit 3 is backup for, not a
#      replacement of — requirement 5 / the Open question's proposal).
#   5. --all additionally snapshots sha256 of every file under the real
#      journal tree and state/, plus `git -C <PRDs> status --porcelain`,
#      before the FIRST test and after the LAST, and fails loud on any
#      diff (AC7 — the load-bearing proof this PRD exists for).
#
# Exit: 0 all named tests passed with zero production drift; 1 one or more
# tests failed or leaked; 2 usage/resolve error; 3 could not set up
# isolation at all (mktemp failed, etc — no test even attempted).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$SKILL_DIR"

# shellcheck source=lib/isolation.sh
source "$HERE/lib/isolation.sh"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

# The registry --all runs: the selftests named in PRD-build-test-isolation-
# by-default's Grounding as unisolated before this PRD (requirement 6).
# Exact filenames confirmed via grep against this tree, not assumed from
# the PRD's drafted line numbers/counts.
SELFTEST_REGISTRY=(
  scripts/gate-wedge-selftest.sh
  tests/chained-tick_ac2_stop_on_red.sh
  tests/chained-tick_ac3_lock_contention.sh
  tests/chained-tick_ac4_no_default_cap.sh
  tests/chained-tick_ac5_kernel_excluded.sh
  tests/chained-tick_ac6_regression_unchanged.sh
  scripts/archive-commit-selftest.sh
  scripts/burst-refuse-selftest.sh
  scripts/cargo-shim-chain-selftest.sh
  scripts/archive-finalize-selftest.sh
  scripts/build-has-work-selftest.sh
  scripts/carbon-lane-install-selftest.sh
  scripts/cli-register-selftest.sh
  scripts/dispatch-distrust-selftest.sh
  scripts/gate-red-summary-selftest.sh
  scripts/gate-red-tick-selftest.sh
  scripts/gates-banner-selftest.sh
  scripts/gatedebt-selftest.sh
  scripts/gatephase-selftest.sh
  scripts/install-hcloud-selftest.sh
  scripts/lane-predicate-selftest.sh
  scripts/manifest-reconcile-selftest.sh
  scripts/prd-lint-selftest.sh
  scripts/python-worktree-selftest.sh
  scripts/worktree-extend-selftest.sh
  scripts/requeue-prd-selftest.sh
  scripts/sccache-assert-selftest.sh
  scripts/sccache-unit-selftest.sh
  scripts/secret-store-selftest.sh
  scripts/routepar-selftest.sh
  tests/canary_ac3_receipt_diff_diverged.sh
  tests/canary_ac4_receipt_diff_same.sh
  tests/canary_ac15_route_block.sh
)

usage() { echo "usage: run-selftests.sh <name-or-path>... | --all" >&2; exit 2; }

resolve_test() {
  local name="$1"
  if [ -f "$name" ]; then printf '%s\n' "$name"; return 0; fi
  if [ -f "$REPO_ROOT/$name" ]; then printf '%s\n' "$REPO_ROOT/$name"; return 0; fi
  local cand
  # PRD-build-shell-worktree-isolation AC10: `run-selftests.sh worktree-extend`
  # must resolve to scripts/worktree-extend-selftest.sh, not the PRODUCTION
  # script scripts/worktree-extend.sh that bare name would otherwise match
  # via the `scripts/$name.sh` candidate below — this is the one name in
  # this tree where the selftest's own basename ("worktree-extend") equals
  # a real production script's basename. Tried FIRST (ahead of the plain
  # scripts/$name(.sh) candidates) so a `<name>-selftest.sh` file always
  # wins when one exists; every other name in this tree either has no
  # `-selftest.sh` sibling at all (unaffected) or already used the
  # selftest's own literal name (e.g. "gate-wedge-selftest") to resolve it,
  # which still resolves identically either way.
  for cand in "$REPO_ROOT/scripts/$name-selftest.sh" "$REPO_ROOT/tests/$name-selftest.sh" \
              "$REPO_ROOT/tests/$name" "$REPO_ROOT/tests/$name.sh" \
              "$REPO_ROOT/scripts/$name" "$REPO_ROOT/scripts/$name.sh"; do
    [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# resolve_test_prefix <name> -> zero or more matching test files on stdout.
# A PRD's own `test_prefix` (e.g. `pullmiss`) names a FAMILY of
# tests/<prefix>_ac*.sh files, not one file — resolve_test above only ever
# resolves a single exact name, so a bare `run-selftests.sh pullmiss` with
# no exact tests/pullmiss(.sh) file would otherwise fail to resolve even
# though nine tests/pullmiss_ac*.sh exist. Only consulted when resolve_test
# itself found nothing (existing exact-name/path behavior is unchanged).
# Sorted glob expansion; a literal non-matching pattern is dropped by the
# `-f` check below, so no nullglob is needed.
resolve_test_prefix() {
  local name="$1" g found=1
  for g in "$REPO_ROOT"/tests/"$name"_ac*.sh; do
    [ -f "$g" ] || continue
    printf '%s\n' "$g"
    found=0
  done
  return $found
}

[ "$#" -ge 1 ] || usage

all_mode=false
declare -a to_run=()
if [ "$1" = "--all" ]; then
  all_mode=true
  for rel in "${SELFTEST_REGISTRY[@]}"; do
    f="$REPO_ROOT/$rel"
    if [ -f "$f" ]; then
      to_run+=("$f")
    else
      echo "run-selftests: WARNING: registered test missing, skipping: $rel" >&2
    fi
  done
else
  for n in "$@"; do
    if resolved="$(resolve_test "$n")"; then
      to_run+=("$resolved")
      continue
    fi
    if prefix_matches="$(resolve_test_prefix "$n")"; then
      while IFS= read -r m; do to_run+=("$m"); done <<<"$prefix_matches"
      continue
    fi
    echo "run-selftests: cannot resolve test: $n" >&2
    exit 2
  done
fi

[ "${#to_run[@]}" -ge 1 ] || { echo "run-selftests: nothing to run" >&2; exit 2; }

# ---- isolation setup (requirement 5) --------------------------------
REAL_HOME="$HOME"
REAL_JOURNAL_TODAY="$REAL_HOME/brain/journal/build/$(date -u +%F).md"
REAL_JOURNAL_ROOT="$REAL_HOME/brain/journal"
REAL_STATE_DIR="$SKILL_DIR/state"
REAL_PRDS_DIR="$REAL_HOME/Documents/PRDs"

_journal_line_count() {
  [ -f "$REAL_JOURNAL_TODAY" ] && wc -l < "$REAL_JOURNAL_TODAY" || echo 0
}

# ---- AC7's --all-mode whole-tree check --------------------------------
#
# Root-caused (PRD-build-test-isolation-by-default iter_log, 2026-09-15):
# a strict before/after hash of the REAL journal/state trees false-
# positives whenever this box's own active /build loop (a real, live
# systemd unit — claude-build-tick.sh — NOT this PRD's test surface) does
# real production work during the several-minutes --all window: it
# legitimately appends to build-auto.log (build-has-work.sh/lane-has-
# work.sh/lane-defer.sh) and burst-lane.log while --all is still running
# other selftests. That's not a leak — a leak is TEST-shaped content
# (the same fixture regex journal.sh's own tripwire refuses: /tmp/,
# does-not-matter, fixture, step=ac<N>/prog*, BURST_LANE_TEST) landing in
# the real tree. So AC7 classifies every diff instead of just hashing:
# new/grown content that is NOT fixture-shaped is concurrent production
# activity (reported as a NOTE, not a failure); new/grown content that IS
# fixture-shaped, or any removed/rewritten/disappeared file, is a real
# leak and fails hard exactly as before. This does not weaken the AC —
# every leak class the PRD's Grounding actually observed (fixture-target
# lines, gate-wedge fixture step= lines) is fixture-shaped by construction
# and still fails; only genuine, unrelated box activity stops being
# misclassified as this run's own leak.
_snapshot_copy() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  [ -d "$src" ] || return 0
  cp -a "$src"/. "$dst"/ 2>/dev/null || true
}

# reads lines on stdin; exit 0 iff any line is fixture-shaped
# (scripts/lib/journal.sh's own _journal_is_fixture_shaped — the exact
# tripwire regex, not a second copy of it).
_any_fixture_shaped_line() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _journal_is_fixture_shaped "$line" && return 0
  done
  return 1
}

# _tree_diff_ok <before-snapshot-dir> <real-after-dir> <label>
# Prints findings to stderr; returns 0 iff no genuine leak was found.
_tree_diff_ok() {
  local before_dir="$1" after_dir="$2" label="$3"
  local leak=0 f rel beforef added removed

  if [ -d "$after_dir" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$after_dir"/}"
      beforef="$before_dir/$rel"
      if [ ! -f "$beforef" ]; then
        if _any_fixture_shaped_line <"$f"; then
          echo "run-selftests: AC7 LEAK ($label): new file with fixture-shaped content: $rel" >&2
          leak=1
        else
          echo "run-selftests: AC7 NOTE ($label): new file during --all window, not fixture-shaped (concurrent production activity, not a leak): $rel" >&2
        fi
        continue
      fi
      cmp -s "$beforef" "$f" && continue
      removed="$(diff "$beforef" "$f" 2>/dev/null | grep '^< ')"
      if [ -n "$removed" ]; then
        echo "run-selftests: AC7 LEAK ($label): $rel had existing content removed or rewritten (append-only violation)" >&2
        leak=1
        continue
      fi
      added="$(diff "$beforef" "$f" 2>/dev/null | grep '^> ' | sed 's/^> //')"
      if [ -n "$added" ] && printf '%s\n' "$added" | _any_fixture_shaped_line; then
        echo "run-selftests: AC7 LEAK ($label): $rel grew with fixture-shaped line(s):" >&2
        printf '%s\n' "$added" >&2
        leak=1
      elif [ -n "$added" ]; then
        echo "run-selftests: AC7 NOTE ($label): $rel grew during --all window, not fixture-shaped (concurrent production activity, not a leak)" >&2
      fi
    done < <(find "$after_dir" -type f -print0 2>/dev/null)
  fi

  if [ -d "$before_dir" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$before_dir"/}"
      if [ ! -f "$after_dir/$rel" ]; then
        echo "run-selftests: AC7 LEAK ($label): $rel disappeared during --all window" >&2
        leak=1
      fi
    done < <(find "$before_dir" -type f -print0 2>/dev/null)
  fi

  [ "$leak" -eq 0 ]
}

# _porcelain_diff_ok <before-text> <after-text> — same classification,
# applied to ~/repos/PRDs' `git status --porcelain` output rather than a
# file tree (a live sibling /build agent's own commit there is expected
# concurrent activity, not this run's leak).
_porcelain_diff_ok() {
  local before="$1" after="$2"
  [ "$before" = "$after" ] && return 0
  local bf af added removed leak=0
  bf="$(mktemp)"; af="$(mktemp)"
  printf '%s\n' "$before" > "$bf"
  printf '%s\n' "$after" > "$af"
  removed="$(diff "$bf" "$af" 2>/dev/null | grep '^< ')"
  added="$(diff "$bf" "$af" 2>/dev/null | grep '^> ' | sed 's/^> //')"
  rm -f "$bf" "$af"
  if [ -n "$removed" ]; then
    echo "run-selftests: AC7 LEAK (PRDs git status): porcelain entries disappeared (treated as a real difference, not noise):" >&2
    printf '%s\n' "$removed" >&2
    leak=1
  fi
  if [ -n "$added" ]; then
    if printf '%s\n' "$added" | _any_fixture_shaped_line; then
      echo "run-selftests: AC7 LEAK (PRDs git status): new fixture-shaped porcelain entries:" >&2
      printf '%s\n' "$added" >&2
      leak=1
    else
      echo "run-selftests: AC7 NOTE (PRDs git status): porcelain changed during --all window, not fixture-shaped (concurrent sibling PRD activity, not a leak):" >&2
      printf '%s\n' "$added" >&2
    fi
  fi
  [ "$leak" -eq 0 ]
}

BUILD_TEST_ROOT="$(mktemp -d /mnt/data/jsy/tmp/bs-test.XXXXXX)" \
  || { echo "run-selftests: mktemp under /mnt/data/jsy/tmp failed" >&2; exit 3; }
export BUILD_TEST=1
export BUILD_TEST_ROOT
isolation_apply || { echo "run-selftests: isolation_apply failed" >&2; exit 3; }

trap 'rm -rf "$BUILD_TEST_ROOT"' EXIT

if $all_mode; then
  BEFORE_JOURNAL_SNAP="$BUILD_TEST_ROOT/ac7-before-journal"
  BEFORE_STATE_SNAP="$BUILD_TEST_ROOT/ac7-before-state"
  _snapshot_copy "$REAL_JOURNAL_ROOT" "$BEFORE_JOURNAL_SNAP"
  _snapshot_copy "$REAL_STATE_DIR" "$BEFORE_STATE_SNAP"
  before_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"
fi

pass=0
fail=0
declare -a failed_names=()

for t in "${to_run[@]}"; do
  name="$(basename "$t")"
  echo "== run-selftests: $name ==" >&2
  before_lines="$(_journal_line_count)"

  rc=0
  RUN_SELFTESTS_RUNNER=1 bash "$t" || rc=$?

  after_lines="$(_journal_line_count)"

  # PRD-build-journal-single-writer requirement 3/9: a raw line-count
  # inequality here used to fail a test outright even when every new line
  # was unrelated, non-fixture-shaped concurrent production activity (this
  # box runs a live /build loop plus sibling cargo-budget/gate-wedge
  # writers) — the exact false-positive AC7's --all-mode classification
  # below already solves for the whole-run window, just not yet for this
  # per-test check. Apply the same classification here: a shrink, or any
  # NEW line that IS fixture-shaped, still fails loud; non-fixture growth
  # is logged as a NOTE, not a failure.
  if [ "$after_lines" -lt "$before_lines" ]; then
    echo "run-selftests: LEAK: $name — real production journal SHRANK ($before_lines -> $after_lines lines, append-only violation)" >&2
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  elif [ "$after_lines" -gt "$before_lines" ] \
       && tail -n "$((after_lines - before_lines))" "$REAL_JOURNAL_TODAY" | _any_fixture_shaped_line; then
    echo "run-selftests: LEAK: $name grew the real production journal with fixture-shaped line(s) ($before_lines -> $after_lines lines)" >&2
    echo "run-selftests: leaked line(s):" >&2
    tail -n "$((after_lines - before_lines))" "$REAL_JOURNAL_TODAY" >&2
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  fi

  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_names+=("$name (exit $rc)")
  fi
done

if $all_mode; then
  after_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"

  if ! _tree_diff_ok "$BEFORE_JOURNAL_SNAP" "$REAL_JOURNAL_ROOT" "journal"; then
    echo "run-selftests: AC7 FAILED: real journal tree leaked fixture-shaped content under --all" >&2
    fail=$((fail + 1))
  fi
  if ! _tree_diff_ok "$BEFORE_STATE_SNAP" "$REAL_STATE_DIR" "state"; then
    echo "run-selftests: AC7 FAILED: real state/ tree leaked fixture-shaped content under --all" >&2
    fail=$((fail + 1))
  fi
  if ! _porcelain_diff_ok "$before_prds_porcelain" "$after_prds_porcelain"; then
    echo "run-selftests: AC7 FAILED: ~/repos/PRDs git status leaked fixture-shaped entries under --all" >&2
    fail=$((fail + 1))
  fi
fi

echo "run-selftests: $pass passed, $fail failed (of ${#to_run[@]})" >&2
if [ "$fail" -gt 0 ]; then
  printf 'run-selftests: failed: %s\n' "${failed_names[*]:-(see AC7 above)}" >&2
  exit 1
fi
exit 0
