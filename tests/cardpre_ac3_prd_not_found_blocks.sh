#!/usr/bin/env bash
# tests/cardpre_ac3_prd_not_found_blocks.sh — PRD-build-intent-card-
# pregate-refresh AC3: "Given intent-card-refresh.sh --prd <path> with a
# path that does not exist, When called, Then it exits non-zero with
# prd-not-found and extend-gate blocks with intent-card-stale
# (cause=prd-not-found) and reviewer-agent does not run."
#
# Two halves: the script-level contract (fast, no gate pipeline) and the
# extend-gate.sh wiring (shared "missing" fixture run — no PRD resolvable
# for the claimed slug at all, neither manifest nor build-queue/).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/cardpre-common.sh
source "$HERE/fixtures/cardpre-common.sh"

echo "=== AC3a: intent-card-refresh.sh --prd <missing> exits non-zero with prd-not-found ==="
scratch_repo="$(mktemp -d "${TMPDIR:-/tmp}/cardpre-ac3-repo.XXXXXX")"
trap 'rm -rf "$scratch_repo"' EXIT
err="$("$CARDPRE_INTENT_CARD_REFRESH" "$scratch_repo" --prd "$scratch_repo/does-not-exist.md" 2>&1 1>/dev/null)"
rc=$?
expect "exit code is non-zero" "[ $rc -ne 0 ]"
expect "stderr names prd-not-found" "case \"$err\" in *prd-not-found*) true ;; *) false ;; esac"

echo "=== AC3b: extend-gate.sh blocks intent-card-stale (cause=prd-not-found), reviewer skipped ==="
DIR="$(cardpre_ensure_shared_run missing)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC1" ] || { echo "selftest: shared missing run never completed" >&2; exit 2; }

expect "extend-gate.sh block note names intent-card-stale (cause=prd-not-found)" \
  "grep -q 'intent-card-stale (cause=prd-not-found)' \"$DIR/out1.log\""
expect "reviewer-agent was skipped (no reviewer-skipped-suppression, no fresh reviewer receipt written this run)" \
  "! grep -q 'reviewer-agent — decision=' \"$DIR/out1.log\""
wt="$(cat "$DIR/WORKTREE")"
target="$(readlink -f "$wt/target" 2>/dev/null || true)"
if [ -f "$target/autobuilder/receipts/reviewer-agent.json" ]; then
  echo "FAIL reviewer-agent.json unexpectedly present for a card-stale run" >&2
  cardpre_fail=1
else
  echo "ok  no reviewer-agent.json receipt was written (reviewer-agent never ran)"
fi

echo "-----"
if [ "$cardpre_fail" -eq 0 ]; then echo "cardpre_ac3: ALL PASS"; else echo "cardpre_ac3: assertion(s) FAILED"; fi
exit "$cardpre_fail"
