#!/usr/bin/env bash
# worktree-extend-gated-land-selftest.sh — PRD-build-gate-before-land
# requirement 2 (P0) / AC3, AC4, AC6: `land` and `integrate` accept
# `--gated-at <main sha> --verdict <path>` and refuse to merge unless main
# is still at that sha (exit 6 `land-stale-base`) and the verdict is
# pass/delta-pass (exit 7 `land-ungated`). Omitting `--gated-at` reproduces
# today's behavior exactly (covered by worktree-extend-default-branch-
# selftest.sh, unmodified by this PRD).
#
#   AC3 — gated_at == main's current HEAD, verdict=pass: land succeeds,
#         merges, and journals `land <slug> (gated_at=... main=...
#         lock_hold=<s>)` with lock_hold well under 30s.
#   AC4 — gated_at != main's current HEAD (a sibling landed first): land
#         exits 6 `land-stale-base (gated_at=X main=Y)`, main is UNCHANGED,
#         and the branch (worktree + commits) is left intact.
#   AC6 — verdict is `block`, or the verdict file is missing: land exits 7
#         `land-ungated (verdict=block|missing)`, main is unchanged.
#
# Real git only (no cargo/autobuilder) — fast, deterministic.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="$HERE/worktree-extend.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git jq flock; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/wtgatedland-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
GIT_ID=(-c user.email=test@wtgatedland-selftest.local -c user.name="wtgatedland-selftest")
JOURNAL="$T/journal.md"
export WORKTREE_EXTEND_JOURNAL="$JOURNAL"
trap '[ -n "${WTGATEDLAND_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

mk_repo() {
  local name="$1"
  local repo="$T/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" "${GIT_ID[@]}" add -A
  git -C "$repo" "${GIT_ID[@]}" commit -q -m init
  printf '%s\n' "$repo"
}

write_verdict() {
  local path="$1" verdict="$2"
  if [ "$verdict" = "__missing__" ]; then
    rm -f "$path"
  else
    printf '{"verdict": "%s"}\n' "$verdict" > "$path"
  fi
}

count_land_lines() { grep -c "^.*  land  " "$JOURNAL" 2>/dev/null || echo 0; }

# =========================================================================
# AC4 — stale base: main advances after gated_at was captured
# =========================================================================
echo "=== AC4: land-stale-base ==="
REPO="$(mk_repo ac4)"
GATED_AT="$(git -C "$REPO" rev-parse HEAD)"
WT="$("$WORKTREE_EXTEND" add "$REPO" ac4-slug 2>/dev/null)"
printf 'branch work\n' >> "$WT/README.md"
git -C "$WT" "${GIT_ID[@]}" add -A
git -C "$WT" "${GIT_ID[@]}" commit -q -m "branch work"

# A sibling lands first, advancing main past GATED_AT.
printf 'sibling landed first\n' >> "$REPO/README.md"
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m "sibling"
MAIN_NOW="$(git -C "$REPO" rev-parse HEAD)"

VERDICT_FILE="$T/ac4-verdict.json"
write_verdict "$VERDICT_FILE" pass
out="$T/ac4.out"
"$WORKTREE_EXTEND" land --gated-at "$GATED_AT" --verdict "$VERDICT_FILE" "$REPO" ac4-slug >"$out" 2>&1
rc=$?
expect "AC4: land exits 6 (land-stale-base)" "[ $rc -eq 6 ]"
expect "AC4: message names land-stale-base with both shas" \
  "grep -q \"land-stale-base (gated_at=$GATED_AT main=$MAIN_NOW)\" \"$out\""
expect "AC4: main is unchanged (still at the sibling's commit)" \
  "[ \"\$(git -C \"$REPO\" rev-parse main)\" = \"$MAIN_NOW\" ]"
expect "AC4: the branch still exists (worktree/commits intact, not landed)" \
  "git -C \"$REPO\" show-ref --verify --quiet refs/heads/autobuilder/ac4-slug"

# =========================================================================
# AC6 — ungated: verdict=block
# =========================================================================
echo "=== AC6a: land-ungated (verdict=block) ==="
REPO2="$(mk_repo ac6a)"
GATED_AT2="$(git -C "$REPO2" rev-parse HEAD)"
WT2="$("$WORKTREE_EXTEND" add "$REPO2" ac6a-slug 2>/dev/null)"
printf 'branch work\n' >> "$WT2/README.md"
git -C "$WT2" "${GIT_ID[@]}" add -A
git -C "$WT2" "${GIT_ID[@]}" commit -q -m "branch work"

VERDICT_FILE2="$T/ac6a-verdict.json"
write_verdict "$VERDICT_FILE2" block
out2="$T/ac6a.out"
"$WORKTREE_EXTEND" land --gated-at "$GATED_AT2" --verdict "$VERDICT_FILE2" "$REPO2" ac6a-slug >"$out2" 2>&1
rc2=$?
expect "AC6a: land exits 7 (land-ungated)" "[ $rc2 -eq 7 ]"
expect "AC6a: message names land-ungated verdict=block" "grep -q 'land-ungated (verdict=block)' \"$out2\""
expect "AC6a: main is unchanged" "[ \"\$(git -C \"$REPO2\" rev-parse main)\" = \"$GATED_AT2\" ]"

# =========================================================================
# AC6 — ungated: verdict file missing
# =========================================================================
echo "=== AC6b: land-ungated (verdict=missing) ==="
REPO3="$(mk_repo ac6b)"
GATED_AT3="$(git -C "$REPO3" rev-parse HEAD)"
WT3="$("$WORKTREE_EXTEND" add "$REPO3" ac6b-slug 2>/dev/null)"
printf 'branch work\n' >> "$WT3/README.md"
git -C "$WT3" "${GIT_ID[@]}" add -A
git -C "$WT3" "${GIT_ID[@]}" commit -q -m "branch work"

VERDICT_FILE3="$T/ac6b-verdict-does-not-exist.json"
out3="$T/ac6b.out"
"$WORKTREE_EXTEND" land --gated-at "$GATED_AT3" --verdict "$VERDICT_FILE3" "$REPO3" ac6b-slug >"$out3" 2>&1
rc3=$?
expect "AC6b: land exits 7 (land-ungated)" "[ $rc3 -eq 7 ]"
expect "AC6b: message names land-ungated verdict=missing" "grep -q 'land-ungated (verdict=missing)' \"$out3\""
expect "AC6b: main is unchanged" "[ \"\$(git -C \"$REPO3\" rev-parse main)\" = \"$GATED_AT3\" ]"

# =========================================================================
# AC3 — happy path: gated_at matches, verdict=pass -> lands, journals
# =========================================================================
echo "=== AC3: gated land succeeds and journals ==="
REPO4="$(mk_repo ac3)"
GATED_AT4="$(git -C "$REPO4" rev-parse HEAD)"
WT4="$("$WORKTREE_EXTEND" add "$REPO4" ac3-slug 2>/dev/null)"
printf 'branch work\n' >> "$WT4/README.md"
git -C "$WT4" "${GIT_ID[@]}" add -A
git -C "$WT4" "${GIT_ID[@]}" commit -q -m "branch work"

VERDICT_FILE4="$T/ac3-verdict.json"
write_verdict "$VERDICT_FILE4" delta-pass
before_lines="$(count_land_lines)"
out4="$T/ac3.out"
t0="$EPOCHREALTIME"
"$WORKTREE_EXTEND" land --gated-at "$GATED_AT4" --verdict "$VERDICT_FILE4" "$REPO4" ac3-slug >"$out4" 2>&1
rc4=$?
t1="$EPOCHREALTIME"
expect "AC3: land exits 0" "[ $rc4 -eq 0 ]"
expect "AC3: main advanced (merge landed)" "[ \"\$(git -C \"$REPO4\" rev-parse main)\" != \"$GATED_AT4\" ]"
after_lines="$(count_land_lines)"
expect "AC3: exactly one new 'land' journal line was written" "[ $((after_lines - before_lines)) -eq 1 ]"
journal_line="$(grep "^.*  land  ac3-slug  " "$JOURNAL" | tail -1)"
expect "AC3: journal line carries gated_at=$GATED_AT4" "printf '%s' \"$journal_line\" | grep -q \"gated_at=$GATED_AT4\""
lock_hold="$(printf '%s' "$journal_line" | sed -n 's/.*lock_hold=\([0-9]*\)s.*/\1/p')"
expect "AC3: journal line carries a numeric lock_hold" "[ -n \"$lock_hold\" ]"
expect "AC3: lock_hold is well under 30s on this warm repo" "[ \"$lock_hold\" -lt 30 ]"
wall="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)}')"
echo "  lock_hold=${lock_hold}s wall=${wall}s"

# =========================================================================
# Regression — omitted --gated-at reproduces today's behavior: no check,
# no journal line.
# =========================================================================
echo "=== regression: ungated land (no --gated-at) is unchanged ==="
REPO5="$(mk_repo legacy)"
WT5="$("$WORKTREE_EXTEND" add "$REPO5" legacy-slug 2>/dev/null)"
printf 'branch work\n' >> "$WT5/README.md"
git -C "$WT5" "${GIT_ID[@]}" add -A
git -C "$WT5" "${GIT_ID[@]}" commit -q -m "branch work"
before_lines5="$(count_land_lines)"
"$WORKTREE_EXTEND" land "$REPO5" legacy-slug >/dev/null 2>&1
rc5=$?
after_lines5="$(count_land_lines)"
expect "regression: ungated land still exits 0" "[ $rc5 -eq 0 ]"
expect "regression: ungated land writes NO journal line" "[ $((after_lines5 - before_lines5)) -eq 0 ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "worktree-extend-gated-land-selftest: ALL PASS"
  exit 0
else
  echo "worktree-extend-gated-land-selftest: assertion(s) FAILED"
  exit 1
fi
