# gatefirst-ac-common.sh — shared helpers for the tests/gatefirst_ac<N>_*.sh
# per-AC wrapper files (PRD-build-gate-before-land, test_prefix `gatefirst`).
#
# Unlike a single-suite PRD (e.g. tests/fixtures/cargoroute-ac-common.sh,
# one selftest backs every AC), this PRD's 13 ACs span SEVEN existing,
# already-passing selftests, each written and reviewed for its own
# requirement before this pairing layer existed: extend-gate-scope-
# selftest.sh (req 1), extend-gate-concurrent-selftest.sh (req 1's no-
# crate-lock claim), worktree-extend-gated-land-selftest.sh (req 2),
# gate-then-land-selftest.sh (req 3), gate-verdict-tree-cache-selftest.sh
# (req 4), select-guard-same-target-cap-selftest.sh (req 5), extend-gate-
# cargo-route-selftest.sh (req 6's AC10 case), and serialization-digest-
# selftest.sh (req 7). There is no separate, hand-duplicated per-AC test
# body here, deliberately, mirroring every other tests/fixtures/*-ac-
# common.sh convention in this repo: each wrapper runs the real suite and
# requires BOTH that it exits 0 AND that the specific labeled assertions
# for its AC are present in the output.
#
# Env isolation: every runner below explicitly unsets BUILD_DISTINCT_
# TARGETS / BUILD_SAME_TARGET_CAP / BUILD_SAME_TARGET_CAP_BURST /
# BUILD_MAX_BRANCHES before invoking its suite. A live /build tick's own
# ambient environment (e.g. an orchestrator that has armed
# BUILD_DISTINCT_TARGETS=0 for this tick's own selection pass) otherwise
# leaks into these child selftests and changes their same-target-cap
# defaults out from under them — observed directly while authoring this
# file: select-guard-same-target-cap-selftest.sh and serialization-digest-
# selftest.sh's Part 1 both depend on the SCRIPT's documented default
# (cap=1 unset), not whatever the calling tick happens to have armed.

# Resolved once, at SOURCE time, from THIS file's own BASH_SOURCE[0] — every
# function below is defined in this same file, so BASH_SOURCE[0] is stable
# here regardless of how many function-call frames deep a caller invokes
# them from (a plain per-call `${BASH_SOURCE[1]}` breaks the moment one
# helper calls another, e.g. _gatefirst_run calling into a shared resolver
# — resolving once at source time sidesteps that entirely).
GATEFIRST_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_gatefirst_run() {  # $1 = suite path (relative to tests/), $@ rest = expected labels
  local suite="$1"; shift
  local script out rc fail=0 want
  script="$GATEFIRST_HERE/../../scripts/$suite"
  [ -x "$script" ] || { echo "FAIL: $script not executable" >&2; return 2; }
  out="$(env -u BUILD_DISTINCT_TARGETS -u BUILD_SAME_TARGET_CAP \
             -u BUILD_SAME_TARGET_CAP_BURST -u BUILD_MAX_BRANCHES \
         bash "$script" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $suite exited $rc" >&2
    echo "$out" | tail -40 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from $suite: $want" >&2
      fail=1
    fi
  done
  return $fail
}

run_scope_and_expect_labels()        { _gatefirst_run extend-gate-scope-selftest.sh "$@"; }
run_concurrent_and_expect_labels()   { _gatefirst_run extend-gate-concurrent-selftest.sh "$@"; }
run_gatedland_and_expect_labels()    { _gatefirst_run worktree-extend-gated-land-selftest.sh "$@"; }
run_gatethenland_and_expect_labels() { _gatefirst_run gate-then-land-selftest.sh "$@"; }
run_treecache_and_expect_labels()    { _gatefirst_run gate-verdict-tree-cache-selftest.sh "$@"; }
run_sametargetcap_and_expect_labels() { _gatefirst_run select-guard-same-target-cap-selftest.sh "$@"; }
run_cargoroute10_and_expect_labels() { _gatefirst_run extend-gate-cargo-route-selftest.sh "$@"; }
run_serialdigest_and_expect_labels() { _gatefirst_run serialization-digest-selftest.sh "$@"; }

# AC13 is prose, not behavior: no suite runs code, this greps SKILL.md
# itself for the requirement-8 wording contract (both former call sites
# describe gate-on-branch -> land-if-unchanged -> cached main check; the
# land-then-gate wording is absent as a live instruction). A HISTORICAL
# mention naming the old order while explaining why it changed (e.g. "The
# old land-then-gate order held the crate's integration lock...") is
# expected prose, not a live alternative, and is not treated as a failure
# here — only a "land-then-gate" occurrence NOT immediately preceded by
# "old " would be.
run_skillmd_wording_check() {
  local skill fail=0
  skill="$GATEFIRST_HERE/../../SKILL.md"
  [ -f "$skill" ] || { echo "FAIL: $skill not found" >&2; return 2; }

  if grep -qF 'scripts/gate-then-land.sh <build_into> <slug> <bump> <tldr-file>' "$skill"; then
    echo "ok  AC13: SKILL.md documents the gate-then-land.sh call"
  else
    echo "FAIL: AC13: gate-then-land.sh call not found in SKILL.md" >&2; fail=1
  fi

  if grep -qF '(cached tree=' "$skill"; then
    echo "ok  AC13: SKILL.md documents the cached-tree main check"
  else
    echo "FAIL: AC13: cached-tree wording not found in SKILL.md" >&2; fail=1
  fi

  # The literal phrase "land-then-gate" may survive ONLY as a historical
  # mention naming the order this PRD replaced (e.g. "the old land-then-
  # gate order held..."), never as a live instruction — every occurrence
  # must be immediately preceded by "old " on the same line.
  local bad
  bad="$(grep -n 'land-then-gate' "$skill" | grep -v 'old land-then-gate' || true)"
  if [ -z "$bad" ]; then
    echo "ok  AC13: land-then-gate wording survives only as historical (old) mention, not a live instruction"
  else
    echo "FAIL: AC13: land-then-gate wording survives as more than a historical mention:" >&2
    printf '%s\n' "$bad" >&2
    fail=1
  fi

  return $fail
}
