#!/usr/bin/env bash
# mainpush_ac14_project_root_cross_repo_gate.sh — PRD-build-main-push-gate-
# nested-project-root AC5 (P1): given the gated-repo (cross-repo-gate)
# branch-verdict check path (PRD-build-cross-repo-commit-gate requirement
# 3), when --project-root is passed, it resolves <repo>/<rel>/target/
# autobuilder/last-verdict.json for that check too, not just the primary
# --gated default. Modeled on tests/xrepo_ac4_main_push_gate_gated_repo.sh
# (the existing cross-repo-gate fixture), but with a nested crate root so
# only the nested verdict location proves the check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
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

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac14.XXXXXX")"
trap '[ -n "${MAINPUSH_AC14_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/gated-nested-repo"
mkdir -p "$REPO/autobuilder"
git -C "$REPO" init -q -b main
printf 'nested crate root\n' > "$REPO/autobuilder/Cargo.toml"
printf 'seed\n' > "$REPO/f.txt"
git -C "$REPO" -c user.name=t -c user.email=t@e.com add -A
git -C "$REPO" -c user.name=t -c user.email=t@e.com commit -q -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
REPO_RP="$(cd "$REPO" && pwd -P)"

MANIFEST="$T/manifest.json"
jq -n --arg t "$REPO_RP" '{prds: {"owner-one": {build_target: "rust-extend", build_into: $t}}, built_at: "x"}' > "$MANIFEST"

export BUILD_MANIFEST="$MANIFEST"
export BUILD_JOURNAL_ROOT="$T/journalroot"

echo "=== a fresh nested verdict, reached only via --project-root, lets the push proceed ==="
mkdir -p "$REPO/autobuilder/target/autobuilder"
jq -n --arg h "$HEAD_SHA" '{head: $h, verdict: "delta-pass"}' \
  > "$REPO/autobuilder/target/autobuilder/last-verdict.json"
out1="$T/out1"
"$MAIN_PUSH_GATE" "$REPO" --project-root autobuilder --writer-slug writer-x >"$out1" 2>&1
rc1=$?
expect "AC14: --project-root resolves the nested verdict, exits 0" "[ $rc1 -eq 0 ]"
expect "AC14: no cross-repo-gate refused line" "! grep -q 'cross-repo-gate  refused' \"$out1\""

echo "=== the SAME repo, called WITHOUT --project-root, cannot see the nested verdict -> refused ==="
out2="$T/out2"
"$MAIN_PUSH_GATE" "$REPO" --writer-slug writer-x >"$out2" 2>&1
rc2=$?
expect "AC14: unflagged call still refuses (nested verdict invisible from repo root)" "[ $rc2 -eq 1 ]"
expect "AC14: unflagged call names cross-repo-gate refused" "grep -q 'cross-repo-gate refused' \"$out2\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpush_ac14: ALL PASS"
else
  echo "mainpush_ac14: assertion(s) FAILED"
fi
exit "$fail"
