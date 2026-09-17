#!/usr/bin/env bash
# landres_ac5_resolve_source_coder_fails_unresolved.sh —
# PRD-build-land-conflict-resolver AC5 (R4, failure slice): given a
# source-file conflict mid-rebase and a stub coder ($LAND_RESOLVE_CODER)
# that gives up (exits non-zero), When `land-resolve.sh resolve` runs,
# Then it does NOT continue the rebase, reports `source_conflicts=<file>
# coder=unresolved` (the marker that distinguishes "R4 tried and failed"
# from AC6's "no coder configured at all"), exits 1, the rebase state is
# left exactly as before the attempt (byte-identical — "branch restored
# to its pre-resolve state"), and the ledger records `source`/`unresolved`
# with a numeric wall_seconds. A second scenario in the same file covers
# the LAND_RESOLVE_MAX_S timeout path (a coder that hangs past the bound
# is treated identically to one that exits non-zero).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

fail=0

run_scenario() {  # $1=label $2=stub-coder-script $3=extra-max-s(optional)
  local label="$1" stub="$2" max_s="${3:-30}"
  local WORK REPO
  WORK="$(mktemp -d)"
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

  export BUILD_STATE_DIR="$WORK/state"
  mkdir -p "$BUILD_STATE_DIR/land-policy"
  export LAND_CONFLICTS_LEDGER="$WORK/state/land-conflicts.jsonl"

  git -C "$REPO" rebase main >/dev/null 2>&1 || true
  local before_status; before_status="$(git -C "$REPO" status --porcelain)"
  local before_content; before_content="$(cat "$REPO/src.rs")"

  export LAND_RESOLVE_CODER="$stub"
  export LAND_RESOLVE_MAX_S="$max_s"

  local out rc
  out="$("$RESOLVE" resolve "$REPO" fix1)"; rc=$?
  if [ "$rc" -eq 1 ] && [ "$out" = "source_conflicts=src.rs coder=unresolved" ]; then
    echo "ok  AC5 ($label): resolve reports source_conflicts=src.rs coder=unresolved, exit 1"
  else
    echo "FAIL ($label): expected rc=1/'source_conflicts=src.rs coder=unresolved', got rc=$rc out='$out'" >&2
    fail=1
  fi

  local after_status; after_status="$(git -C "$REPO" status --porcelain)"
  local after_content; after_content="$(cat "$REPO/src.rs")"
  if [ "$after_status" = "$before_status" ] && [ "$after_content" = "$before_content" ]; then
    echo "ok  AC5 ($label): branch left byte-identical to its pre-resolve state"
  else
    echo "FAIL ($label): tree changed — before='$before_content'/'$before_status' after='$after_content'/'$after_status'" >&2
    fail=1
  fi

  local gitdir; gitdir="$(git -C "$REPO" rev-parse --absolute-git-dir)"
  if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
    echo "ok  AC5 ($label): rebase state directory still present — not continued or aborted by us"
  else
    echo "FAIL ($label): rebase state directory is gone" >&2
    fail=1
  fi

  if [ -f "$LAND_CONFLICTS_LEDGER" ]; then
    local rec wall
    rec="$(jq -c 'select(.file == "src.rs" and .class == "source" and .resolution == "unresolved")' "$LAND_CONFLICTS_LEDGER")"
    wall="$(printf '%s' "$rec" | jq -r '.wall_seconds // "missing"' 2>/dev/null)"
    if [ -n "$rec" ] && [ "$wall" != "missing" ] && [ "$wall" -ge 0 ] 2>/dev/null; then
      echo "ok  AC5 ($label): ledger records source/unresolved with numeric wall_seconds ($wall)"
    else
      echo "FAIL ($label): ledger record missing or malformed: '$rec'" >&2
      fail=1
    fi
  else
    echo "FAIL ($label): ledger file not written at $LAND_CONFLICTS_LEDGER" >&2
    fail=1
  fi

  git -C "$REPO" rebase --abort 2>/dev/null || true
  rm -rf "$WORK"
}

# Scenario 1: coder exits non-zero (gives up outright).
cat >"/tmp/landres-ac5-stub-fail-$$.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "/tmp/landres-ac5-stub-fail-$$.sh"
run_scenario "coder exits non-zero" "/tmp/landres-ac5-stub-fail-$$.sh"
rm -f "/tmp/landres-ac5-stub-fail-$$.sh"

# Scenario 2: coder hangs past LAND_RESOLVE_MAX_S — treated as a failure.
cat >"/tmp/landres-ac5-stub-hang-$$.sh" <<'EOF'
#!/usr/bin/env bash
sleep 20
exit 0
EOF
chmod +x "/tmp/landres-ac5-stub-hang-$$.sh"
run_scenario "coder exceeds LAND_RESOLVE_MAX_S" "/tmp/landres-ac5-stub-hang-$$.sh" 1
rm -f "/tmp/landres-ac5-stub-hang-$$.sh"

exit $fail
