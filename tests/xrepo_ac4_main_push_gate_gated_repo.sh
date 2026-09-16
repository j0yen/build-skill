#!/usr/bin/env bash
# tests/xrepo_ac4_main_push_gate_gated_repo.sh — PRD-build-cross-repo-
# commit-gate requirement 3 (P0) / AC4: main-push-gate.sh, when <repo> is
# a registered gated target, refuses (exit 1) a head with no fresh
# pass/delta-pass branch-gate verdict, and proceeds (exit 0) once one
# exists for the exact head being pushed. No cargo/autobuilder needed —
# this check only reads gated-targets.sh's registry and a hand-written
# target/autobuilder/last-verdict.json, so this test is fast (real git,
# no fixture crate build).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MAIN_PUSH_GATE="$HERE/../scripts/main-push-gate.sh"
[ -x "$MAIN_PUSH_GATE" ] || { echo "selftest: $MAIN_PUSH_GATE not executable" >&2; exit 2; }
for bin in git jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/xrepo-ac4-selftest.XXXXXX")"
trap '[ -n "${XREPO_AC4_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/gated-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf 'seed\n' > "$REPO/f.txt"
git -C "$REPO" -c user.name=t -c user.email=t@e.com add -A
git -C "$REPO" -c user.name=t -c user.email=t@e.com commit -q -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
mkdir -p "$REPO/target/autobuilder"
REPO_RP="$(cd "$REPO" && pwd -P)"

MANIFEST="$T/manifest.json"
jq -n --arg t "$REPO_RP" '{prds: {"owner-one": {build_target: "rust-extend", build_into: $t}}, built_at: "x"}' > "$MANIFEST"

export BUILD_MANIFEST="$MANIFEST"
export BUILD_JOURNAL_ROOT="$T/journalroot"

echo "=== AC4a: no verdict file at all -> refused ==="
rm -f "$REPO/target/autobuilder/last-verdict.json"
out1="$T/out1"
"$MAIN_PUSH_GATE" "$REPO" --writer-slug writer-x >"$out1" 2>&1
rc1=$?
expect "AC4a: exits 1" "[ $rc1 -eq 1 ]"
expect "AC4a: message names cross-repo-gate refused" "grep -q 'cross-repo-gate refused' \"$out1\""

echo "=== AC4b: verdict head mismatches current HEAD -> refused ==="
jq -n '{head: "0000000000000000000000000000000000000000", verdict: "pass"}' > "$REPO/target/autobuilder/last-verdict.json"
out2="$T/out2"
"$MAIN_PUSH_GATE" "$REPO" --writer-slug writer-x >"$out2" 2>&1
rc2=$?
expect "AC4b: exits 1" "[ $rc2 -eq 1 ]"
expect "AC4b: message names cross-repo-gate refused" "grep -q 'cross-repo-gate refused' \"$out2\""

echo "=== AC4c: verdict=block at the current HEAD -> refused ==="
jq -n --arg h "$HEAD_SHA" '{head: $h, verdict: "block", new_blocks: ["vti-plan"]}' > "$REPO/target/autobuilder/last-verdict.json"
out3="$T/out3"
"$MAIN_PUSH_GATE" "$REPO" --writer-slug writer-x >"$out3" 2>&1
rc3=$?
expect "AC4c: exits 1" "[ $rc3 -eq 1 ]"

echo "=== AC4d: verdict=pass at the current HEAD -> proceeds ==="
jq -n --arg h "$HEAD_SHA" '{head: $h, verdict: "pass"}' > "$REPO/target/autobuilder/last-verdict.json"
out4="$T/out4"
"$MAIN_PUSH_GATE" "$REPO" --writer-slug writer-x >"$out4" 2>&1
rc4=$?
expect "AC4d: exits 0" "[ $rc4 -eq 0 ]"

echo "=== AC4e: verdict=delta-pass at the current HEAD -> proceeds ==="
jq -n --arg h "$HEAD_SHA" '{head: $h, verdict: "delta-pass"}' > "$REPO/target/autobuilder/last-verdict.json"
out5="$T/out5"
"$MAIN_PUSH_GATE" "$REPO" --writer-slug writer-x >"$out5" 2>&1
rc5=$?
expect "AC4e: exits 0" "[ $rc5 -eq 0 ]"

journal_file="$T/journalroot/$(date -u +%F).md"
expect "journal: at least one cross-repo-gate refused line" "grep -q 'cross-repo-gate  refused  (writer=writer-x target=gated-repo' \"$journal_file\""
expect "journal: at least one cross-repo-gate pass line" "grep -q 'cross-repo-gate  pass  (writer=writer-x target=gated-repo' \"$journal_file\""

echo "=== AC4f: a non-gated repo is entirely unaffected (existing behavior) ==="
UNGATED="$T/ungated-repo"
mkdir -p "$UNGATED"
git -C "$UNGATED" init -q -b main
printf 'seed\n' > "$UNGATED/f.txt"
git -C "$UNGATED" -c user.name=t -c user.email=t@e.com add -A
git -C "$UNGATED" -c user.name=t -c user.email=t@e.com commit -q -m init
out6="$T/out6"
"$MAIN_PUSH_GATE" "$UNGATED" >"$out6" 2>&1
rc6=$?
expect "AC4f: a repo with no ci-equivalent.toml still gets the PRE-EXISTING unknown/5 (unaffected by this check)" "[ $rc6 -eq 5 ]"
expect "AC4f: no cross-repo-gate line for the ungated repo" "! grep -q 'target=ungated-repo' \"$journal_file\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac4: ALL PASS"
else
  echo "xrepo_ac4: assertion(s) FAILED"
fi
exit "$fail"
