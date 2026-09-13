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
# PRD-build-archive-manifest-backfill (test_prefix `manbackfill`) extends
# this same suite rather than duplicating it — `tests/manbackfill_ac<N>_*.sh`
# wrappers (via tests/fixtures/manbackfill-ac-common.sh) pull labels
# prefixed `MANBACKFILL AC<N>:` out of this same run, one per that PRD's
# own numbered acceptance criteria:
#   MANBACKFILL AC1 — no MANIFEST.md line exists for the slug: one is
#         appended to the built-prds section, flipped to shipped, rc=0,
#         and the journal names the backfill.
#   MANBACKFILL AC2 — that backfilled line matches a sibling entry's exact
#         format (field order/separators), and the commit message names
#         the backfill.
#   MANBACKFILL AC3 — a line already exists for the slug: no backfill
#         occurs, it's flipped as today, and no manifest-backfill line is
#         journaled.
#   MANBACKFILL AC4 — two conflicting lines exist for the same slug: dies
#         with a distinct exit code (not 4), naming the duplicate (real
#         failure-mode case).
#   MANBACKFILL AC5 — MANIFEST.md is unreadable: dies with exit 4, as
#         before this PRD (real failure-mode case).
#   MANBACKFILL AC6 — a slug already backfilled and flipped by a prior run:
#         re-running is a no-op, exit 0, no second line or commit.
#   MANBACKFILL AC7 — the backfill and flip land in the same commit that
#         a sibling's push/pull-rebase must still survive (lock/commit
#         ordering, mirrors AC5 above for the base atomic-commit feature).
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

# ---- helpers added for PRD-build-archive-manifest-backfill (manbackfill) ----

# Add a queued PRD $2 (slug) to fixture $1 WITHOUT a MANIFEST.md line — the
# exact shape this PRD exists to handle (a hand-queued PRD /dream never
# reconciled). Carries a Drafted: date + build_target so a backfilled line
# has real fields to source, not "?".
add_queued_prd_no_manifest_line() {
  local d="$1" slug="$2" defbr="$3" target="${4:-shell}" drafted="${5:-2026-09-13}"
  printf '# PRD: %s\n\n- Status: queued\n- build_target: %s\n- build_into: /tmp/nowhere-%s\n- Drafted: %s\n' \
    "$slug" "$target" "$slug" "$drafted" > "$d/prds/build-queue/PRD-$slug.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add $slug"
  git -C "$d/prds" push -q origin "$defbr"
}

# Append one full sibling entry to fixture $1's "## built-prds" section (so
# a backfill has a real sibling to derive its format from) and push.
add_built_prds_sibling() {
  local d="$1" defbr="$2" sib_slug="${3:-sibling-existing}"
  python3 - "$d/prds/MANIFEST.md" "$sib_slug" <<'PY'
import sys
f, sib_slug = sys.argv[1], sys.argv[2]
with open(f) as fh: c = fh.read()
c = c.replace("## built-prds\n", f"## built-prds\n- PRD-{sib_slug}.md — built · rust-extend · 2026-09-01\n")
with open(f, 'w') as fh: fh.write(c)
PY
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add sibling $sib_slug manifest line"
  git -C "$d/prds" push -q origin "$defbr"
}

# Write TWO conflicting MANIFEST.md lines for the same slug $3 directly
# (malformed real corruption, not the "absent" case) and push.
add_duplicate_manifest_lines() {
  local d="$1" defbr="$2" slug="$3"
  python3 - "$d/prds/MANIFEST.md" "$slug" <<'PY'
import sys
f, slug = sys.argv[1], sys.argv[2]
with open(f) as fh: c = fh.read()
extra = f"- PRD-{slug}.md — queued · shell · 2026-09-01\n- PRD-{slug}.md — blocked · shell · 2026-09-02\n"
c = c.replace("## built-prds\n", "## built-prds\n" + extra)
with open(f, 'w') as fh: fh.write(c)
PY
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add duplicate $slug manifest lines"
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

# ======================================================================
# MANBACKFILL AC1/AC2 — no MANIFEST.md line for the slug: backfilled into
# built-prds, matching a sibling's format, flipped to shipped, journaled,
# named in the commit message.
# ======================================================================
D8="$T/mb1"; mkdir -p "$D8"
DEFBR8="$(new_prd_fixture "$D8")"
add_built_prds_sibling "$D8" "$DEFBR8" "siborig"
add_queued_prd_no_manifest_line "$D8" "mbfill1" "$DEFBR8" "shell" "2026-09-13"
mkdir -p "$D8/receipts"; echo r > "$D8/receipts/r.txt"
cat > "$D8/bmanifest.json" <<EOF
{"prds":{"mbfill1":{"slug":"mbfill1","receipts_dir":"$D8/receipts"}}}
EOF
out8="$(PRD_DIR="$D8/prds" BUILD_MANIFEST="$D8/bmanifest.json" "$AC" mbfill1 2>&1)"; rc8=$?
expect "MANBACKFILL AC1: archive-commit exits 0"                  "[ $rc8 -eq 0 ]"
expect "MANBACKFILL AC1: build-queue/PRD-mbfill1.md is gone"      "[ ! -f '$D8/prds/build-queue/PRD-mbfill1.md' ]"
expect "MANBACKFILL AC1: built-prds/PRD-mbfill1.md exists"        "[ -f '$D8/prds/built-prds/PRD-mbfill1.md' ]"
expect "MANBACKFILL AC1: a shipped line now exists for mbfill1"   "grep -q '^- PRD-mbfill1.md — shipped ' '$D8/prds/MANIFEST.md'"
built_prds_block8="$(awk '/^## built-prds/{p=1} p{print} /^## parked/{exit}' "$D8/prds/MANIFEST.md")"
expect "MANBACKFILL AC1: backfilled line lands in built-prds section" "grep -q 'PRD-mbfill1.md — shipped' <<<\"\$built_prds_block8\""
expect "MANBACKFILL AC1: journal names the backfill"              "grep -q 'manifest-backfill (slug=mbfill1 section=built-prds' <<<\"\$out8\""
# AC2: the backfilled line's separators match the sibling's exactly.
expect "MANBACKFILL AC2: backfilled line matches sibling's exact format" \
  "grep -qxF -- '- PRD-mbfill1.md — shipped · shell · 2026-09-13' '$D8/prds/MANIFEST.md'"
commit_msg8="$(git -C "$D8/prds" log -1 --format=%B)"
expect "MANBACKFILL AC2: commit message names the backfill"       "grep -q 'manifest-backfill: appended MANIFEST.md line for mbfill1' <<<\"\$commit_msg8\""
expect "MANBACKFILL AC2: commit subject is unchanged by the backfill note" \
  "git -C '$D8/prds' log -1 --format=%s | grep -qx 'archive: mbfill1 shipped'"

# ======================================================================
# MANBACKFILL AC3 — a line already exists for the slug: flipped as today,
# no backfill occurs, nothing is journaled.
# ======================================================================
D9="$T/mb3"; mkdir -p "$D9"
DEFBR9="$(new_prd_fixture "$D9")"
add_queued_prd "$D9" "mbexist" "$DEFBR9"
mkdir -p "$D9/receipts"; echo r > "$D9/receipts/r.txt"
cat > "$D9/bmanifest.json" <<EOF
{"prds":{"mbexist":{"slug":"mbexist","receipts_dir":"$D9/receipts"}}}
EOF
out9="$(PRD_DIR="$D9/prds" BUILD_MANIFEST="$D9/bmanifest.json" "$AC" mbexist 2>&1)"; rc9=$?
expect "MANBACKFILL AC3: archive-commit exits 0"                  "[ $rc9 -eq 0 ]"
expect "MANBACKFILL AC3: existing line flipped to shipped"        "grep -q 'PRD-mbexist.md — shipped' '$D9/prds/MANIFEST.md'"
expect "MANBACKFILL AC3: exactly one line for the slug (no dup appended)" \
  "[ \"\$(grep -c 'PRD-mbexist.md' '$D9/prds/MANIFEST.md')\" -eq 1 ]"
expect "MANBACKFILL AC3: no manifest-backfill line journaled"     "! grep -q 'manifest-backfill' <<<\"\$out9\""
commit_msg9="$(git -C "$D9/prds" log -1 --format=%B)"
expect "MANBACKFILL AC3: commit message has no backfill note"     "! grep -q 'manifest-backfill:' <<<\"\$commit_msg9\""

# ======================================================================
# MANBACKFILL AC4 — two conflicting lines for the same slug: real
# corruption, dies with a distinct exit code (not 4), names the duplicate,
# zero writes (required real failure-mode case).
# ======================================================================
D10="$T/mb4"; mkdir -p "$D10"
DEFBR10="$(new_prd_fixture "$D10")"
add_duplicate_manifest_lines "$D10" "$DEFBR10" "mbdup"
add_queued_prd_no_manifest_line "$D10" "mbdup" "$DEFBR10"
mkdir -p "$D10/receipts"; echo r > "$D10/receipts/r.txt"
cat > "$D10/bmanifest.json" <<EOF
{"prds":{"mbdup":{"slug":"mbdup","receipts_dir":"$D10/receipts"}}}
EOF
head10_0="$(git -C "$D10/prds" rev-parse HEAD)"
out10="$(PRD_DIR="$D10/prds" BUILD_MANIFEST="$D10/bmanifest.json" "$AC" mbdup 2>&1)"; rc10=$?
head10_1="$(git -C "$D10/prds" rev-parse HEAD)"
expect "MANBACKFILL AC4: exits non-zero"                          "[ $rc10 -ne 0 ]"
expect "MANBACKFILL AC4: exit code is distinct from 4"            "[ $rc10 -ne 4 ]"
expect "MANBACKFILL AC4: names the duplicate"                     "grep -qi 'duplicate' <<<\"\$out10\""
expect "MANBACKFILL AC4: no writes (HEAD unchanged)"              "[ '$head10_0' = '$head10_1' ]"
expect "MANBACKFILL AC4: working tree clean"                      "[ -z \"\$(git -C '$D10/prds' status --porcelain)\" ]"
expect "MANBACKFILL AC4: PRD still queued (untouched)"            "grep -q '^- Status: queued\$' '$D10/prds/build-queue/PRD-mbdup.md'"

# ======================================================================
# MANBACKFILL AC5 — MANIFEST.md unreadable: dies exit 4, as before this
# PRD (real failure-mode case; the required OTHER failure mode).
# ======================================================================
D11="$T/mb5"; mkdir -p "$D11"
DEFBR11="$(new_prd_fixture "$D11")"
add_queued_prd_no_manifest_line "$D11" "mbunread" "$DEFBR11"
mkdir -p "$D11/receipts"; echo r > "$D11/receipts/r.txt"
cat > "$D11/bmanifest.json" <<EOF
{"prds":{"mbunread":{"slug":"mbunread","receipts_dir":"$D11/receipts"}}}
EOF
chmod 000 "$D11/prds/MANIFEST.md"
out11="$(PRD_DIR="$D11/prds" BUILD_MANIFEST="$D11/bmanifest.json" "$AC" mbunread 2>&1)"; rc11=$?
chmod 644 "$D11/prds/MANIFEST.md"
expect "MANBACKFILL AC5: exits with code 4"                       "[ $rc11 -eq 4 ]"
expect "MANBACKFILL AC5: PRD still queued (untouched)"            "grep -q '^- Status: queued\$' '$D11/prds/build-queue/PRD-mbunread.md'"

# ======================================================================
# MANBACKFILL AC6 — idempotence: a slug already backfilled and flipped by
# a prior run; re-running is a no-op (exit 0, no second line, no second
# commit).
# ======================================================================
D12="$T/mb6"; mkdir -p "$D12"
DEFBR12="$(new_prd_fixture "$D12")"
add_built_prds_sibling "$D12" "$DEFBR12" "siborig2"
add_queued_prd_no_manifest_line "$D12" "mbidem" "$DEFBR12"
mkdir -p "$D12/receipts"; echo r > "$D12/receipts/r.txt"
cat > "$D12/bmanifest.json" <<EOF
{"prds":{"mbidem":{"slug":"mbidem","receipts_dir":"$D12/receipts"}}}
EOF
PRD_DIR="$D12/prds" BUILD_MANIFEST="$D12/bmanifest.json" "$AC" mbidem >/dev/null 2>&1
head12_after1="$(git -C "$D12/origin.git" rev-parse HEAD)"
out12b="$(PRD_DIR="$D12/prds" BUILD_MANIFEST="$D12/bmanifest.json" "$AC" mbidem 2>&1)"; rc12b=$?
head12_after2="$(git -C "$D12/origin.git" rev-parse HEAD)"
expect "MANBACKFILL AC6: re-run exits 0"                          "[ $rc12b -eq 0 ]"
expect "MANBACKFILL AC6: re-run adds no new commit"               "[ '$head12_after1' = '$head12_after2' ]"
expect "MANBACKFILL AC6: exactly one line for the slug (no dup)"  "[ \"\$(grep -c 'PRD-mbidem.md' '$D12/prds/MANIFEST.md')\" -eq 1 ]"

# ======================================================================
# MANBACKFILL AC7 — the backfill + flip land in the same commit, which
# must still survive a sibling tick's own concurrent push (lock/commit
# ordering fixture proof, P1).
# ======================================================================
D13="$T/mb7"; mkdir -p "$D13"
DEFBR13="$(new_prd_fixture "$D13")"
add_built_prds_sibling "$D13" "$DEFBR13" "siborig3"
add_queued_prd_no_manifest_line "$D13" "mbrace" "$DEFBR13"
mkdir -p "$D13/receipts"; echo r > "$D13/receipts/r.txt"
cat > "$D13/bmanifest.json" <<EOF
{"prds":{"mbrace":{"slug":"mbrace","receipts_dir":"$D13/receipts"}}}
EOF
# Sibling tick: an independent clone pushes an unrelated commit to origin
# before archive-commit runs, so archive-commit's own post-commit
# `git pull --rebase --autostash` has real upstream history to land on.
git clone -q "$D13/origin.git" "$D13/sibling-clone" 2>/dev/null
printf '# PRD: siblingrace\n\n- Status: queued\n- build_target: shell\n' > "$D13/sibling-clone/build-queue/PRD-siblingrace.md"
gc "$D13/sibling-clone" add -A
gc "$D13/sibling-clone" commit -qm "sibling: add siblingrace"
git -C "$D13/sibling-clone" push -q origin "$DEFBR13"
out13="$(PRD_DIR="$D13/prds" BUILD_MANIFEST="$D13/bmanifest.json" "$AC" mbrace 2>&1)"; rc13=$?
expect "MANBACKFILL AC7: archive-commit exits 0"                  "[ $rc13 -eq 0 ]"
expect "MANBACKFILL AC7: sibling's commit is present on origin"  "git -C '$D13/origin.git' log --oneline --all | grep -q 'sibling: add siblingrace'"
expect "MANBACKFILL AC7: our archive commit is present on origin" "git -C '$D13/origin.git' log --oneline --all | grep -q 'archive: mbrace shipped'"
expect "MANBACKFILL AC7: backfill + flip survived the rebase"    "grep -q 'PRD-mbrace.md — shipped' '$D13/prds/MANIFEST.md'"
expect "MANBACKFILL AC7: sibling's pulled-in file is present"    "[ -f '$D13/prds/build-queue/PRD-siblingrace.md' ]"
expect "MANBACKFILL AC7: working tree is clean"                  "[ -z \"\$(git -C '$D13/prds' status --porcelain)\" ]"

echo "----"
echo "archive-commit-selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
