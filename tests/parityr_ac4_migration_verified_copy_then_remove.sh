#!/usr/bin/env bash
# parityr_ac4_migration_verified_copy_then_remove.sh —
# PRD-build-burst-parity-robust AC4.
#
# Given a live root-only session with an old-root worktree copy, When
# `provision` migrates, Then the old directory is removed after a
# size-and-count match and `provision  migrated-removed` is journaled;
# given a copy mismatch, Then the old directory is kept and
# `provision  migrate-keep  (cause=copy-mismatch)` is journaled. Also
# covers the Requirements section's "reap covers both roots" backstop
# (not one of the six numbered ACs, but the same requirement 4).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  parityr AC4: old-root copy verified (bytes+count match) and removed after migration" \
  "ok  parityr AC4: journal records migrated-removed naming the old path" \
  "ok  parityr AC4: a copy mismatch keeps the old directory" \
  "ok  parityr AC4: journal records migrate-keep(cause=copy-mismatch) naming the old path" \
  "ok  parityr: reap removes the old-root leftover" \
  "ok  parityr: reap journals the old-root removal tagged with its root" \
  "ok  parityr: reap's own summary counts the old-root dir too"
