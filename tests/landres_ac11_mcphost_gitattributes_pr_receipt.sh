#!/usr/bin/env bash
# landres_ac11_mcphost_gitattributes_pr_receipt.sh —
# PRD-build-land-conflict-resolver AC11 (P1): "Given mcphost's
# .gitattributes, When read after this PRD's mcphost PR merges, Then the
# append-only paths carry merge=union and the PR is cited in receipts."
#
# Unlike the other landres_ac*.sh tests, R6/AC11 is not a general
# mechanism to fixture-test -- it is a one-time real landing into a real
# repo (mcphost), proven through the actual `loop: build-land-conflict-
# resolver` PR (j0yen/mcphost#9, squash-merged 6cc49c4) rather than
# through land-resolve.sh's own conflict-resolution path. This test
# checks the two halves of the AC directly against real evidence:
#   (a) mcphost's real origin/main .gitattributes carries `merge=union`
#       for every append_only path this repo's own
#       state/land-policy/mcphost.json declares -- so a future edit to
#       either file (mcphost's attributes, or the policy) that lets them
#       drift back out of sync fails this test, not just this PR.
#   (b) a receipt under $HOME/brain/journal/build/receipts names the PR
#       (j0yen/mcphost, a pull URL) with exit 0 -- "the PR is cited in
#       receipts".
# Requires network + a local mcphost clone (this fleet's standing
# convention, same assumption branch-protection.sh's resolve_repo_dir
# already makes); skips with a clear message rather than a false FAIL
# when neither is available; a MISSING mcphost clone during this repo's
# own selftest run is a strong finding, so the AC5-style "ok"/"FAIL"
# convention only applies once the precondition is met.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
POLICY="$SKILL_DIR/state/land-policy/mcphost.json"
MCPHOST="${MCPHOST_REPO_DIR:-$HOME/wintermute/mcphost}"
RECEIPTS_DIR="${VC_RECEIPTS_DIR:-$HOME/brain/journal/build/receipts}"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }
[ -f "$POLICY" ] || { echo "FAIL: $POLICY missing" >&2; exit 2; }

if ! git -C "$MCPHOST" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIP: AC11: no local mcphost clone at $MCPHOST (fleet-convention precondition unmet, not a mechanism failure)"
  exit 0
fi

fail=0

# --- (a) real .gitattributes carries merge=union for every append_only path --
git -C "$MCPHOST" fetch origin main -q 2>/dev/null || true
attrs="$(git -C "$MCPHOST" show origin/main:.gitattributes 2>/dev/null)"
if [ -z "$attrs" ]; then
  echo "FAIL: AC11: could not read origin/main:.gitattributes from $MCPHOST" >&2
  fail=1
else
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if grep -qF "$path merge=union" <<<"$attrs"; then
      echo "ok  AC11: mcphost .gitattributes has '$path merge=union'"
    else
      echo "FAIL: AC11: mcphost .gitattributes missing '$path merge=union' (policy declares it append_only)" >&2
      fail=1
    fi
  done < <(jq -r '.append_only[]' "$POLICY")
fi

# --- (b) a receipt cites the PR ------------------------------------------
if [ -d "$RECEIPTS_DIR" ] && grep -rlqE 'j0yen/mcphost/pull/[0-9]+' "$RECEIPTS_DIR"/*-build-land-conflict-resolver-*.txt 2>/dev/null; then
  hit="$(grep -lE 'j0yen/mcphost/pull/[0-9]+' "$RECEIPTS_DIR"/*-build-land-conflict-resolver-*.txt 2>/dev/null | head -1)"
  if grep -q '^exit: 0$' "$hit" 2>/dev/null; then
    echo "ok  AC11: receipt $hit cites the mcphost PR with exit 0"
  else
    echo "FAIL: AC11: receipt $hit cites the PR but did not exit 0" >&2
    fail=1
  fi
else
  echo "FAIL: AC11: no receipt under $RECEIPTS_DIR cites a j0yen/mcphost pull URL" >&2
  fail=1
fi

exit $fail
