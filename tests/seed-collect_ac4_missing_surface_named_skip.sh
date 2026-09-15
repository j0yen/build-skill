#!/usr/bin/env bash
# seed-collect_ac4_missing_surface_named_skip.sh — PRD-prd-seed-inbox AC4:
# Given a surface directory that does not exist on this host, When
# collect runs, Then it prints a named skip and exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seed-collect-ac-common.sh"
seed_fixture_setup
trap seed_fixture_teardown EXIT
# Neither surface exists: the journal dir is deleted here, and
# SEED_SYNTHORG_DIRS (from seed_fixture_setup) already points at a path
# that was never created.
rm -rf "$SEED_JOURNAL_DIR"

set +e
out="$("$SCRIPT" collect 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "AC4: collect exits 0 when a surface is missing"

echo "$out" | grep -qF "skip build-journal ($SEED_JOURNAL_DIR not present on this host)" \
  || fail "AC4: missing build-journal surface did not print a named skip"
ok "AC4: missing build-journal surface prints a named skip"

echo "$out" | grep -qF "skip synthorg-packs ($SEED_SYNTHORG_DIRS not present on this host)" \
  || fail "AC4: missing synthorg-packs surface did not print a named skip"
ok "AC4: missing synthorg-packs surface prints a named skip"
