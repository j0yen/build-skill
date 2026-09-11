#!/usr/bin/env bash
# isolate_ac5_fixture_named_box_dir_fails.sh —
# PRD-build-burst-selftest-isolation AC5: a fake box listing a
# gb-ac3.XXXX-style directory while a session is active fails the
# selftest's box-isolation check, naming the offending directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/isolate-ac-common.sh"
run_suite_and_expect_labels \
  "ok  isolate AC5: box-isolation-check fails with a fixture-named box dir present" \
  "ok  isolate AC5: it names the offending directory" \
  "ok  isolate AC5: clean once the fixture-named dir is gone"
