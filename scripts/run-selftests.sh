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
  scripts/gatedebt-selftest.sh
  scripts/gatephase-selftest.sh
  scripts/install-hcloud-selftest.sh
  scripts/lane-predicate-selftest.sh
  scripts/manifest-reconcile-selftest.sh
  scripts/prd-lint-selftest.sh
  scripts/python-worktree-selftest.sh
  scripts/requeue-prd-selftest.sh
  scripts/sccache-assert-selftest.sh
  scripts/sccache-unit-selftest.sh
  scripts/secret-store-selftest.sh
)

usage() { echo "usage: run-selftests.sh <name-or-path>... | --all" >&2; exit 2; }

resolve_test() {
  local name="$1"
  if [ -f "$name" ]; then printf '%s\n' "$name"; return 0; fi
  if [ -f "$REPO_ROOT/$name" ]; then printf '%s\n' "$REPO_ROOT/$name"; return 0; fi
  local cand
  for cand in "$REPO_ROOT/tests/$name" "$REPO_ROOT/tests/$name.sh" \
              "$REPO_ROOT/scripts/$name" "$REPO_ROOT/scripts/$name.sh"; do
    [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
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
    resolved="$(resolve_test "$n")" || { echo "run-selftests: cannot resolve test: $n" >&2; exit 2; }
    to_run+=("$resolved")
  done
fi

[ "${#to_run[@]}" -ge 1 ] || { echo "run-selftests: nothing to run" >&2; exit 2; }

# ---- isolation setup (requirement 5) --------------------------------
REAL_HOME="$HOME"
REAL_JOURNAL_TODAY="$REAL_HOME/brain/journal/build/$(date -u +%F).md"
REAL_JOURNAL_ROOT="$REAL_HOME/brain/journal"
REAL_STATE_DIR="$SKILL_DIR/state"
REAL_PRDS_DIR="$REAL_HOME/Documents/PRDs"

_snapshot_hashes() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
}

_journal_line_count() {
  [ -f "$REAL_JOURNAL_TODAY" ] && wc -l < "$REAL_JOURNAL_TODAY" || echo 0
}

BUILD_TEST_ROOT="$(mktemp -d /mnt/data/jsy/tmp/bs-test.XXXXXX)" \
  || { echo "run-selftests: mktemp under /mnt/data/jsy/tmp failed" >&2; exit 3; }
export BUILD_TEST=1
export BUILD_TEST_ROOT
isolation_apply || { echo "run-selftests: isolation_apply failed" >&2; exit 3; }

trap 'rm -rf "$BUILD_TEST_ROOT"' EXIT

if $all_mode; then
  before_journal_hash="$(_snapshot_hashes "$REAL_JOURNAL_ROOT")"
  before_state_hash="$(_snapshot_hashes "$REAL_STATE_DIR")"
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
  bash "$t" || rc=$?

  after_lines="$(_journal_line_count)"

  if [ "$after_lines" != "$before_lines" ]; then
    echo "run-selftests: LEAK: $name grew the real production journal ($before_lines -> $after_lines lines)" >&2
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
  after_journal_hash="$(_snapshot_hashes "$REAL_JOURNAL_ROOT")"
  after_state_hash="$(_snapshot_hashes "$REAL_STATE_DIR")"
  after_prds_porcelain="$(git -C "$REAL_PRDS_DIR" status --porcelain 2>/dev/null)"

  if [ "$before_journal_hash" != "$after_journal_hash" ]; then
    echo "run-selftests: AC7 FAILED: real journal tree changed under --all" >&2
    diff <(printf '%s\n' "$before_journal_hash") <(printf '%s\n' "$after_journal_hash") >&2 || true
    fail=$((fail + 1))
  fi
  if [ "$before_state_hash" != "$after_state_hash" ]; then
    echo "run-selftests: AC7 FAILED: real state/ tree changed under --all" >&2
    diff <(printf '%s\n' "$before_state_hash") <(printf '%s\n' "$after_state_hash") >&2 || true
    fail=$((fail + 1))
  fi
  if [ "$before_prds_porcelain" != "$after_prds_porcelain" ]; then
    echo "run-selftests: AC7 FAILED: ~/repos/PRDs git status changed under --all" >&2
    diff <(printf '%s\n' "$before_prds_porcelain") <(printf '%s\n' "$after_prds_porcelain") >&2 || true
    fail=$((fail + 1))
  fi
fi

echo "run-selftests: $pass passed, $fail failed (of ${#to_run[@]})" >&2
if [ "$fail" -gt 0 ]; then
  printf 'run-selftests: failed: %s\n' "${failed_names[*]:-(see AC7 above)}" >&2
  exit 1
fi
exit 0
