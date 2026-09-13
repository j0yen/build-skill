#!/usr/bin/env bash
# archverify_ac3_no_manifest_patch_on_failure.sh —
# PRD-build-archive-verify-before-shipped acceptance criterion 3: given
# archive-commit.sh exits non-zero, when the calling branch's Phase 4
# archive step follows the documented ordering (SKILL.md's "archive"
# bullet — gate the manifest-set.sh status:shipped/built patch on
# archive-commit.sh's own exit code), then no manifest patch sets
# status: shipped/built for that action.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archverify-ac-common.sh"
run_suite_and_expect_labels \
  "ok  ARCHVERIFY AC3: ordering never patches status:shipped on a non-zero archive-commit exit"
