#!/usr/bin/env bash
# archatomic_ac7_skill_md_one_command.sh —
# PRD-build-archive-atomic-commit AC7: given the shipped SKILL.md, when
# grepped, then the archive step names archive-commit.sh and contains no
# `git mv` or `Status:`-editing instructions.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC7: SKILL.md archive step names archive-commit.sh" \
  "ok  AC7: SKILL.md archive step has no git-mv instruction" \
  "ok  AC7: SKILL.md archive step has no manual Status: edit"
