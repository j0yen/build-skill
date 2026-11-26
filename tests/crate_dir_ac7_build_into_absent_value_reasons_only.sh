#!/usr/bin/env bash
# crate_dir_ac7_build_into_absent_value_reasons_only.sh —
# PRD-build-contract-declared-crate-dir AC7 (host gate, owner correction F1).
#
# Given a fixture rust-extend PRD with `crate_dir: ledger-read` whose
# build_into does not exist on the lint host, When scripts/prd-lint.sh runs,
# Then it reports the build-into-not-found warning, no crate-dir-invalid and no
# build-into-substrate-mismatch, and exits 0; the same PRD with `crate_dir: a/b`
# fails crate-dir-invalid.
#
# The pair separates three wrong readings: an ungated substrate test (a
# missing path read as "no pyproject.toml") fails the first half; gating the
# value reason behind existence too fails the second half; dropping the
# warning for crate_dir PRDs fails the first half's warning check.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixtures/crate-dir-common.sh"

absent="$CD_ROOT/not-on-this-host/swarm-decide"
f="$CD_Q/PRD-cd7-absent.md"

cd_prd "$f" rust-extend "$absent" ledger-read
cd_lint "$f"
cd_expect "AC7 valid value, absent build_into: exit 0" "[ $cd_rc -eq 0 ]"
cd_expect "AC7 valid value: the build-into-not-found warning stands alone" "[ \"\$(cd_ids \"\$cd_out\" warnings)\" = build-into-not-found ]"
cd_expect "AC7 valid value: no crate-dir-invalid" "! cd_ids \"\$cd_out\" failures | grep -qx crate-dir-invalid"
cd_expect "AC7 valid value: no build-into-substrate-mismatch" "! cd_ids \"\$cd_out\" failures | grep -qx build-into-substrate-mismatch"

cd_prd "$f" rust-extend "$absent" a/b
cd_lint "$f"
cd_expect "AC7 a/b, absent build_into: exit 1" "[ $cd_rc -eq 1 ]"
cd_expect "AC7 a/b: fails crate-dir-invalid on every host" "cd_ids \"\$cd_out\" failures | grep -qx crate-dir-invalid"
cd_expect "AC7 a/b: the failure is the value reason, not a substrate one" \
  "cd_msgs \"\$cd_out\" failures crate-dir-invalid | grep -q \"contains '/'\" && ! cd_msgs \"\$cd_out\" failures crate-dir-invalid | grep -qE 'pyproject|Cargo'"
cd_expect "AC7 a/b: the build-into-not-found warning is still reported" "cd_ids \"\$cd_out\" warnings | grep -qx build-into-not-found"

exit $cd_fail
