#!/usr/bin/env bash
# landres_ac3_classify_append_only.sh —
# PRD-build-land-conflict-resolver AC3 (classifier slice): given a policy
# listing a path as append-only, When land-resolve.sh classify runs on
# that path, Then it returns class=append_only. The union-merge itself
# (R3) is a later step; this test covers only the classifier's read of
# R2's append_only list, plus mcphost's actual shipped policy file
# (state/land-policy/mcphost.json, R2's named initial content) so a
# regression in that file's shape is caught here too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH (required by land-resolve.sh)" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"

cat >"$BUILD_STATE_DIR/land-policy/repo-fixture.json" <<'EOF'
{
  "generated": [],
  "append_only": ["CHANGELOG.md", "docs/*.md"]
}
EOF

fail=0

out="$("$RESOLVE" classify "$WORK/repo-fixture" "CHANGELOG.md")"
if [ "$out" = "class=append_only" ]; then
  echo "ok  AC3: exact-path append_only entry classifies correctly"
else
  echo "FAIL: expected class=append_only, got '$out'" >&2
  fail=1
fi

out2="$("$RESOLVE" classify "$WORK/repo-fixture" "docs/readme.md")"
if [ "$out2" = "class=append_only" ]; then
  echo "ok  AC3: glob append_only entry (docs/*.md) matches a concrete file"
else
  echo "FAIL: expected class=append_only, got '$out2'" >&2
  fail=1
fi

# R2's own named initial content for mcphost, read from the real policy
# path this PRD ships (not BUILD_STATE_DIR — the skill's actual state/).
SKILL_STATE_DIR="$HERE/../state"
mcphost_policy="$SKILL_STATE_DIR/land-policy/mcphost.json"
if [ -f "$mcphost_policy" ]; then
  out3="$(BUILD_STATE_DIR="$SKILL_STATE_DIR" "$RESOLVE" classify "/wherever/mcphost" "www/llms.txt")"
  if [ "$out3" = "class=append_only" ]; then
    echo "ok  AC3: mcphost's shipped policy classifies www/llms.txt as append_only"
  else
    echo "FAIL: expected class=append_only for mcphost's www/llms.txt, got '$out3'" >&2
    fail=1
  fi
  out4="$(BUILD_STATE_DIR="$SKILL_STATE_DIR" "$RESOLVE" classify "/wherever/mcphost" "agent/intent-card.json")"
  if [ "$out4" = "class=generated regen=scripts/intent-card-refresh.sh . PRD-.md" ]; then
    echo "ok  AC3: mcphost's shipped policy classifies agent/intent-card.json as generated"
  else
    echo "FAIL: expected generated classification for mcphost's intent-card.json, got '$out4'" >&2
    fail=1
  fi
else
  echo "FAIL: mcphost's policy file is missing at $mcphost_policy" >&2
  fail=1
fi

exit $fail
