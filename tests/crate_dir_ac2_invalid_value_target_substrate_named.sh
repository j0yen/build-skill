#!/usr/bin/env bash
# crate_dir_ac2_invalid_value_target_substrate_named.sh —
# PRD-build-contract-declared-crate-dir AC2.
#
# Given crate_dir set to a/b, to .., on a python-cli PRD, and on an existing
# fixture repo with no root pyproject.toml, When scripts/prd-lint.sh runs on
# each, Then each fails crate-dir-invalid with a message naming that reason,
# and `scripts/prd-lint.sh --explain crate-dir-invalid` exits 0 and prints the
# rule.
. "$(dirname "$0")/fixtures/crate-dir-common.sh"

# check <label> <file> <message regex naming the reason>
check() {
  local label="$1" f="$2" re="$3"
  cd_lint "$f"
  cd_expect "AC2 $label: exit 1" "[ $cd_rc -eq 1 ]"
  cd_expect "AC2 $label: fails crate-dir-invalid" "cd_ids \"\$cd_out\" failures | grep -qx crate-dir-invalid"
  cd_expect "AC2 $label: message names the reason" "cd_msgs \"\$cd_out\" failures crate-dir-invalid | grep -qE \"\$re\""
  cd_expect "AC2 $label: never build-into-substrate-mismatch" "! cd_ids \"\$cd_out\" failures | grep -qx build-into-substrate-mismatch"
}

# value reasons, on a valid Python fixture repo so only the value is wrong
cd_prd "$CD_Q/PRD-cd2-slash.md" rust-extend "$CD_PY" a/b
check "a/b" "$CD_Q/PRD-cd2-slash.md" "crate_dir 'a/b' .*contains '/'"
cd_prd "$CD_Q/PRD-cd2-dotdot.md" rust-extend "$CD_PY" ..
check ".." "$CD_Q/PRD-cd2-dotdot.md" "crate_dir '\.\.' .*contains '\.\.'"

# target reason: a valid value on a python-cli PRD
cd_prd "$CD_Q/PRD-cd2-python.md" python-cli "$CD_PY" ledger-read
check "python-cli" "$CD_Q/PRD-cd2-python.md" "build_target 'python-cli'.*rust-extend"

# substrate reason: an existing fixture repo with no root pyproject.toml
mkdir -p "$CD_ROOT/plain"
echo "no manifests here" > "$CD_ROOT/plain/README.md"
cd_prd "$CD_Q/PRD-cd2-nopy.md" rust-extend "$CD_ROOT/plain" ledger-read
check "no root pyproject.toml" "$CD_Q/PRD-cd2-nopy.md" "has no root pyproject\.toml"

out="$("$CD_LINT" --explain crate-dir-invalid 2>&1)"; rc=$?
cd_expect "AC2 --explain crate-dir-invalid exits 0" "[ $rc -eq 0 ]"
cd_expect "AC2 --explain prints the rule (id, pattern, host gate)" \
  "grep -q '^crate-dir-invalid' <<<\"\$out\" && grep -qF '^[a-z0-9][a-z0-9-]{0,62}\$' <<<\"\$out\" && grep -q 'build-into-not-found' <<<\"\$out\""

exit $cd_fail
