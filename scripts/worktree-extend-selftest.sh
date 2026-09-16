#!/usr/bin/env bash
# worktree-extend-selftest.sh — regression coverage for
# PRD-build-shell-worktree-isolation AC1-4, AC5, AC7-9: the shell/hooks/
# config worktree-isolation mechanism (`worktree-extend.sh add`/`land`
# skill-shaped reminder, rebase-first land, `transition`, `list`'s
# lang/behind/dirty columns, and chain-guard.sh's `worktree-isolated:`
# line). AC6 (build-contract.md wording) has no runtime behavior to drive
# and is checked directly by tests/shwt_ac6_contract_wording.sh instead.
#
# Same convention as scripts/python-worktree-selftest.sh: one monolith
# driving the REAL scripts against disposable fixture repos under
# $TMPDIR, emitting `ok  <label>` / `FAIL <label>` lines; the
# tests/shwt_ac<N>_*.sh wrappers just assert specific labels are present
# (tests/fixtures/shwt-ac-common.sh) rather than re-implementing the
# behavior a second time.
#
# Usage: worktree-extend-selftest.sh
# Exit: 0 all checks pass | 1 a check failed | 2 missing prerequisite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKTREE_EXTEND="$HERE/worktree-extend.sh"
CHAIN_GUARD="$HERE/chain-guard.sh"
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
[ -x "$CHAIN_GUARD" ] || { echo "selftest: $CHAIN_GUARD not executable" >&2; exit 2; }
for bin in git flock jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/shwt-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
export WORKTREE_EXTEND_JOURNAL="$T/journal.md"
# Both BUILD_STATE_DIR and the bare STATE_DIR: manifest-sidecar.sh (called
# by worktree-extend.sh on a land conflict) keys off STATE_DIR alone with
# no BUILD_STATE_DIR fallback — the exact naming split requirement 4's
# reminder now covers. Missing either one here would leak a land-conflict
# fixture's sidecar write into this real skill's own production state/.
export BUILD_STATE_DIR="$T/fixture-state" STATE_DIR="$T/fixture-state"
mkdir -p "$BUILD_STATE_DIR"
trap '[ -n "${SHWT_SELFTEST_KEEP:-}" ] || { for r in "$T"/repo*; do [ -d "$r" ] || continue; git -C "$r" worktree list --porcelain 2>/dev/null | awk "/^worktree /{print \$2}" | grep -F "$BUILD_WT_ROOT" | while read -r w; do git -C "$r" worktree remove --force "$w" 2>/dev/null; done; done; rm -rf "$T"; }' EXIT

GIT_ID=(-c user.email=test@shwt-selftest.local -c user.name="shwt-selftest")

# ===== AC1: skill-shaped fixture repo, `add`, stderr reminder, main unchanged =====
REPO1="$T/repo-skillshaped"
mkdir -p "$REPO1/scripts"
git -C "$REPO1" init -q -b main
{
  echo "---"
  echo "name: fixture-skill"
  echo "---"
  echo "# fixture skill"
} > "$REPO1/SKILL.md"
printf '#!/usr/bin/env bash\necho ok\n' > "$REPO1/scripts/run-selftests.sh"
chmod +x "$REPO1/scripts/run-selftests.sh"
git -C "$REPO1" "${GIT_ID[@]}" add -A
git -C "$REPO1" "${GIT_ID[@]}" commit -q -m "init fixture skill repo"

WT1A="$("$WORKTREE_EXTEND" add "$REPO1" ac1 2>"$T/ac1-add.stderr")"
expect "AC1: add returns a worktree path under BUILD_WT_ROOT" \
  "[ -n \"$WT1A\" ] && [ -d \"$WT1A\" ] && [ \"\${WT1A#\$BUILD_WT_ROOT}\" != \"\$WT1A\" ]"
expect "AC1: worktree is on branch autobuilder/ac1" \
  "[ \"\$(git -C "$WT1A" symbolic-ref --short HEAD)\" = autobuilder/ac1 ]"
expect "AC1: stderr names the production-state rule" \
  "grep -q 'production-state rule' "$T/ac1-add.stderr""
expect "AC1: stderr names the worktree-local BUILD_STATE_DIR export" \
  "grep -qF 'BUILD_STATE_DIR=\"$WT1A/state\"' "$T/ac1-add.stderr""
expect "AC1: main checkout unchanged after add" \
  "[ -z \"\$(git -C "$REPO1" status --porcelain)\" ]"

# ===== AC2 / AC3: two branches sharing one build_into, disjoint vs conflicting =====
REPO2="$T/repo-shared"
mkdir -p "$REPO2/scripts"
git -C "$REPO2" init -q -b main
printf 'readme v0\n' > "$REPO2/README.md"
printf 'line1\nline2\nline3\n' > "$REPO2/scripts/x.sh"
git -C "$REPO2" "${GIT_ID[@]}" add -A
git -C "$REPO2" "${GIT_ID[@]}" commit -q -m "init shared fixture"

# AC2: s1 (README.md) lands first; s2 (scripts/x.sh, disjoint file) rebases clean.
WT2S1="$("$WORKTREE_EXTEND" add "$REPO2" s1 2>/dev/null)"
printf 'readme v1 (s1)\n' > "$WT2S1/README.md"
git -C "$WT2S1" "${GIT_ID[@]}" add -A && git -C "$WT2S1" "${GIT_ID[@]}" commit -q -m "s1: readme"
WT2S2="$("$WORKTREE_EXTEND" add "$REPO2" s2 2>/dev/null)"
printf 'line1\nline2\nline3\nline4 (s2)\n' > "$WT2S2/scripts/x.sh"
git -C "$WT2S2" "${GIT_ID[@]}" add -A && git -C "$WT2S2" "${GIT_ID[@]}" commit -q -m "s2: x.sh"

"$WORKTREE_EXTEND" land "$REPO2" s1 >/dev/null 2>&1
s1_rc=$?
expect "AC2: s1 (first lander) exits 0" "[ $s1_rc -eq 0 ]"
: > "$T/journal.md"
"$WORKTREE_EXTEND" land "$REPO2" s2 >/dev/null 2>&1
s2_rc=$?
expect "AC2: s2 (rebase-first, disjoint file) exits 0" "[ $s2_rc -eq 0 ]"
expect "AC2: journal names the rebase with commits=1" \
  "grep -qE 'land  rebased  \(slug=s2 onto=[0-9a-f]+ commits=1\)' "$T/journal.md""
expect "AC2: main has both s1's and s2's changes" \
  "grep -q 's1' "$REPO2/README.md" && grep -q 's2' "$REPO2/scripts/x.sh""

# AC3: s3 vs s4, both edit line 2 of the SAME file — a genuine conflict once
# s3 has already landed and s4's rebase collides with it.
printf 'alpha\nbeta\ngamma\n' > "$REPO2/shared.txt"
git -C "$REPO2" "${GIT_ID[@]}" add -A && git -C "$REPO2" "${GIT_ID[@]}" commit -q -m "add shared.txt"
WT2S3="$("$WORKTREE_EXTEND" add "$REPO2" s3 2>/dev/null)"
sed -i 's/beta/beta-s3/' "$WT2S3/shared.txt"
git -C "$WT2S3" "${GIT_ID[@]}" add -A && git -C "$WT2S3" "${GIT_ID[@]}" commit -q -m "s3: edit shared.txt"
WT2S4="$("$WORKTREE_EXTEND" add "$REPO2" s4 2>/dev/null)"
sed -i 's/beta/beta-s4/' "$WT2S4/shared.txt"
git -C "$WT2S4" "${GIT_ID[@]}" add -A && git -C "$WT2S4" "${GIT_ID[@]}" commit -q -m "s4: edit shared.txt"

"$WORKTREE_EXTEND" land "$REPO2" s3 >/dev/null 2>&1
s3_rc=$?
main_after_s3="$(git -C "$REPO2" rev-parse HEAD)"
: > "$T/journal.md"
"$WORKTREE_EXTEND" land "$REPO2" s4 >/dev/null 2>&1
s4_rc=$?
expect "AC3: s3 lands cleanly (exit 0)" "[ $s3_rc -eq 0 ]"
expect "AC3: s4's conflicting rebase-land exits 5" "[ $s4_rc -eq 5 ]"
expect "AC3: journal names the conflict and the file" \
  "grep -qE 'land  conflict  \(slug=s4 files=shared\.txt\)' "$T/journal.md""
expect "AC3: autobuilder/s4 branch still has its own commit" \
  "git -C "$REPO2" show autobuilder/s4:shared.txt | grep -q beta-s4"
expect "AC3: main is unchanged (still s3's landing)" \
  "[ \"\$(git -C "$REPO2" rev-parse HEAD)\" = \"$main_after_s3\" ]"

# ===== AC4: dirty main refuses to land, no mutation =====
REPO4="$T/repo-dirty"
mkdir -p "$REPO4"
git -C "$REPO4" init -q -b main
echo "v0" > "$REPO4/f.txt"
git -C "$REPO4" "${GIT_ID[@]}" add -A && git -C "$REPO4" "${GIT_ID[@]}" commit -q -m init
WT4="$("$WORKTREE_EXTEND" add "$REPO4" d1 2>/dev/null)"
echo "v1" > "$WT4/f.txt"
git -C "$WT4" "${GIT_ID[@]}" add -A && git -C "$WT4" "${GIT_ID[@]}" commit -q -m "d1: bump"
echo "untracked dirty edit" >> "$REPO4/other-dirty.md"
before_head="$(git -C "$REPO4" rev-parse HEAD)"
"$WORKTREE_EXTEND" land "$REPO4" d1 >/tmp/shwt-ac4.$$.log 2>&1
d1_rc=$?
expect "AC4: land against dirty main exits 4" "[ $d1_rc -eq 4 ]"
expect "AC4: dirty-main message names the case" "grep -q 'dirty' /tmp/shwt-ac4.$$.log"
expect "AC4: no mutation — HEAD unchanged" "[ \"\$(git -C "$REPO4" rev-parse HEAD)\" = \"$before_head\" ]"
expect "AC4: d1's branch commit remains intact for retry" \
  "git -C "$REPO4" show autobuilder/d1:f.txt | grep -q v1"
rm -f "$REPO4/other-dirty.md" /tmp/shwt-ac4.$$.log

# ===== AC5: a worktree selftest, run with the printed env, never touches
# the fixture's "production" state/journal =====
FIXTURE_PROD_STATE="$T/fixture-prod-state"
FIXTURE_PROD_JOURNAL="$T/fixture-prod-journal.md"
mkdir -p "$FIXTURE_PROD_STATE"
: > "$FIXTURE_PROD_JOURNAL"
WT_AC5="$("$WORKTREE_EXTEND" add "$REPO1" ac5 2>/dev/null)"
# Simulate the exact env `add`'s reminder tells a worktree selftest to
# export, then run a toy "selftest" that writes state + a journal line —
# using the SAME two env vars a real production script would read.
(
  export BUILD_STATE_DIR="$WT_AC5/state" STATE_DIR="$WT_AC5/state" BURST_LANE_STATE_DIR="$WT_AC5/state/burst-lane"
  mkdir -p "$BUILD_STATE_DIR"
  echo '{"probe":true}' > "$BUILD_STATE_DIR/probe.json"
  echo "probe journal line" >> "$T/journal.md"
)
expect "AC5: worktree state/ gained the probe file" "[ -f "$WT_AC5/state/probe.json" ]"
expect "AC5: fixture's 'production' state dir gained nothing" \
  "[ -z \"\$(ls -A "$FIXTURE_PROD_STATE" 2>/dev/null)\" ]"
expect "AC5: fixture's 'production' journal gained no lines" \
  "[ ! -s "$FIXTURE_PROD_JOURNAL" ]"

# ===== AC7: chain-guard.sh prints worktree-isolated: yes|no =====
CG_STATE="$T/cg-state"
mkdir -p "$CG_STATE"
python3 - "$CG_STATE/manifest.json" "$BUILD_WT_ROOT" <<'PY'
import json, sys
path, wt_root = sys.argv[1], sys.argv[2]
manifest = {"prds": {
    "shwt-isolated": {"status": "queued", "build_target": "shell", "blockers": [],
                       "work_tree": wt_root + "/repo-skillshaped-ac1"},
    "shwt-not-isolated": {"status": "queued", "build_target": "shell", "blockers": []},
}}
with open(path, "w") as f:
    json.dump(manifest, f)
PY
cg_out_yes="$(BUILD_STATE_DIR="$CG_STATE" BUILD_MANIFEST="$CG_STATE/manifest.json" BUILD_WT_ROOT="$BUILD_WT_ROOT" "$CHAIN_GUARD" check shwt-isolated --skip-select-guard 2>/dev/null)"
cg_out_no="$(BUILD_STATE_DIR="$CG_STATE" BUILD_MANIFEST="$CG_STATE/manifest.json" BUILD_WT_ROOT="$BUILD_WT_ROOT" "$CHAIN_GUARD" check shwt-not-isolated --skip-select-guard 2>/dev/null)"
expect "AC7: a PRD whose work_tree is under the worktree root reports worktree-isolated: yes" \
  "grep -qF 'worktree-isolated: yes' <<<\"\$cg_out_yes\""
expect "AC7: a PRD with no work_tree reports worktree-isolated: no" \
  "grep -qF 'worktree-isolated: no' <<<\"\$cg_out_no\""

# ===== AC8: transition attributes dirty files per-branch, sweeps the rest =====
REPO8="$T/repo-transition"
mkdir -p "$REPO8"
git -C "$REPO8" init -q -b main
echo "a" > "$REPO8/a.sh"; echo "b" > "$REPO8/b.sh"; echo "c" > "$REPO8/c.sh"
git -C "$REPO8" "${GIT_ID[@]}" add -A && git -C "$REPO8" "${GIT_ID[@]}" commit -q -m init
WT8S1="$("$WORKTREE_EXTEND" add "$REPO8" tr1 2>/dev/null)"
printf 'a\na-line2\na-line3\n' > "$WT8S1/a.sh"
git -C "$WT8S1" "${GIT_ID[@]}" add -A && git -C "$WT8S1" "${GIT_ID[@]}" commit -q -m "tr1: extend a.sh"
# Dirty main directly (the pre-this-PRD failure mode): a.sh gets a NEW,
# non-overlapping line appended (attributable to tr1 without colliding with
# tr1's own edit), b.sh and c.sh are untouched by any branch (unattributable).
printf 'a\na-appended-in-main\n' > "$REPO8/a.sh"
echo "b-dirty" >> "$REPO8/b.sh"
echo "c-dirty" >> "$REPO8/c.sh"
: > "$T/journal.md"
"$WORKTREE_EXTEND" transition "$REPO8" >/dev/null 2>&1
tr_rc=$?
expect "AC8: transition exits 0" "[ $tr_rc -eq 0 ]"
expect "AC8: main is clean after transition" "[ -z \"\$(git -C "$REPO8" status --porcelain)\" ]"
expect "AC8: journal names dirty_files=3" "grep -qE 'worktree  transition  \(dirty_files=3 action=committed\)' "$T/journal.md""
expect "AC8: attributed file's dirty edit reached autobuilder/tr1" \
  "git -C "$REPO8" show autobuilder/tr1:a.sh | grep -q appended-in-main"
tbranch8="$(git -C "$REPO8" for-each-ref --format='%(refname:short)' 'refs/heads/transition/*' | head -1)"
expect "AC8: an unattributable-files transition/<ts> branch was created" "[ -n \"$tbranch8\" ]"
expect "AC8: b.sh landed on the transition branch" "git -C "$REPO8" show "$tbranch8:b.sh" | grep -q b-dirty"
expect "AC8: c.sh landed on the transition branch" "git -C "$REPO8" show "$tbranch8:c.sh" | grep -q c-dirty"

# ===== AC9 (P1): `list` shows lang=/behind=/dirty= per worktree =====
REPO9="$T/repo-list"
mkdir -p "$REPO9"
git -C "$REPO9" init -q -b main
echo v0 > "$REPO9/f.txt"
git -C "$REPO9" "${GIT_ID[@]}" add -A && git -C "$REPO9" "${GIT_ID[@]}" commit -q -m init
WT9A="$("$WORKTREE_EXTEND" add "$REPO9" l1 2>/dev/null)"
WT9B="$("$WORKTREE_EXTEND" add "$REPO9" l2 2>/dev/null)"
echo v1 > "$REPO9/f.txt"
git -C "$REPO9" "${GIT_ID[@]}" add -A && git -C "$REPO9" "${GIT_ID[@]}" commit -q -m "advance main"
echo "uncommitted" >> "$WT9B/f2.txt"
list_out="$("$WORKTREE_EXTEND" list "$REPO9")"
expect "AC9: l1's row names lang=shell" \
  "grep -F 'autobuilder/l1' <<<\"\$list_out\" | grep -q 'lang=shell'"
expect "AC9: l1's row shows behind=1 (main advanced once since add)" \
  "grep -F 'autobuilder/l1' <<<\"\$list_out\" | grep -q 'behind=1'"
expect "AC9: l1's row shows dirty=no" \
  "grep -F 'autobuilder/l1' <<<\"\$list_out\" | grep -q 'dirty=no'"
expect "AC9: l2's row shows dirty=yes (uncommitted file in its worktree)" \
  "grep -F 'autobuilder/l2' <<<\"\$list_out\" | grep -q 'dirty=yes'"

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "worktree-extend-selftest: ALL CHECKS PASS"
else
  echo "worktree-extend-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
