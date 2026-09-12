#!/usr/bin/env bash
# archive-commit-selftest.sh — durable acceptance harness for
# archive-commit.sh + the lane-claim.sh pull hardening it depends on
# (PRD-build-archive-atomic-commit). Builds throwaway git fixtures under
# a tempdir (bare "origin" repos, disposable clones) and asserts the
# atomic-write + tolerant-pull behavior end to end. No network.
#
# Covers, one `expect` label per acceptance criterion so
# `tests/archatomic_ac<N>_*.sh` wrappers (via
# tests/fixtures/archatomic-ac-common.sh) can pull individual labels out
# of one shared run — mirrors tests/fixtures/gateconcurrent-ac-common.sh's
# convention (one real implementation, thin per-AC wrappers, no
# hand-duplicated second copy of the logic to drift from the first):
#   AC1 — a clean archive lands atomically: header + move + manifest flip
#         + push all in one commit, checkout ends clean.
#   AC2 — a missing receipt refuses before any write, naming the
#         `receipt` step (the required real failure-mode case).
#   AC3 — the integrate lock held by another process is waited out; the
#         journal line's lock_wait reflects the real wait.
#   AC4 — the lock held past the bound times out, naming `lock-timeout`,
#         with zero writes (the other required real failure-mode case).
#   AC5 — a sibling's uncommitted, non-conflicting edit survives a
#         lane-claim.sh claim's hardened pull (the "concurrent sibling
#         pull during the archive window doesn't fail" case).
#   AC6 — a sibling's uncommitted edit that DOES conflict with the
#         incoming commit is restored exactly, and the claim returns
#         checkout-conflict rather than committing over unresolved
#         conflict markers (a second required real failure-mode case).
#   AC7 — SKILL.md's archive step names archive-commit.sh and contains no
#         `git mv` / `Status:`-editing instructions.
#
# Run: bash scripts/archive-commit-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
AC="$HERE/archive-commit.sh"
LC="$HERE/lane-claim.sh"
[ -x "$AC" ] || { echo "selftest: $AC not executable" >&2; exit 2; }
[ -x "$LC" ] || { echo "selftest: $LC not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/archatomic-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label" >&2; FAIL=$((FAIL+1)); fi
}
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# Build one throwaway "shared PRDs checkout" fixture: bare origin, one
# clone, build-queue/ + built-prds/ + MANIFEST.md, pushed to origin.
# $1 = fixture dir (created fresh).
new_prd_fixture() {
  local d="$1"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/prds" 2>/dev/null
  mkdir -p "$d/prds/build-queue" "$d/prds/built-prds"
  printf '# MANIFEST\n\n## build-queue\n\n## built-prds\n' > "$d/prds/MANIFEST.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm init
  local defbr; defbr="$(git -C "$d/prds" symbolic-ref --short HEAD)"
  git -C "$d/prds" push -q origin "$defbr"
  printf '%s' "$defbr"
}

# Add a queued PRD $2 (slug) to fixture $1, with a MANIFEST.md line, and
# push. Does not set up a receipt.
add_queued_prd() {
  local d="$1" slug="$2" defbr="$3"
  printf '# PRD: %s\n\n- Status: queued\n- build_target: shell\n- build_into: /tmp/nowhere-%s\n' "$slug" "$slug" \
    > "$d/prds/build-queue/PRD-$slug.md"
  python3 - "$d/prds/MANIFEST.md" "$slug" <<'PY'
import sys
f, slug = sys.argv[1], sys.argv[2]
with open(f) as fh: c = fh.read()
c = c.replace("## build-queue\n", f"## build-queue\n- PRD-{slug}.md — queued · shell · 2026-09-12\n")
with open(f, 'w') as fh: fh.write(c)
PY
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add $slug"
  git -C "$d/prds" push -q origin "$defbr"
}

# ======================================================================
# AC1 — clean archive lands atomically
# ======================================================================
D1="$T/ac1"; mkdir -p "$D1"
DEFBR1="$(new_prd_fixture "$D1")"
add_queued_prd "$D1" "clean1" "$DEFBR1"
mkdir -p "$D1/receipts"; echo "receipt" > "$D1/receipts/r.txt"
cat > "$D1/bmanifest.json" <<EOF
{"prds":{"clean1":{"slug":"clean1","receipts_dir":"$D1/receipts","gate":{"verdict":"pass"},"tag":"v1.0.0","rollback_base":"v0.9.0"}}}
EOF
out1="$(PRD_DIR="$D1/prds" BUILD_MANIFEST="$D1/bmanifest.json" "$AC" clean1 2>&1)"; rc1=$?
expect "AC1: archive-commit exits 0"                       "[ $rc1 -eq 0 ]"
expect "AC1: prints the archive-commit journal line"       "grep -q 'archive-commit clean1 commit=.* pushed=yes lock_wait=' <<<\"\$out1\""
expect "AC1: built-prds/PRD-clean1.md carries Status: built" "grep -q '^- Status: built\$' '$D1/prds/built-prds/PRD-clean1.md'"
expect "AC1: built-prds/PRD-clean1.md carries a Built: line" "grep -q '^- Built: ' '$D1/prds/built-prds/PRD-clean1.md'"
expect "AC1: built-prds/PRD-clean1.md carries a Receipts: line" "grep -q '^- Receipts: ' '$D1/prds/built-prds/PRD-clean1.md'"
expect "AC1: build-queue/PRD-clean1.md is gone"             "[ ! -f '$D1/prds/build-queue/PRD-clean1.md' ]"
expect "AC1: MANIFEST.md line flipped to shipped"           "grep -q 'PRD-clean1.md — shipped' '$D1/prds/MANIFEST.md'"
expect "AC1: working tree is clean"                         "[ -z \"\$(git -C '$D1/prds' status --porcelain)\" ]"
# 3 = fixture init + add_queued_prd's "add clean1" + this one archive commit.
expect "AC1: exactly one new commit reached origin"         "[ \"\$(git -C '$D1/origin.git' log --oneline | wc -l)\" -eq 3 ]"
expect "AC1: origin's new commit is titled archive: clean1 shipped" "git -C '$D1/origin.git' log -1 --format=%s | grep -qx 'archive: clean1 shipped'"
files1="$(git -C "$D1/prds" show --name-only --format= HEAD)"
ac1_files_ok() {
  [ "$(wc -l <<<"$files1")" -eq 3 ] \
    && grep -qx 'MANIFEST.md' <<<"$files1" \
    && grep -qx 'build-queue/PRD-clean1.md' <<<"$files1" \
    && grep -qx 'built-prds/PRD-clean1.md' <<<"$files1"
}
expect "AC1: the archive commit contains all three changes"  "ac1_files_ok"

# ======================================================================
# AC2 — missing receipt refuses cleanly (real failure-mode case #1)
# ======================================================================
D2="$T/ac2"; mkdir -p "$D2"
DEFBR2="$(new_prd_fixture "$D2")"
add_queued_prd "$D2" "noreceipt" "$DEFBR2"
cat > "$D2/bmanifest.json" <<EOF
{"prds":{"noreceipt":{"slug":"noreceipt","receipts_dir":"$D2/no-such-receipts"}}}
EOF
head2_0="$(git -C "$D2/prds" rev-parse HEAD)"
out2="$(PRD_DIR="$D2/prds" BUILD_MANIFEST="$D2/bmanifest.json" "$AC" noreceipt 2>&1)"; rc2=$?
head2_1="$(git -C "$D2/prds" rev-parse HEAD)"
expect "AC2: exits non-zero"                                "[ $rc2 -ne 0 ]"
expect "AC2: names the receipt step"                        "grep -qi 'receipt' <<<\"\$out2\""
expect "AC2: working tree unchanged"                        "[ -z \"\$(git -C '$D2/prds' status --porcelain)\" ]"
expect "AC2: no new local commit"                            "[ '$head2_0' = '$head2_1' ]"
# 2 = fixture init + add_queued_prd's "add noreceipt"; the archive attempt
# must not add a third.
expect "AC2: origin got no new commit"                       "[ \"\$(git -C '$D2/origin.git' log --oneline | wc -l)\" -eq 2 ]"
expect "AC2: PRD still queued (untouched)"                   "grep -q '^- Status: queued\$' '$D2/prds/build-queue/PRD-noreceipt.md'"

# ======================================================================
# AC3 — lock contended: waits, then proceeds; lock_wait reflects it
# ======================================================================
D3="$T/ac3"; mkdir -p "$D3"
DEFBR3="$(new_prd_fixture "$D3")"
add_queued_prd "$D3" "waiter" "$DEFBR3"
mkdir -p "$D3/receipts"; echo r > "$D3/receipts/r.txt"
cat > "$D3/bmanifest.json" <<EOF
{"prds":{"waiter":{"slug":"waiter","receipts_dir":"$D3/receipts"}}}
EOF
( exec 9>"$D3/prds/.git/autobuilder-integrate.lock"; flock 9; sleep 5 ) &
holder3=$!
sleep 0.5
out3="$(PRD_DIR="$D3/prds" BUILD_MANIFEST="$D3/bmanifest.json" "$AC" waiter --lock-wait 30 2>&1)"; rc3=$?
wait "$holder3" 2>/dev/null
lockwait3="$(grep -o 'lock_wait=[0-9]*' <<<"$out3" | cut -d= -f2)"
expect "AC3: exits 0 after the holder releases"              "[ $rc3 -eq 0 ]"
expect "AC3: lock_wait is at least 4"                        "[ -n \"\$lockwait3\" ] && [ \"\$lockwait3\" -ge 4 ]"
expect "AC3: the archive still landed"                       "[ ! -f '$D3/prds/build-queue/PRD-waiter.md' ] && [ -f '$D3/prds/built-prds/PRD-waiter.md' ]"

# ======================================================================
# AC4 — lock held past the bound: times out, zero writes (failure-mode #2)
# ======================================================================
D4="$T/ac4"; mkdir -p "$D4"
DEFBR4="$(new_prd_fixture "$D4")"
add_queued_prd "$D4" "timeout" "$DEFBR4"
mkdir -p "$D4/receipts"; echo r > "$D4/receipts/r.txt"
cat > "$D4/bmanifest.json" <<EOF
{"prds":{"timeout":{"slug":"timeout","receipts_dir":"$D4/receipts"}}}
EOF
( exec 9>"$D4/prds/.git/autobuilder-integrate.lock"; flock 9; sleep 6 ) &
holder4=$!
sleep 0.5
head4_0="$(git -C "$D4/prds" rev-parse HEAD)"
out4="$(PRD_DIR="$D4/prds" BUILD_MANIFEST="$D4/bmanifest.json" "$AC" timeout --lock-wait 2 2>&1)"; rc4=$?
head4_1="$(git -C "$D4/prds" rev-parse HEAD)"
wait "$holder4" 2>/dev/null
expect "AC4: exits non-zero"                                 "[ $rc4 -ne 0 ]"
expect "AC4: names lock-timeout"                             "grep -q 'lock-timeout' <<<\"\$out4\""
expect "AC4: no writes (HEAD unchanged)"                      "[ '$head4_0' = '$head4_1' ]"
expect "AC4: working tree clean"                              "[ -z \"\$(git -C '$D4/prds' status --porcelain)\" ]"
expect "AC4: PRD still queued"                                "grep -q '^- Status: queued\$' '$D4/prds/build-queue/PRD-timeout.md'"

# ======================================================================
# AC5 — sibling's non-conflicting dirty file survives lane-claim's pull
# ======================================================================
D5="$T/ac5"; mkdir -p "$D5"
git init -q --bare "$D5/origin.git"
git clone -q "$D5/origin.git" "$D5/A"
mkdir -p "$D5/A/build-queue"
printf '# PRD: sib\n\n- Status: queued\n- build_target: shell\n' > "$D5/A/build-queue/PRD-sib.md"
printf '# PRD: other\n\n- Status: queued\n- build_target: shell\n' > "$D5/A/build-queue/PRD-other.md"
gc "$D5/A" add -A; gc "$D5/A" commit -qm init
defbr5="$(git -C "$D5/A" symbolic-ref --short HEAD)"
git -C "$D5/A" push -q origin "$defbr5"
git clone -q "$D5/origin.git" "$D5/B"
git -C "$D5/B" checkout -q "$defbr5"
printf '# PRD: newone\n\n- Status: queued\n- build_target: shell\n' > "$D5/B/build-queue/PRD-newone.md"
gc "$D5/B" add -A; gc "$D5/B" commit -qm "add newone"
git -C "$D5/B" push -q origin "$defbr5"
echo "- Note: sibling in-progress edit" >> "$D5/A/build-queue/PRD-other.md"
out5="$(bash "$LC" claim "$D5/A/build-queue/PRD-sib.md" testlane 2>&1)"; rc5=$?
expect "AC5: claim succeeds despite the dirty sibling file"   "[ $rc5 -eq 0 ]"
expect "AC5: claim message reports claimed"                   "grep -q '^claimed: sib' <<<\"\$out5\""
expect "AC5: sibling's own edit is still present afterwards"  "grep -q 'sibling in-progress edit' '$D5/A/build-queue/PRD-other.md'"
expect "AC5: sibling's edit stayed uncommitted (not swept in)" "git -C '$D5/A' status --porcelain -- build-queue/PRD-other.md | grep -q '^ M'"
expect "AC5: the incoming commit was pulled in"                "[ -f '$D5/A/build-queue/PRD-newone.md' ]"

# ======================================================================
# AC6 — sibling's CONFLICTING dirty file: restored, checkout-conflict
# (real failure-mode case #3 — this repo requires at least one, this
# selftest carries three: AC2, AC4, and this one)
# ======================================================================
D6="$T/ac6"; mkdir -p "$D6"
git init -q --bare "$D6/origin.git"
git clone -q "$D6/origin.git" "$D6/A"
mkdir -p "$D6/A/build-queue"
printf '# PRD: sib\n\n- Status: queued\n- build_target: shell\n' > "$D6/A/build-queue/PRD-sib.md"
printf 'line1\nline2\nline3\n' > "$D6/A/build-queue/PRD-other.md"
gc "$D6/A" add -A; gc "$D6/A" commit -qm init
defbr6="$(git -C "$D6/A" symbolic-ref --short HEAD)"
git -C "$D6/A" push -q origin "$defbr6"
git clone -q "$D6/origin.git" "$D6/B"
git -C "$D6/B" checkout -q "$defbr6"
printf 'line1\nCHANGED-BY-B\nline3\n' > "$D6/B/build-queue/PRD-other.md"
gc "$D6/B" add -A; gc "$D6/B" commit -qm "B changes other.md line2"
git -C "$D6/B" push -q origin "$defbr6"
printf 'line1\nCHANGED-BY-A\nline3\n' > "$D6/A/build-queue/PRD-other.md"
out6="$(bash "$LC" claim "$D6/A/build-queue/PRD-sib.md" testlane 2>&1)"; rc6=$?
expect "AC6: claim returns the busy exit code (2)"            "[ $rc6 -eq 2 ]"
expect "AC6: reason is checkout-conflict"                     "grep -q 'checkout-conflict' <<<\"\$out6\""
expect "AC6: no rebase left in progress"                       "[ ! -d '$D6/A/.git/rebase-apply' ] && [ ! -d '$D6/A/.git/rebase-merge' ]"
expect "AC6: no unmerged paths remain"                         "[ -z \"\$(git -C '$D6/A' diff --name-only --diff-filter=U)\" ]"
expect "AC6: sibling's edit is restored exactly, uncommitted"  "[ \"\$(cat '$D6/A/build-queue/PRD-other.md')\" = \"\$(printf 'line1\nCHANGED-BY-A\nline3\n')\" ] && git -C '$D6/A' status --porcelain -- build-queue/PRD-other.md | grep -q '^ M'"
expect "AC6: the claim never got written"                      "! grep -q 'Lane:' '$D6/A/build-queue/PRD-sib.md'"

# ======================================================================
# AC7 — SKILL.md's archive step names archive-commit.sh, no manual steps
# ======================================================================
SKILL_MD="$SKILL_DIR/SKILL.md"
# The archive bullet's action paragraph ends at the first blank line (the
# "Rebuild gate"/checklist prose that follows is a separate, much longer
# sub-section that legitimately mentions `Status: built` in an unrelated
# context — reality-check's Requirement 8 — so it must not be swept into
# this scope check).
archive_block="$(awk '/^- \*\*archive\*\*:/{p=1} p{print; if (/^$/) exit}' "$SKILL_MD")"
expect "AC7: SKILL.md archive step names archive-commit.sh"    "grep -q 'archive-commit.sh' <<<\"\$archive_block\""
expect "AC7: SKILL.md archive step has no git-mv instruction"  "! grep -q 'git mv' <<<\"\$archive_block\""
expect "AC7: SKILL.md archive step has no manual Status: edit" "! grep -qE '^- Status:|Status:.*built' <<<\"\$archive_block\""

echo "----"
echo "archive-commit-selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
