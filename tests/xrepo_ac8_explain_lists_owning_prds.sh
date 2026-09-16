#!/usr/bin/env bash
# tests/xrepo_ac8_explain_lists_owning_prds.sh — PRD-build-cross-repo-
# commit-gate requirement 7 (P2) / AC8: "Given gated-targets.sh --explain,
# When run, Then each path lists the PRD slugs that gate it." A dedicated
# AC8 file (rather than folding this into xrepo_ac1's coverage) so
# verified-completed.sh's AC-to-test derive pairs AC8 unambiguously
# against this PRD's own test_prefix (xrepo) instead of falling back to a
# bare "ac8" match against an unrelated PRD's test file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATED_TARGETS="$HERE/../scripts/gated-targets.sh"
[ -x "$GATED_TARGETS" ] || { echo "selftest: $GATED_TARGETS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/xrepo-ac8-selftest.XXXXXX")"
trap '[ -n "${XREPO_AC8_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO_A="$T/gated-a"
REPO_B="$T/gated-b"
mkdir -p "$REPO_A" "$REPO_B"
RP_A="$(cd "$REPO_A" && pwd -P)"
RP_B="$(cd "$REPO_B" && pwd -P)"

MANIFEST="$T/manifest.json"
jq -n --arg a "$RP_A" --arg b "$RP_B" \
  '{prds: {"prd-alpha": {build_target: "rust-extend", build_into: $a},
           "prd-beta":  {build_target: "rust-extend", build_into: $a},
           "prd-gamma": {build_target: "rust-extend", build_into: $b}},
    built_at: "x"}' > "$MANIFEST"

export BUILD_MANIFEST="$MANIFEST"
export BUILD_STATE_DIR="$T/state"
export BUILD_JOURNAL_ROOT="$T/journal"

echo "=== AC8: --explain names the owning PRD slugs per gated path ==="
explain_out="$("$GATED_TARGETS" list --explain)"

line_a="$(printf '%s\n' "$explain_out" | grep -F "$RP_A")"
line_b="$(printf '%s\n' "$explain_out" | grep -F "$RP_B")"

expect "repo A's line names prd-alpha" "printf '%s' \"\$line_a\" | grep -q prd-alpha"
expect "repo A's line names prd-beta" "printf '%s' \"\$line_a\" | grep -q prd-beta"
expect "repo A's line does NOT name prd-gamma" "! printf '%s' \"\$line_a\" | grep -q prd-gamma"
expect "repo B's line names prd-gamma" "printf '%s' \"\$line_b\" | grep -q prd-gamma"
expect "repo B's line does NOT name prd-alpha" "! printf '%s' \"\$line_b\" | grep -q prd-alpha"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac8: ALL PASS"
else
  echo "xrepo_ac8: assertion(s) FAILED"
fi
exit "$fail"
