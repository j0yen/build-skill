#!/usr/bin/env bash
# landres_ac2_classify_generated.sh —
# PRD-build-land-conflict-resolver AC2 (classifier slice): given a policy
# listing a path as generated with a regen command, When land-resolve.sh
# classify runs on that path, Then it returns class=generated and the
# regen command with {slug} substituted. Also covers a glob entry
# (tests/suite_*.rs) matching a concrete file. Regen EXECUTION and the
# dedup-on-second-land behavior are a later step; this test covers only
# the classifier's read of R2's policy shape.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH (required by land-resolve.sh)" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy" "$WORK/repo-fixture"

cat >"$BUILD_STATE_DIR/land-policy/repo-fixture.json" <<'EOF'
{
  "generated": [
    {"path": "agent/intent-card.json", "regen": "scripts/intent-card-refresh.sh {slug}"},
    {"path": "tests/suite_*.rs", "regen": "scripts/gen-test-suites.sh"}
  ],
  "append_only": ["CHANGELOG.md"]
}
EOF

fail=0

out="$("$RESOLVE" classify "$WORK/repo-fixture" "agent/intent-card.json" "my-slug")"
if [ "$out" = "class=generated regen=scripts/intent-card-refresh.sh my-slug" ]; then
  echo "ok  AC2: exact-path generated entry classifies with {slug} substituted"
else
  echo "FAIL: expected substituted regen command, got '$out'" >&2
  fail=1
fi

out2="$("$RESOLVE" classify "$WORK/repo-fixture" "tests/suite_foo.rs")"
if [ "$out2" = "class=generated regen=scripts/gen-test-suites.sh" ]; then
  echo "ok  AC2: glob generated entry (tests/suite_*.rs) matches a concrete file"
else
  echo "FAIL: expected glob match, got '$out2'" >&2
  fail=1
fi

out3="$("$RESOLVE" classify "$WORK/repo-fixture" "src/lib.rs")"
if [ "$out3" = "class=source" ]; then
  echo "ok  AC2: an unlisted path under a real policy still falls to class=source"
else
  echo "FAIL: expected class=source, got '$out3'" >&2
  fail=1
fi

exit $fail
