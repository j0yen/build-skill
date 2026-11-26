#!/usr/bin/env bash
# crate_dir_ac5_scan_manifest_carries_crate_dir.sh —
# PRD-build-contract-declared-crate-dir AC5.
#
# Given the amended contract, When scripts/scan-prds.sh scans a fixture queue
# holding one PRD with crate_dir and one without, Then the manifest entries
# carry crate_dir as `ledger-read` and as an empty string, and
# scripts/prd-lint-selftest.sh reports key parity ok including crate_dir.
#
# scan-prds.sh's lint pass writes only to the scratch manifest/journal set
# below. Like scan-prds-selftest.sh, this reads the bash emission path (the
# `vellum` fast path is an external binary that is not installed here).
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixtures/crate-dir-common.sh"
SCAN="$CD_REPO/scripts/scan-prds.sh"
JQ="${JQ:-$(command -v jq)}"

cd_prd "$CD_Q/PRD-cd5-with.md" rust-extend "$CD_PY" ledger-read
cd_prd "$CD_Q/PRD-cd5-without.md" python-cli "$CD_PY" -
mkdir -p "$CD_ROOT/state"
printf '{"prds":{},"built_at":"2020-01-01T00:00:00Z"}\n' > "$CD_ROOT/state/manifest.json"

out="$(PRD_DIR="$CD_ROOT/corpus" JQ="$JQ" BUILD_STATE_DIR="$CD_ROOT/state" \
  BUILD_MANIFEST="$CD_ROOT/state/manifest.json" JOURNAL="$CD_ROOT/journal.md" \
  bash "$SCAN" 2>"$CD_ROOT/scan.err")"; rc=$?
cd_expect "AC5: scan exits 0" "[ $rc -eq 0 ]"
cd_expect "AC5: the crate_dir PRD's entry carries crate_dir \"ledger-read\"" \
  "\"\$JQ\" -e '.[] | select(.slug==\"cd5-with\") | .crate_dir == \"ledger-read\"' >/dev/null <<<\"\$out\""
cd_expect "AC5: the other entry carries crate_dir as an empty string" \
  "\"\$JQ\" -e '.[] | select(.slug==\"cd5-without\") | (.crate_dir | type) == \"string\" and .crate_dir == \"\"' >/dev/null <<<\"\$out\""
cd_expect "AC5: every entry has the crate_dir field" \
  "\"\$JQ\" -e 'length == 2 and all(.[]; has(\"crate_dir\"))' >/dev/null <<<\"\$out\""

sout="$(bash "$CD_REPO/scripts/prd-lint-selftest.sh" 2>&1)"
cd_expect "AC5: prd-lint-selftest.sh reports key parity ok including crate_dir" \
  "grep -E '^ok: key-parity ' <<<\"\$sout\" | grep -qw crate_dir"

exit $cd_fail
