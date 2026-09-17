#!/usr/bin/env bash
# landres_ac2_resolve_generated_regen.sh —
# PRD-build-land-conflict-resolver AC2 (resolve slice): given a fixture
# repo where main and a branch both regenerated a policy-listed generated
# file (real content divergence, real rebase conflict), When
# `land-resolve.sh resolve` runs mid-rebase, Then it takes main's side,
# reruns the regen command, stages the result, continues the rebase, and
# the branch lands with the file equal to the regen output — no source
# conflict recorded.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email a@b.c
git -C "$REPO" config user.name test

# regen.sh: deterministic "generator" — always writes the same canonical
# output regardless of which branch runs it, the property that makes a
# generated-file conflict spurious in the first place.
cat >"$REPO/regen.sh" <<'EOF'
#!/usr/bin/env bash
echo "generated-canonical-v1" > gen.txt
EOF
chmod +x "$REPO/regen.sh"
"$REPO/regen.sh" 2>/dev/null || true
( cd "$REPO" && ./regen.sh )
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base

git -C "$REPO" checkout -q -b autobuilder/fix1
echo "src-change" > "$REPO/src.txt"
( cd "$REPO" && ./regen.sh )
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "branch regenerated gen.txt (stale timestamp variant)"
# Force a real textual conflict: hand-edit the branch's committed gen.txt
# to differ from what regen.sh produces, simulating "two branches each
# regenerated it" landing at different times with different embedded
# state (PRD AC2's actual scenario).
echo "generated-canonical-v1-branch-variant" > "$REPO/gen.txt"
git -C "$REPO" commit -q -am "branch variant of gen.txt"

git -C "$REPO" checkout -q main
echo "generated-canonical-v1-main-variant" > "$REPO/gen.txt"
git -C "$REPO" commit -q -am "main variant of gen.txt"

git -C "$REPO" checkout -q autobuilder/fix1

# Policy: gen.txt is generated, regen = ./regen.sh.
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"
cat >"$BUILD_STATE_DIR/land-policy/repo.json" <<'EOF'
{"generated": [{"path": "gen.txt", "regen": "./regen.sh"}], "append_only": []}
EOF

git -C "$REPO" rebase main >/dev/null 2>&1 || true
conflicted_before="$(git -C "$REPO" diff --name-only --diff-filter=U)"

fail=0
if [ "$conflicted_before" = "gen.txt" ]; then
  echo "ok  AC2: fixture actually produced a real rebase conflict in gen.txt"
else
  echo "FAIL: expected a conflict in gen.txt, got '$conflicted_before'" >&2
  fail=1
fi

out="$("$RESOLVE" resolve "$REPO" fix1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "resolved=all" ]; then
  echo "ok  AC2: land-resolve resolve reports resolved=all"
else
  echo "FAIL: expected rc=0/resolved=all, got rc=$rc out='$out'" >&2
  fail=1
fi

if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  echo "ok  AC2: rebase completed, working tree clean"
else
  echo "FAIL: working tree not clean after resolve: $(git -C "$REPO" status --porcelain)" >&2
  fail=1
fi

content="$(cat "$REPO/gen.txt" 2>/dev/null)"
if [ "$content" = "generated-canonical-v1" ]; then
  echo "ok  AC2: landed gen.txt equals the regen output, not either branch's stale variant"
else
  echo "FAIL: expected regen output, got '$content'" >&2
  fail=1
fi

exit $fail
