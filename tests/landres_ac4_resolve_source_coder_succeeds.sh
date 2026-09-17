#!/usr/bin/env bash
# landres_ac4_resolve_source_coder_succeeds.sh —
# PRD-build-land-conflict-resolver AC4 (R4, success slice): given a
# source-file conflict (no policy entry) mid-rebase and a stub coder
# ($LAND_RESOLVE_CODER) that resolves the markers so the repo's own test
# command then passes, When `land-resolve.sh resolve` runs, Then it
# stages the file, continues the rebase, reports `resolved=all`, exit 0,
# and the ledger records one `source`/`coder` line with a numeric
# wall_seconds. The "tests pass" check is real here — $LAND_RESOLVE_TEST_CMD
# runs an actual script that fails until the stub coder's edit lands, so
# this also proves R4 trusts the test command, not the coder's own exit
# code, for the verdict.
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

printf 'fn main() {}\n' >"$REPO/src.rs"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base

git -C "$REPO" checkout -q -b autobuilder/fix1
printf 'fn main() { branch_change(); }\n' >"$REPO/src.rs"
git -C "$REPO" commit -q -am "branch source change"

git -C "$REPO" checkout -q main
printf 'fn main() { main_change(); }\n' >"$REPO/src.rs"
git -C "$REPO" commit -q -am "main source change"

git -C "$REPO" checkout -q autobuilder/fix1

# No policy file -> src.rs classifies `source`.
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"

git -C "$REPO" rebase main >/dev/null 2>&1 || true

# Stub coder: replaces the conflicted file with a merged, marker-free
# resolution. Takes <repo> <slug> <file...>.
cat >"$WORK/stub-coder.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
repo="$1"; shift; shift  # repo, slug
for f in "$@"; do
  printf 'fn main() { main_change(); branch_change(); }\n' > "$repo/$f"
done
exit 0
EOF
chmod +x "$WORK/stub-coder.sh"

# Test command: passes only once the merged marker (both calls present)
# is in place — proves R4 checks tests, not just the coder's own exit 0.
cat >"$WORK/check.sh" <<EOF
#!/usr/bin/env bash
grep -q 'main_change().*branch_change()' "$REPO/src.rs"
EOF
chmod +x "$WORK/check.sh"

export LAND_RESOLVE_CODER="$WORK/stub-coder.sh"
export LAND_RESOLVE_TEST_CMD="$WORK/check.sh"
export LAND_RESOLVE_MAX_S=30
export LAND_CONFLICTS_LEDGER="$WORK/state/land-conflicts.jsonl"

fail=0
out="$("$RESOLVE" resolve "$REPO" fix1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "resolved=all" ]; then
  echo "ok  AC4: land-resolve resolve reports resolved=all after coder success"
else
  echo "FAIL: expected rc=0/resolved=all, got rc=$rc out='$out'" >&2
  fail=1
fi

if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  echo "ok  AC4: rebase completed, working tree clean"
else
  echo "FAIL: working tree not clean after resolve: $(git -C "$REPO" status --porcelain)" >&2
  fail=1
fi

content="$(cat "$REPO/src.rs" 2>/dev/null)"
if [ "$content" = "fn main() { main_change(); branch_change(); }" ]; then
  echo "ok  AC4: landed src.rs equals the stub coder's merged resolution"
else
  echo "FAIL: expected coder's resolution, got '$content'" >&2
  fail=1
fi

if [ -f "$LAND_CONFLICTS_LEDGER" ]; then
  rec="$(jq -c 'select(.file == "src.rs" and .class == "source" and .resolution == "coder")' "$LAND_CONFLICTS_LEDGER")"
  wall="$(printf '%s' "$rec" | jq -r '.wall_seconds // "missing"' 2>/dev/null)"
  if [ -n "$rec" ] && [ "$wall" != "missing" ] && [ "$wall" -ge 0 ] 2>/dev/null; then
    echo "ok  AC4: ledger records source/coder with numeric wall_seconds ($wall)"
  else
    echo "FAIL: ledger record missing or malformed: '$rec'" >&2
    fail=1
  fi
else
  echo "FAIL: ledger file not written at $LAND_CONFLICTS_LEDGER" >&2
  fail=1
fi

exit $fail
