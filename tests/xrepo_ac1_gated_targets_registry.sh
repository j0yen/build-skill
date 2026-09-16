#!/usr/bin/env bash
# tests/xrepo_ac1_gated_targets_registry.sh — PRD-build-cross-repo-commit-gate
# requirement 1 (P0) / AC1: gated-targets.sh's list/is-gated/--explain
# mechanics against a FIXTURE manifest (deterministic — the live corpus
# form, `is-gated /home/jsy/wintermute/mcphost` exits 0 while
# `is-gated /home/jsy/wintermute/build-skill` exits 1, was verified
# manually against the real manifest.json this session; a repeatable
# selftest needs a fixture since the live corpus changes over time).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATED_TARGETS="$HERE/../scripts/gated-targets.sh"
[ -x "$GATED_TARGETS" ] || { echo "selftest: $GATED_TARGETS not executable" >&2; exit 2; }
for bin in jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/xrepo-ac1-selftest.XXXXXX")"
trap '[ -n "${XREPO_AC1_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

GATED_REPO="$T/gated-repo"
UNGATED_REPO="$T/ungated-repo"
mkdir -p "$GATED_REPO" "$UNGATED_REPO"
GATED_RP="$(cd "$GATED_REPO" && pwd -P)"

MANIFEST="$T/manifest.json"
jq -n --arg t "$GATED_RP" \
  '{prds: {"owner-one": {build_target: "rust-extend", build_into: $t},
           "owner-two": {build_target: "rust-extend", build_into: $t},
           "not-rust-extend": {build_target: "shell", build_into: $t},
           "no-build-into": {build_target: "rust-extend", build_into: null}},
    built_at: "2026-09-16T00:00:00Z"}' > "$MANIFEST"

export BUILD_MANIFEST="$MANIFEST"
export BUILD_STATE_DIR="$T/state"
export BUILD_JOURNAL_ROOT="$T/journal"

echo "=== AC1: list/is-gated/--explain ==="
list_out="$("$GATED_TARGETS" list)"
expect "list: gated repo appears exactly once" \
  "[ \"\$(printf '%s\n' \"\$list_out\" | grep -c \"^\$GATED_RP\$\")\" -eq 1 ]"
expect "list: ungated repo does not appear" \
  "! printf '%s\n' \"\$list_out\" | grep -qF \"\$(cd \"$UNGATED_REPO\" && pwd -P)\""

"$GATED_TARGETS" is-gated "$GATED_REPO" >/dev/null 2>&1
expect "is-gated: gated repo exits 0" "[ \$? -eq 0 ]"
"$GATED_TARGETS" is-gated "$UNGATED_REPO" >/dev/null 2>&1
rc_ungated=$?
expect "is-gated: ungated repo exits 1" "[ $rc_ungated -eq 1 ]"
"$GATED_TARGETS" is-gated "$T/does-not-exist-at-all" >/dev/null 2>&1
rc_missing=$?
expect "is-gated: a path that doesn't exist locally never crashes (exit 1, not a nonzero-2 error)" "[ $rc_missing -eq 1 ]"

explain_out="$("$GATED_TARGETS" list --explain | grep -F "$GATED_RP")"
expect "--explain: names both owning slugs for the gated repo" \
  "printf '%s' \"\$explain_out\" | grep -q 'owner-one' && printf '%s' \"\$explain_out\" | grep -q 'owner-two'"
expect "--explain: does not name the non-rust-extend slug" \
  "! printf '%s' \"\$explain_out\" | grep -q 'not-rust-extend'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac1: ALL PASS"
else
  echo "xrepo_ac1: assertion(s) FAILED"
fi
exit "$fail"
