#!/usr/bin/env bash
# lintdr_ac8_key_parity_selftest_catches_unknown_key.sh —
# PRD-build-prd-lint-deferred-reasons-key AC8.
#
# Given the selftest's key-parity check, When a key is added to
# scan-prds.sh's parsed set and not to prd-lint.sh or the allowlist, Then
# the selftest fails naming the key; and When run against the shipped
# tree, Then it passes.
#
# Runs the REAL prd-lint-selftest.sh against a scratch copy of this repo's
# scripts/ dir (never the live checkout) so the negative case's injected
# key never touches the shipped scan-prds.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELFTEST_SRC="$HERE/../scripts/prd-lint-selftest.sh"
[ -x "$SELFTEST_SRC" ] || { echo "FAIL: $SELFTEST_SRC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Positive case: the shipped tree passes the key-parity check today.
out_ok="$(bash "$SELFTEST_SRC" 2>&1)"
expect "AC8: shipped tree's key-parity check passes" \
  "grep -q 'ok: key-parity' <<<\"\$out_ok\""

# Negative case: a scratch copy with an unknown key injected into
# scan-prds.sh's own wide local-declaration line fails, naming the key.
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
cp -a "$HERE/.." "$d/repo"
sed -i 's/deferred_ac_reasons publish test_prefix/deferred_ac_reasons totally_new_field publish test_prefix/' \
  "$d/repo/scripts/scan-prds.sh"
out_bad="$(bash "$d/repo/scripts/prd-lint-selftest.sh" 2>&1)"
expect "AC8: injected unknown key fails the selftest" \
  "grep -q 'SELFTEST FAILED' <<<\"\$out_bad\""
expect "AC8: failure names the injected key" \
  "grep -q 'totally_new_field' <<<\"\$out_bad\""

exit $fail
