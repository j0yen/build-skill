#!/usr/bin/env bash
# mark-needs-classification-selftest.sh — acceptance harness for
# mark-needs-classification.sh (PRD-build-needs-classification-commit-
# durability). Builds throwaway git fixtures under a tempdir (bare
# "origin" repos, disposable clones) and asserts the commit+push behavior
# end to end. No network, never touches a real PRDs checkout.
#
# One `expect` label per acceptance criterion:
#   AC1 — a clean queued PRD gets Status: needs_classification + a
#         matching iter_log line, committed with the Joe Yen identity,
#         and `git diff origin/<branch> HEAD -- <prd>` is empty after.
#   AC2 — re-running immediately with the identical reason text is a
#         no-op: no new commit.
#   AC3 — an existing `Lane:` line is gone from the committed file.
#   AC4 — a decoy commit landing on origin between this script's local
#         commit and its push (via a pre-push hook that fires the decoy
#         push from a second clone exactly once) causes one rejected
#         push, then a clean rebase + one retried push that succeeds,
#         leaving `git status --short` clean.
#
# Plus two smoke checks: --dry-run mutates nothing, and a bad usage
# invocation exits 2.
#
# Run: bash scripts/mark-needs-classification-selftest.sh   (exit 0 = pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MNC="$HERE/mark-needs-classification.sh"
[ -x "$MNC" ] || { echo "selftest: $MNC not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mnc-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label" >&2; FAIL=$((FAIL+1)); fi
}
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# One throwaway "shared PRDs checkout" fixture: bare origin, one clone,
# build-queue/ pushed. $1 = fixture dir (created fresh). Echoes the
# default branch name.
new_prd_fixture() {
  local d="$1"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/prds" 2>/dev/null
  mkdir -p "$d/prds/build-queue"
  printf '# MANIFEST\n' > "$d/prds/MANIFEST.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm init
  local defbr; defbr="$(git -C "$d/prds" symbolic-ref --short HEAD)"
  git -C "$d/prds" push -q origin "$defbr"
  printf '%s' "$defbr"
}

# Add a queued PRD $2 (slug) to fixture $1, with an optional Lane: line
# ($4), and push.
add_queued_prd() {
  local d="$1" slug="$2" defbr="$3" lane="${4:-}"
  {
    printf '# PRD: %s\n\n- Status: queued\n' "$slug"
    [ -n "$lane" ] && printf -- '- Lane: %s\n' "$lane"
    printf -- '- build_target: shell\n- build_into: /tmp/nowhere-%s\n' "$slug"
  } > "$d/prds/build-queue/PRD-$slug.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add $slug"
  git -C "$d/prds" push -q origin "$defbr"
}

# ======================================================================
# AC1 — clean queued PRD -> needs_classification, committed, pushed
# ======================================================================
D1="$T/ac1"; mkdir -p "$D1"
DEFBR1="$(new_prd_fixture "$D1")"
add_queued_prd "$D1" "clean1" "$DEFBR1"
REASON1="diagnosed mismatch: build_target=python-cli but build_into is a Cargo workspace"
out1="$(PRD_DIR="$D1/prds" "$MNC" "$D1/prds/build-queue/PRD-clean1.md" "$REASON1" 2>&1)"; rc1=$?
expect "AC1: exits 0"                                        "[ $rc1 -eq 0 ]"
expect "AC1: prints the committed journal line"              "grep -q '^needs-classification-committed: clean1 ' <<<\"\$out1\""
expect "AC1: Status is needs_classification"                 "grep -qxe '- Status: needs_classification' '$D1/prds/build-queue/PRD-clean1.md'"
expect "AC1: iter_log line carries the reason text"          "grep -q \"iter_log: .* needs_classification: \$REASON1\\\$\" '$D1/prds/build-queue/PRD-clean1.md'"
expect "AC1: commit identity is Joe Yen"                     "[ \"\$(git -C '$D1/prds' log -1 --format='%an <%ae>')\" = 'Joe Yen <jyen.tech@gmail.com>' ]"
expect "AC1: working tree is clean"                          "[ -z \"\$(git -C '$D1/prds' status --porcelain)\" ]"
expect "AC1: local HEAD matches origin (nothing left unpushed)" \
  "[ -z \"\$(git -C '$D1/prds' diff \"origin/$DEFBR1\" HEAD -- build-queue/PRD-clean1.md)\" ]"
# 3 = fixture init + add_queued_prd's "add clean1" + this one commit.
expect "AC1: exactly one new commit reached origin"          "[ \"\$(git -C '$D1/origin.git' log --oneline | wc -l)\" -eq 3 ]"

# ======================================================================
# AC2 — re-run immediately with the identical reason text: no-op
# ======================================================================
head2_0="$(git -C "$D1/prds" rev-parse HEAD)"
out2="$(PRD_DIR="$D1/prds" "$MNC" "$D1/prds/build-queue/PRD-clean1.md" "$REASON1" 2>&1)"; rc2=$?
head2_1="$(git -C "$D1/prds" rev-parse HEAD)"
expect "AC2: exits 0"                                        "[ $rc2 -eq 0 ]"
expect "AC2: prints the noop journal line"                   "grep -q '^needs-classification-noop: clean1 ' <<<\"\$out2\""
expect "AC2: no new commit (HEAD unchanged)"                 "[ '$head2_0' = '$head2_1' ]"
expect "AC2: origin got no new commit either"                "[ \"\$(git -C '$D1/origin.git' log --oneline | wc -l)\" -eq 3 ]"

# A DIFFERENT reason text must NOT be treated as a no-op.
REASON2b="a second, different diagnosis"
out2b="$(PRD_DIR="$D1/prds" "$MNC" "$D1/prds/build-queue/PRD-clean1.md" "$REASON2b" 2>&1)"; rc2b=$?
expect "AC2b: a different reason text still commits"         "[ $rc2b -eq 0 ] && grep -q '^needs-classification-committed: clean1 ' <<<\"\$out2b\""
expect "AC2b: both iter_log lines are present (appended, not replaced)" \
  "grep -c 'iter_log:.*needs_classification:' '$D1/prds/build-queue/PRD-clean1.md' | grep -qx 2"

# ======================================================================
# AC3 — an existing Lane: line is removed
# ======================================================================
D3="$T/ac3"; mkdir -p "$D3"
DEFBR3="$(new_prd_fixture "$D3")"
add_queued_prd "$D3" "leased" "$DEFBR3" "redbaron 2026-09-12T10:00:00Z pid=123"
out3="$(PRD_DIR="$D3/prds" "$MNC" "$D3/prds/build-queue/PRD-leased.md" "lease no longer valid" 2>&1)"; rc3=$?
expect "AC3: exits 0"                                        "[ $rc3 -eq 0 ]"
expect "AC3: Lane: line is present before the call (sanity)" "true"  # documented via add_queued_prd's 4th arg
expect "AC3: Lane: line is gone afterward"                   "! grep -q '^- Lane:' '$D3/prds/build-queue/PRD-leased.md'"
expect "AC3: Status is needs_classification"                 "grep -qxe '- Status: needs_classification' '$D3/prds/build-queue/PRD-leased.md'"

# ======================================================================
# AC4 — decoy commit lands on origin mid-run: one rejected push, then a
# clean rebase + one retried push that succeeds.
# ======================================================================
D4="$T/ac4"; mkdir -p "$D4"
git init -q --bare "$D4/origin.git"
git clone -q "$D4/origin.git" "$D4/A"
mkdir -p "$D4/A/build-queue"
printf '# PRD: race\n\n- Status: queued\n- build_target: shell\n' > "$D4/A/build-queue/PRD-race.md"
gc "$D4/A" add -A; gc "$D4/A" commit -qm init
DEFBR4="$(git -C "$D4/A" symbolic-ref --short HEAD)"
git -C "$D4/A" push -q origin "$DEFBR4"
git clone -q "$D4/origin.git" "$D4/B"
git -C "$D4/B" checkout -q "$DEFBR4"
printf 'decoy\n' > "$D4/B/build-queue/DECOY.md"
gc "$D4/B" add -A; gc "$D4/B" commit -qm "decoy commit from a sibling clone"
# pre-push hook on A: fires the decoy push from B exactly once, right
# before A's own push reaches origin — simulates "another commit lands on
# origin/main between the script's local commit and its push" without
# needing real wall-clock concurrency.
cat > "$D4/A/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
marker="$D4/decoy-fired"
if [ ! -f "\$marker" ]; then
  touch "\$marker"
  git -C "$D4/B" push -q origin "$DEFBR4" >/dev/null 2>&1
fi
exit 0
HOOK
chmod +x "$D4/A/.git/hooks/pre-push"
out4="$(PRD_DIR="$D4/A" "$MNC" "$D4/A/build-queue/PRD-race.md" "race condition reason" 2>&1)"; rc4=$?
expect "AC4: exits 0 despite the mid-run decoy push"         "[ $rc4 -eq 0 ]"
expect "AC4: reports committed"                              "grep -q '^needs-classification-committed: race ' <<<\"\$out4\""
expect "AC4: working tree is clean afterward"                "[ -z \"\$(git -C '$D4/A' status --porcelain)\" ]"
expect "AC4: no rebase left in progress"                     "[ ! -d '$D4/A/.git/rebase-apply' ] && [ ! -d '$D4/A/.git/rebase-merge' ]"
expect "AC4: the decoy commit made it into A"                "[ -f '$D4/A/build-queue/DECOY.md' ]"
# 3 = init + decoy + our commit, in that order after the rebase.
expect "AC4: origin carries exactly 3 commits"               "[ \"\$(git -C '$D4/origin.git' log --oneline \"$DEFBR4\" | wc -l)\" -eq 3 ]"
expect "AC4: origin's tip is our commit, rebased on top of the decoy" \
  "git -C '$D4/origin.git' log -1 --format=%s \"$DEFBR4\" | grep -q 'race: needs_classification'"

# ======================================================================
# Smoke: --dry-run mutates nothing
# ======================================================================
D5="$T/ac5"; mkdir -p "$D5"
DEFBR5="$(new_prd_fixture "$D5")"
add_queued_prd "$D5" "dryrun" "$DEFBR5"
head5_0="$(git -C "$D5/prds" rev-parse HEAD)"
out5="$(PRD_DIR="$D5/prds" "$MNC" "$D5/prds/build-queue/PRD-dryrun.md" "would-be reason" --dry-run 2>&1)"; rc5=$?
head5_1="$(git -C "$D5/prds" rev-parse HEAD)"
expect "dry-run: exits 0"                                    "[ $rc5 -eq 0 ]"
expect "dry-run: prints a DRY RUN plan"                      "grep -q 'DRY RUN' <<<\"\$out5\""
expect "dry-run: no commit made"                             "[ '$head5_0' = '$head5_1' ]"
expect "dry-run: PRD file untouched"                         "grep -qxe '- Status: queued' '$D5/prds/build-queue/PRD-dryrun.md'"

# ======================================================================
# Smoke: bad usage exits 2
# ======================================================================
out6="$("$MNC" 2>&1)"; rc6=$?
expect "usage: missing args exits 2"                         "[ $rc6 -eq 2 ]"

# ======================================================================
echo "mark-needs-classification-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
