#!/usr/bin/env bash
# archatomic_ac8_selftest_all_green.sh —
# PRD-build-archive-atomic-commit AC8: given the selftest fixture set,
# when the build selftest runs, then the archatomic cases are named and
# green. This wrapper requires no individual labels of its own (the
# other archatomic_ac<N> wrappers already pin those) — it exists to
# assert the shared suite as a whole exits 0, which
# run_suite_and_expect_labels already checks before looking at any
# requested labels.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels
