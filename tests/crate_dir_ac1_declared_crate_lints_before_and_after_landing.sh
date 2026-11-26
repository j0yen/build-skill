#!/usr/bin/env bash
# crate_dir_ac1_declared_crate_lints_before_and_after_landing.sh —
# PRD-build-contract-declared-crate-dir AC1.
#
# Given a fixture rust-extend PRD with `crate_dir: ledger-read` on a fixture
# repo whose root holds only pyproject.toml, When scripts/prd-lint.sh runs
# before ledger-read/ exists and again after ledger-read/Cargo.toml is added,
# Then both runs report no build-into-substrate-mismatch and no
# crate-dir-invalid, and with ledger-read/ present but no Cargo.toml it fails
# crate-dir-invalid.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixtures/crate-dir-common.sh"

f="$CD_Q/PRD-cd1-ledger-read.md"
cd_prd "$f" rust-extend "$CD_PY" ledger-read

# 1. before the crate's first landing: ledger-read/ does not exist
cd_lint "$f"
cd_expect "AC1 before: exit 0" "[ $cd_rc -eq 0 ]"
cd_expect "AC1 before: no build-into-substrate-mismatch" "! cd_ids \"\$cd_out\" failures | grep -qx build-into-substrate-mismatch"
cd_expect "AC1 before: no crate-dir-invalid" "! cd_ids \"\$cd_out\" failures | grep -qx crate-dir-invalid"
cd_expect "AC1 before: crate_dir is a contract key (no unknown-frontmatter-key)" "! cd_ids \"\$cd_out\" warnings | grep -qx unknown-frontmatter-key"
cd_expect "AC1 before: lint is clean (OK)" "[ \"\$(\"\$CD_LINT\" \"\$f\" 2>&1)\" = OK ]"

# 2. ledger-read/ present but no Cargo.toml in it: crate-dir-invalid
mkdir -p "$CD_PY/ledger-read/src"
cd_lint "$f"
cd_expect "AC1 dir without Cargo.toml: exit 1" "[ $cd_rc -eq 1 ]"
cd_expect "AC1 dir without Cargo.toml: fails crate-dir-invalid" "cd_ids \"\$cd_out\" failures | grep -qx crate-dir-invalid"
cd_expect "AC1 dir without Cargo.toml: message names the missing Cargo.toml" "cd_msgs \"\$cd_out\" failures crate-dir-invalid | grep -q 'ledger-read.*exists but has no Cargo.toml'"
cd_expect "AC1 dir without Cargo.toml: never build-into-substrate-mismatch" "! cd_ids \"\$cd_out\" failures | grep -qx build-into-substrate-mismatch"

# 3. after the crate's first landing: ledger-read/Cargo.toml exists
printf '[package]\nname = "ledger-read"\nversion = "0.1.0"\n' > "$CD_PY/ledger-read/Cargo.toml"
cd_lint "$f"
cd_expect "AC1 after: exit 0" "[ $cd_rc -eq 0 ]"
cd_expect "AC1 after: no build-into-substrate-mismatch" "! cd_ids \"\$cd_out\" failures | grep -qx build-into-substrate-mismatch"
cd_expect "AC1 after: no crate-dir-invalid" "! cd_ids \"\$cd_out\" failures | grep -qx crate-dir-invalid"
cd_expect "AC1 after: lint is clean (OK; a declared crate never warns crate-dir-undeclared)" "[ \"\$(\"\$CD_LINT\" \"\$f\" 2>&1)\" = OK ]"

exit $cd_fail
