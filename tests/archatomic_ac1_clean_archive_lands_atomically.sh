#!/usr/bin/env bash
# archatomic_ac1_clean_archive_lands_atomically.sh —
# PRD-build-archive-atomic-commit AC1: given a fixture repo with a queued
# PRD, a fake receipt, and a bare origin, when archive-commit.sh <slug>
# runs, then built-prds/PRD-<slug>.md carries Status/Built/Receipts,
# build-queue/ no longer has the file, the manifest line says shipped,
# the working tree is clean, and origin has exactly one new commit titled
# "archive: <slug> shipped" containing all three changes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: archive-commit exits 0" \
  "ok  AC1: built-prds/PRD-clean1.md carries Status: built" \
  "ok  AC1: built-prds/PRD-clean1.md carries a Built: line" \
  "ok  AC1: built-prds/PRD-clean1.md carries a Receipts: line" \
  "ok  AC1: build-queue/PRD-clean1.md is gone" \
  "ok  AC1: MANIFEST.md line flipped to shipped" \
  "ok  AC1: working tree is clean" \
  "ok  AC1: exactly one new commit reached origin" \
  "ok  AC1: origin's new commit is titled archive: clean1 shipped" \
  "ok  AC1: the archive commit contains all three changes"
