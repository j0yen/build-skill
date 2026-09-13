#!/usr/bin/env bash
# archverify_ac2_lying_push_is_not_treated_as_archived.sh —
# PRD-build-archive-verify-before-shipped acceptance criterion 2 /
# requirement 5's own fixture: given a fixture where the git-mv silently
# fails to land (simulated here via a stubbed `git` whose `push`
# subcommand reports success without actually reaching origin), when
# archive-commit.sh runs, then it exits non-zero and prints a reason
# naming the missing postcondition — never the false success this PRD
# is named for.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archverify-ac-common.sh"
run_suite_and_expect_labels \
  "ok  ARCHVERIFY AC1/AC2: exits non-zero despite the push reporting success" \
  "ok  ARCHVERIFY AC1/AC2: names postcondition-failed" \
  "ok  ARCHVERIFY AC1/AC2: origin never actually received the commit" \
  "ok  ARCHVERIFY AC1/AC2: exit code is 8 (postcondition-failed, not retried)"
