#!/usr/bin/env bash
# crate_dir_ac3_undeclared_keeps_depth1_and_warns.sh —
# PRD-build-contract-declared-crate-dir AC3.
#
# Given a rust-extend PRD without crate_dir on the same fixture repo, When
# scripts/prd-lint.sh runs, Then it fails build-into-substrate-mismatch with
# today's message; after a ledger-read/Cargo.toml is added it passes with one
# crate-dir-undeclared warning.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixtures/crate-dir-common.sh"

f="$CD_Q/PRD-cd3-undeclared.md"
cd_prd "$f" rust-extend "$CD_PY" -

cd_lint "$f"
want="build_target 'rust-extend' requires a Cargo.toml at or under build_into '$CD_PY'; none found (pyproject.toml present: True)"
cd_expect "AC3 no key: exit 1" "[ $cd_rc -eq 1 ]"
cd_expect "AC3 no key: fails build-into-substrate-mismatch" "cd_ids \"\$cd_out\" failures | grep -qx build-into-substrate-mismatch"
cd_expect "AC3 no key: today's message, byte for byte" "[ \"\$(cd_msgs \"\$cd_out\" failures build-into-substrate-mismatch)\" = \"\$want\" ]"
cd_expect "AC3 no key: no crate-dir-* finding" "! printf '%s' \"\$cd_out\" | grep -q 'crate-dir-'"

mkdir -p "$CD_PY/ledger-read"
printf '[package]\nname = "ledger-read"\nversion = "0.1.0"\n' > "$CD_PY/ledger-read/Cargo.toml"
cd_lint "$f"
cd_expect "AC3 crate landed: exit 0" "[ $cd_rc -eq 0 ]"
cd_expect "AC3 crate landed: no failures" "[ -z \"\$(cd_ids \"\$cd_out\" failures)\" ]"
cd_expect "AC3 crate landed: exactly one warning, crate-dir-undeclared" "[ \"\$(cd_ids \"\$cd_out\" warnings)\" = crate-dir-undeclared ]"
cd_expect "AC3 crate landed: the warning names the crate directory" "cd_msgs \"\$cd_out\" warnings crate-dir-undeclared | grep -q 'ledger-read'"

exit $cd_fail
