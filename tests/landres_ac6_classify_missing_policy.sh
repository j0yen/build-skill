#!/usr/bin/env bash
# landres_ac6_classify_missing_policy.sh —
# PRD-build-land-conflict-resolver AC6 (classifier slice): given no policy
# file for a repo, When land-resolve.sh classify runs on any path, Then it
# returns class=source — the safe default that reproduces today's
# behavior (every conflict is fatal, no regen or union attempted). Full
# AC6 (the rebase-conflict path itself) lands in a later step of this
# PRD; this test covers the classifier's own fail-open contract.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR"
# Deliberately no state/land-policy/no-such-repo.json.

fail=0

out="$("$RESOLVE" classify "$WORK/no-such-repo" "agent/intent-card.json")"
if [ "$out" = "class=source" ]; then
  echo "ok  AC6: missing policy -> class=source for a would-be-generated path"
else
  echo "FAIL: expected 'class=source', got '$out'" >&2
  fail=1
fi

out2="$("$RESOLVE" classify "$WORK/no-such-repo" "CHANGELOG.md")"
if [ "$out2" = "class=source" ]; then
  echo "ok  AC6: missing policy -> class=source for a would-be-append-only path"
else
  echo "FAIL: expected 'class=source', got '$out2'" >&2
  fail=1
fi

exit $fail
