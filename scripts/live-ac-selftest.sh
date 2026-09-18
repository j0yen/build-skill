#!/usr/bin/env bash
# live-ac-selftest.sh — acceptance harness for the `(Live` AC marker
# (PRD-build-live-ac-no-defer). Hermetic: every fixture lives under a
# tempdir, never touches ~/Documents/PRDs, ~/.claude/skills/build/state, or
# ~/brain/journal. Run: bash scripts/live-ac-selftest.sh
#
# Coverage in THIS revision: R1 (marker + scan-prds.sh live_acs), R2
# (loop-tooling scope file), R3 (prd-lint.sh live-ac-deferred /
# live-ac-missing), R4 (verified-completed.sh --derive: a `(Live` AC pairs
# only with its own named evidence, never a fixture; deferred ->
# live-ac-deferred), R5 (archive-live-ac-refusal.sh: refuses + journals
# live-ac-unproven:<N> for an unproven `(Live` AC, goes silent once its
# evidence appears), R6 (live-ac-reality-check.sh: the built->shipped flip
# once a `(Live` AC's own evidence appears, and the LIVE_AC_MAX_WALL
# decision-open when it doesn't), R7/R8g (`(Real-box` wins over `(Live`
# when both are present, in both the lint layer AND the derive layer), and
# R9 (live-ac-report.sh: the one-time deferred-live/real/box report, never
# re-opening anything). That is PRD ACs 1, 2, 3, 4, 5, 6, 7, 8, 9.
#
# AC6/AC7 were blocked needs-user on this PRD's own open question
# (LIVE_AC_MAX_TICKS default 24 or a wall-clock bound?) until the Operator-
# note 2026-09-17T19:25Z (Joe: "6h") resolved it: a wall-clock bound,
# `LIVE_AC_MAX_WALL` (default 6h), replacing the tick count entirely. Both
# fixtures below use `LIVE_AC_MAX_WALL=60s` per the PRD's own AC7 wording.
# AC10's full-suite claim is asserted by run-selftests.sh wiring this file
# in, not by anything here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/prd-lint.sh"
SCAN="$HERE/scan-prds.sh"
VC="$HERE/verified-completed.sh"
ARCHIVE_REFUSAL="$HERE/archive-live-ac-refusal.sh"
REALITY_CHECK="$HERE/live-ac-reality-check.sh"
LOOP_TOOLING_REPOS_FILE="$HERE/loop-tooling-repos.txt"
export LOOP_TOOLING_REPOS_FILE

PASS=0; FAIL=0
ck() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1 -- $3"; FAIL=$((FAIL+1)); fi; }

mk_fixture_dir() {
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest.XXXXXX")"
  mkdir -p "$t/queue" "$t/visions"
  : > "$t/visions/x.md"
  printf '%s' "$t"
}

lint_json() { # <file>
  "$LINT" "$1" --format json 2>/dev/null
}
lint_ids() { # <file> <failures|warnings>
  lint_json "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)[0]
print(' '.join(x['id'] for x in d['$2']))
"
}

T="$(mk_fixture_dir)"

# ---- AC1: loop-tooling PRD defers a `(Live` AC -> live-ac-deferred, exit != 0 ----
f1="$T/queue/PRD-fixture-ac1.md"
cat > "$f1" <<'EOF'
# PRD: fixture-ac1

- Status: queued
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- Drafted: 2026-09-17
- Grounding: failure-derived
- deferred_acs: [3]
- mock_justifications: AC3 deferred for the fixture.
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
2. P0 — Given a thing, When it happens, Then it works.
3. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: journal:foo)
EOF
"$LINT" "$f1" >/dev/null 2>&1
rc1=$?
ids1="$(lint_ids "$f1" failures)"
ck "AC1: live-ac-deferred fires when a loop-tooling PRD defers its (Live AC" \
  '[[ "$ids1" == *live-ac-deferred* ]]' "ids: $ids1"
ck "AC1: prd-lint.sh exits non-zero on the deferred (Live AC" '[ "$rc1" -ne 0 ]' "rc=$rc1"

# ---- AC2: loop-tooling PRD, drafted today, no `(Live` AC -> live-ac-missing (fail) ----
f2a="$T/queue/PRD-fixture-ac2-new.md"
cat > "$f2a" <<'EOF'
# PRD: fixture-ac2-new

- Status: queued
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- Drafted: 2026-09-17
- Grounding: failure-derived
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
2. P0 — Given a thing, When it happens, Then it works.
EOF
ids2a="$(lint_ids "$f2a" failures)"
ck "AC2: live-ac-missing fails a loop-tooling PRD drafted 2026-09-17 with no (Live AC" \
  '[[ "$ids2a" == *live-ac-missing* ]]' "ids: $ids2a"

# Same PRD, Drafted 2026-09-01 -> warning only, exit 0 (modulo other checks).
f2b="$T/queue/PRD-fixture-ac2-old.md"
sed 's/Drafted: 2026-09-17/Drafted: 2026-09-01/; s/fixture-ac2-new/fixture-ac2-old/' "$f2a" > "$f2b"
ids2b_fail="$(lint_ids "$f2b" failures)"
ids2b_warn="$(lint_ids "$f2b" warnings)"
ck "AC2: an earlier-drafted PRD with no (Live AC gets a warning, not a failure" \
  '[[ "$ids2b_warn" == *live-ac-missing* && "$ids2b_fail" != *live-ac-missing* ]]' \
  "fails: $ids2b_fail warns: $ids2b_warn"

# ---- AC3: product PRD (build_into outside the loop-tooling list) defers a
# `(Live` AC -> no live-ac-* diagnostic at all ----
f3="$T/queue/PRD-fixture-ac3.md"
cat > "$f3" <<'EOF'
# PRD: fixture-ac3

- Status: queued
- build_target: shell
- build_into: /home/jsy/wintermute/mcphost
- Drafted: 2026-09-17
- Grounding: failure-derived
- deferred_acs: [3]
- mock_justifications: AC3 deferred for the fixture.
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
2. P0 — Given a thing, When it happens, Then it works.
3. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: journal:foo)
EOF
ids3="$(lint_ids "$f3" failures)$(lint_ids "$f3" warnings)"
ck "AC3: a product PRD deferring a (Live AC gets no live-ac-* diagnostic" \
  '[[ "$ids3" != *live-ac* ]]' "ids: $ids3"

# ---- AC4: verified-completed.sh --derive -- a `(Live` AC naming
# journal:<regex> pairs ONLY against that evidence, never a fixture tests/
# file whose name would otherwise pair it (a real `<prefix>_ac4_*.sh` file
# is planted here specifically to prove the fixture is ignored). Own
# hermetic repo + own loop-tooling-repos.txt scratch file (never the
# exported one above, which points at the real build-skill repo) so
# resolve_repo() sees a scratch tests/ dir, not this repo's own ----
T4="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest-ac4.XXXXXX")"
mkdir -p "$T4/repo/tests" "$T4/queue" "$T4/journal"
cat > "$T4/loop-tooling-repos.txt" <<EOF
$T4/repo
EOF
cat > "$T4/repo/tests/liveac_ac4_something.sh" <<'EOF'
echo fixture
EOF
f4="$T4/queue/PRD-fixture-ac4.md"
cat > "$f4" <<EOF
# PRD: fixture-ac4

- Status: queued
- build_target: shell
- build_into: $T4/repo
- test_prefix: liveac
- Drafted: 2026-09-17
- Grounding: failure-derived
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
2. P0 — Given a thing, When it happens, Then it works.
3. P0 — Given a thing, When it happens, Then it works.
4. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: journal:UNIQUE_TOKEN_XYZ)
EOF
cls4_before="$(LOOP_TOOLING_REPOS_FILE="$T4/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T4/journal" \
  "$VC" "$f4" --derive --format table 2>/dev/null | awk -F'\t' '$1==4{print $4}')"
ck "AC4: a fixture tests/ file never pairs a (Live AC (unproven before its own evidence exists)" \
  '[ "$cls4_before" = "live-ac-unproven" ]' "got: $cls4_before"

echo "2026-09-17T20:00:00Z  liveac  UNIQUE_TOKEN_XYZ  ok" > "$T4/journal/2026-09-17.md"
cls4_after="$(LOOP_TOOLING_REPOS_FILE="$T4/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T4/journal" \
  "$VC" "$f4" --derive --format table 2>/dev/null | awk -F'\t' '$1==4{print $4}')"
ck "AC4: the (Live AC pairs once its own named journal evidence exists" \
  '[ "$cls4_after" = "PAIRED" ]' "got: $cls4_after"

f4d="$T4/queue/PRD-fixture-ac4-deferred.md"
sed 's/^- Vision: x.md$/- deferred_acs: [4]\n- mock_justifications: AC4 deferred for the fixture.\n- Vision: x.md/; s/fixture-ac4/fixture-ac4-deferred/' "$f4" > "$f4d"
cls4d="$(LOOP_TOOLING_REPOS_FILE="$T4/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T4/journal" \
  "$VC" "$f4d" --derive --format table 2>/dev/null | awk -F'\t' '$1==4{print $4}')"
ck "AC4: verified-completed.sh reports a deferred (Live AC as live-ac-deferred, not DEFERRED" \
  '[ "$cls4d" = "live-ac-deferred" ]' "got: $cls4d"
rm -rf "$T4"

# ---- Regression (PRD-build-inherited-blocks-delta-pass, found 2026-09-18
# proving that PRD's own AC6): a backtick-quoted evidence spec that itself
# contains a paren group -- `journal:gate ... (pass|delta-pass|block) ...`
# -- was truncated at the FIRST ")" by the tag capture in
# verified-completed.sh, leaving one unterminated backtick, no quoted
# token to extract, and an empty spec that surfaced as the misleading
# "(no evidence: clause on the AC line)" for a clause that was in fact
# present and well-formed. Seven queued PRDs carry that shape. Assert both
# halves: the spec parses whole (unproven names the REAL regex, not the
# no-clause reason), and it still pairs once its evidence lands. ----
TP="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest-paren.XXXXXX")"
mkdir -p "$TP/repo/tests" "$TP/queue" "$TP/journal"
cat > "$TP/loop-tooling-repos.txt" <<EOF
$TP/repo
EOF
fp="$TP/queue/PRD-fixture-paren.md"
cat > "$fp" <<EOF
# PRD: fixture-paren

- Status: queued
- build_target: shell
- build_into: $TP/repo
- test_prefix: liveac
- Drafted: 2026-09-18
- Grounding: failure-derived
- Vision: x.md

## Acceptance criteria

1. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: \`journal:gate  PARENFIX-[a-z0-9-]+  (pass|delta-pass|block) .*inherited=[0-9]+\`)
EOF
run_vcp() {
  LOOP_TOOLING_REPOS_FILE="$TP/loop-tooling-repos.txt" VC_JOURNAL_DIR="$TP/journal" \
    "$VC" "$fp" 2>&1
}
outp_before="$(run_vcp)"
ck "paren-spec: the reason names the whole regex, paren group included" \
  '[[ "$outp_before" == *"evidence not found: journal:gate  PARENFIX-[a-z0-9-]+  (pass|delta-pass|block)"* ]]' \
  "out: $outp_before"
ck "paren-spec: the old no-clause misdiagnosis is gone" \
  '[[ "$outp_before" != *"no evidence: clause on the AC line"* ]]' "out: $outp_before"

echo "2026-09-18T00:00:00Z  gate  PARENFIX-fixture  delta-pass  (scope=branch) inherited=2 in-scope=0" \
  > "$TP/journal/2026-09-18.md"
clsp_after="$(LOOP_TOOLING_REPOS_FILE="$TP/loop-tooling-repos.txt" VC_JOURNAL_DIR="$TP/journal" \
  "$VC" "$fp" --derive --format table 2>/dev/null | awk -F'\t' '$1==1{print $4}')"
ck "paren-spec: pairs once a journal line matching the whole regex exists" \
  '[ "$clsp_after" = "PAIRED" ]' "got: $clsp_after"
rm -rf "$TP"

# ---- AC5: archive-live-ac-refusal.sh -- a `(Live` AC unproven refuses
# (exit 1), prints live-ac-unproven:<N>, and journals it; once the named
# evidence appears it goes silent (exit 0, nothing to refuse on live-ac-*
# grounds). Own hermetic repo + own loop-tooling-repos.txt scratch file,
# same isolation shape as AC4 ----
T5="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest-ac5.XXXXXX")"
mkdir -p "$T5/repo/tests" "$T5/queue" "$T5/journal"
cat > "$T5/loop-tooling-repos.txt" <<EOF
$T5/repo
EOF
f5="$T5/queue/PRD-fixture-ac5.md"
cat > "$f5" <<EOF
# PRD: fixture-ac5

- Status: built
- build_target: shell
- build_into: $T5/repo
- test_prefix: liveac
- Drafted: 2026-09-17
- Grounding: failure-derived
- Vision: x.md

## Acceptance criteria

1. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: journal:UNIQUE_TOKEN_AC5)
EOF
refusal5_before="$(LOOP_TOOLING_REPOS_FILE="$T5/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T5/journal" \
  ARCHIVE_LIVE_AC_JOURNAL="$T5/journal/refusal.md" "$ARCHIVE_REFUSAL" "$f5")"
rc5_before=$?
ck "AC5: archive-live-ac-refusal.sh refuses (exit 1) while the (Live AC is unproven" \
  '[ "$rc5_before" -eq 1 ]' "rc=$rc5_before"
ck "AC5: archive-live-ac-refusal.sh prints live-ac-unproven:1 on refusal" \
  '[ "$refusal5_before" = "live-ac-unproven:1" ]' "got: $refusal5_before"
ck "AC5: the refusal is journaled with live-ac-unproven:1" \
  'grep -q "fixture-ac5  archive  refuse (live-ac-unproven:1)" "$T5/journal/refusal.md" 2>/dev/null' \
  "journal: $(cat "$T5/journal/refusal.md" 2>/dev/null)"

echo "2026-09-17T20:05:00Z  liveac  UNIQUE_TOKEN_AC5  ok" > "$T5/journal/2026-09-17.md"
refusal5_after="$(LOOP_TOOLING_REPOS_FILE="$T5/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T5/journal" \
  ARCHIVE_LIVE_AC_JOURNAL="$T5/journal/refusal.md" "$ARCHIVE_REFUSAL" "$f5")"
rc5_after=$?
ck "AC5: archive-live-ac-refusal.sh goes silent (exit 0, no output) once the named evidence exists" \
  '[ "$rc5_after" -eq 0 ] && [ -z "$refusal5_after" ]' "rc=$rc5_after out=$refusal5_after"
rm -rf "$T5"

# ---- AC6: live-ac-reality-check.sh -- once the fixture journal gains the
# matching line, a `built` loop-tooling PRD's (Live AC pairs, the archive
# trailer's evidence is recorded, and the file moves build-queue ->
# built-prds with MANIFEST.md flipped to shipped. Needs a REAL (if
# throwaway) git checkout, same bare-origin/clone shape
# archive-commit-selftest.sh's own new_prd_fixture uses, so
# archive-commit.sh's atomic git-mv + push runs for real, hermetically ----
T6="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest-ac6.XXXXXX")"
gc6() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git init -q --bare "$T6/origin.git"
git clone -q "$T6/origin.git" "$T6/prds" 2>/dev/null
mkdir -p "$T6/prds/build-queue" "$T6/prds/built-prds" "$T6/repo/tests" "$T6/journal" "$T6/pending" "$T6/receipts"
printf '# MANIFEST\n\n## build-queue\n- PRD-fixture-ac6.md — built · shell · 2026-09-17\n\n## built-prds\n' > "$T6/prds/MANIFEST.md"
gc6 "$T6/prds" add -A
gc6 "$T6/prds" commit -qm init
defbr6="$(git -C "$T6/prds" symbolic-ref --short HEAD)"
git -C "$T6/prds" push -q origin "$defbr6"
cat > "$T6/loop-tooling-repos.txt" <<EOF
$T6/repo
EOF
echo receipt > "$T6/receipts/r.txt"
cat > "$T6/bmanifest.json" <<EOF
{"prds":{"fixture-ac6":{"slug":"fixture-ac6","receipts_dir":"$T6/receipts","gate":{"verdict":"pass"}}}}
EOF
f6="$T6/prds/build-queue/PRD-fixture-ac6.md"
cat > "$f6" <<EOF
# PRD: fixture-ac6

- Status: built
- build_target: shell
- build_into: $T6/repo
- test_prefix: liveac
- Drafted: 2026-09-17
- Grounding: failure-derived
- Vision: x.md

## Acceptance criteria

1. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: journal:UNIQUE_TOKEN_AC6)
EOF
gc6 "$T6/prds" add -A
gc6 "$T6/prds" commit -qm "add fixture-ac6"
git -C "$T6/prds" push -q origin "$defbr6"

run_rc6() { # <label of run>
  LOOP_TOOLING_REPOS_FILE="$T6/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T6/journal" \
    LIVE_AC_PENDING_DIR="$T6/pending" LIVE_AC_MAX_WALL=60s BUILD_JOURNAL_ROOT="$T6/journal" \
    PRD_DIR="$T6/prds" BUILD_MANIFEST="$T6/bmanifest.json" \
    "$REALITY_CHECK" check "$f6"
}
out6_before="$(run_rc6)"; rc6_before=$?
ck "AC6: still unproven -- reality check declines to ship (PRD stays in build-queue)" \
  '[ -f "$T6/prds/build-queue/PRD-fixture-ac6.md" ] && [ ! -f "$T6/prds/built-prds/PRD-fixture-ac6.md" ]' \
  "out: $out6_before rc=$rc6_before"

echo "2026-09-17T20:05:00Z  liveac  UNIQUE_TOKEN_AC6  ok" > "$T6/journal/2026-09-17.md"
out6_after="$(run_rc6)"; rc6_after=$?
ck "AC6: reality check exits 0 once the fixture journal line appears" '[ "$rc6_after" -eq 0 ]' "out: $out6_after"
ck "AC6: build-queue/PRD-fixture-ac6.md is gone (archived for real)" \
  '[ ! -f "$T6/prds/build-queue/PRD-fixture-ac6.md" ]' "listing: $(ls "$T6/prds/build-queue" 2>/dev/null)"
ck "AC6: built-prds/PRD-fixture-ac6.md exists" \
  '[ -f "$T6/prds/built-prds/PRD-fixture-ac6.md" ]' "listing: $(ls "$T6/prds/built-prds" 2>/dev/null)"
ck "AC6: the archived copy records the (Live AC's evidence path" \
  'grep -q "^- Live-AC-evidence: AC1: journal:" "$T6/prds/built-prds/PRD-fixture-ac6.md" 2>/dev/null' \
  "content: $(cat "$T6/prds/built-prds/PRD-fixture-ac6.md" 2>/dev/null)"
ck "AC6: MANIFEST.md's line for the slug flips to shipped" \
  'grep -q "PRD-fixture-ac6.md — shipped" "$T6/prds/MANIFEST.md"' "manifest: $(cat "$T6/prds/MANIFEST.md")"
ck "AC6: the pending-state file for the slug is cleaned up once shipped" \
  '[ ! -f "$T6/pending/fixture-ac6.json" ]' "listing: $(ls "$T6/pending" 2>/dev/null)"
rm -rf "$T6"

# ---- AC7: live-ac-reality-check.sh -- a `(Live` AC unproven for
# LIVE_AC_MAX_WALL (fixture: 60s, backdated so the very first check already
# trips it) opens exactly one decision naming the PRD, the AC number, and
# the missing evidence form; a second tick against the SAME still-missing
# evidence opens no second decision (decisions.sh's own idempotent-by-
# question-hash `open`) ----
T7="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest-ac7.XXXXXX")"
mkdir -p "$T7/repo/tests" "$T7/queue" "$T7/journal" "$T7/pending" "$T7/decisions"
cat > "$T7/loop-tooling-repos.txt" <<EOF
$T7/repo
EOF
f7="$T7/queue/PRD-fixture-ac7.md"
cat > "$f7" <<EOF
# PRD: fixture-ac7

- Status: built
- build_target: shell
- build_into: $T7/repo
- test_prefix: liveac
- Drafted: 2026-09-17
- Grounding: failure-derived
- Vision: x.md

## Acceptance criteria

1. P0 — Given a real loop, When it runs, Then it proves this. (Live; evidence: journal:UNIQUE_TOKEN_AC7)
EOF
run_rc7() {
  LOOP_TOOLING_REPOS_FILE="$T7/loop-tooling-repos.txt" VC_JOURNAL_DIR="$T7/journal" \
    LIVE_AC_PENDING_DIR="$T7/pending" LIVE_AC_MAX_WALL=60s BUILD_JOURNAL_ROOT="$T7/journal" \
    DECISIONS_FILE="$T7/decisions/decisions.jsonl" \
    "$REALITY_CHECK" check "$f7"
}
run_rc7 >/dev/null 2>&1
# Backdate first_seen_unproven_at well past LIVE_AC_MAX_WALL=60s so the
# NEXT check trips the bound -- the fixture equivalent of "3 ticks" the
# PRD's own AC7 prose names before the wall-clock rewrite.
python3 -c "
import json
f='$T7/pending/fixture-ac7.json'
d=json.load(open(f))
d['first_seen_unproven_at']='2020-01-01T00:00:00Z'
json.dump(d, open(f,'w'))
"
out7="$(run_rc7 2>&1)"
ck "AC7: after LIVE_AC_MAX_WALL, exactly one decision is opened" \
  '[ "$(wc -l < "$T7/decisions/decisions.jsonl" 2>/dev/null)" = 1 ]' \
  "out: $out7 file: $(cat "$T7/decisions/decisions.jsonl" 2>/dev/null)"
decision7="$(cat "$T7/decisions/decisions.jsonl" 2>/dev/null)"
ck "AC7: the decision names the PRD, AC1, and the missing evidence form" \
  '[[ "$decision7" == *"fixture-ac7"* && "$decision7" == *"AC1"* && "$decision7" == *"journal:UNIQUE_TOKEN_AC7"* ]]' \
  "decision: $decision7"
run_rc7 >/dev/null 2>&1
ck "AC7: a second tick against the same still-missing evidence opens no second decision" \
  '[ "$(wc -l < "$T7/decisions/decisions.jsonl" 2>/dev/null)" = 1 ]' \
  "file: $(cat "$T7/decisions/decisions.jsonl" 2>/dev/null)"
rm -rf "$T7"

# ---- AC8: an AC marked both `(Live` and `(Real-box`, deferred -> the
# `(Real-box` rule applies, no live-ac-* diagnostic emitted ----
f8="$T/queue/PRD-fixture-ac8.md"
cat > "$f8" <<'EOF'
# PRD: fixture-ac8

- Status: queued
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- Drafted: 2026-09-17
- Grounding: failure-derived
- deferred_acs: [3]
- mock_justifications: AC3 deferred; no box reachable.
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
2. P0 — Given a thing, When it happens, Then it works.
3. P0 — Given real hardware, When it runs, Then it proves this. (Real-box; deferrable only with a justification naming why no box was reachable. Also (Live in spirit.)
EOF
ids8="$(lint_ids "$f8" failures)$(lint_ids "$f8" warnings)"
ck "AC8: (Live + (Real-box on the same AC, deferred, raises no live-ac-* diagnostic" \
  '[[ "$ids8" != *live-ac* ]]' "ids: $ids8"

cls8="$("$VC" "$f8" --derive --format table 2>/dev/null | awk -F'\t' '$1==3{print $4}')"
ck "AC8: verified-completed.sh --derive classifies the same AC DEFERRED (the (Real-box rule), never live-ac-*" \
  '[ "$cls8" = "DEFERRED" ]' "got: $cls8"

# ---- AC9: live-ac-report.sh -- a hermetic scratch built-prds/ with one
# shipped loop-tooling PRD (block-list mock_justifications), one shipped
# loop-tooling PRD (inline mock_justifications, reason mentions "real"),
# one shipped loop-tooling PRD whose deferred AC's reason does NOT mention
# live/real/box (must be excluded), and one shipped PRODUCT PRD deferring
# a live-sounding AC (out of scope, must be excluded) ----
REPORT="$HERE/live-ac-report.sh"
T9="$(mktemp -d "${TMPDIR:-/tmp}/live-ac-selftest-ac9.XXXXXX")"
mkdir -p "$T9/built-prds"
cat > "$T9/loop-tooling-repos.txt" <<EOF
/home/jsy/wintermute/build-skill
EOF
cat > "$T9/built-prds/PRD-fixture-ac9-block.md" <<'EOF'
# PRD: fixture-ac9-block

- Status: built
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- deferred_acs: [5, 6]
- mock_justifications:
  - AC5 requires a live burst-lane box; none reachable this session.
  - AC6 covered by AC5's same real-hardware run.
- Vision: x.md

## Acceptance criteria

5. P0 — Given a thing, When it happens, Then it works.
6. P0 — Given a thing, When it happens, Then it works.
EOF
cat > "$T9/built-prds/PRD-fixture-ac9-inline.md" <<'EOF'
# PRD: fixture-ac9-inline

- Status: built
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- deferred_acs: [2]
- mock_justifications: AC2 needs a real box, deferred for the fixture.
- Vision: x.md

## Acceptance criteria

2. P0 — Given a thing, When it happens, Then it works.
EOF
cat > "$T9/built-prds/PRD-fixture-ac9-unrelated.md" <<'EOF'
# PRD: fixture-ac9-unrelated

- Status: built
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- deferred_acs: [1]
- mock_justifications: AC1 skipped -- low priority, revisit later.
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
EOF
cat > "$T9/built-prds/PRD-fixture-ac9-product.md" <<'EOF'
# PRD: fixture-ac9-product

- Status: built
- build_target: shell
- build_into: /home/jsy/wintermute/mcphost
- deferred_acs: [1]
- mock_justifications: AC1 needs a live real box, out of scope for this repo.
- Vision: x.md

## Acceptance criteria

1. P0 — Given a thing, When it happens, Then it works.
EOF
report_json="$(LOOP_TOOLING_REPOS_FILE="$T9/loop-tooling-repos.txt" PRD_DIR="$T9" "$REPORT" --format json 2>/dev/null)"
report_count="$(python3 -c "import json,sys; print(json.load(sys.stdin)['count'])" <<<"$report_json")"
ck "AC9: live-ac-report.sh finds exactly the 3 live/real/box-justified deferred ACs (block AC5+AC6, inline AC2), excludes the unrelated-reason and out-of-scope-repo ones" \
  '[ "$report_count" = 3 ]' "count=$report_count json=$report_json"
report_slugs="$(python3 -c "import json,sys; print(','.join(sorted(c['slug']+':'+str(c['ac']) for c in json.load(sys.stdin)['candidates'])))" <<<"$report_json")"
ck "AC9: report names slug+AC for each candidate (fixture-ac9-block:5, :6, fixture-ac9-inline:2)" \
  '[ "$report_slugs" = "fixture-ac9-block:5,fixture-ac9-block:6,fixture-ac9-inline:2" ]' "got: $report_slugs"
rm -rf "$T9"

# ---- Self-lint: this PRD's own file must not false-positive on its own
# prose (AC1-AC10 quote "`(Live`" in backticks describing the convention;
# only AC11's un-quoted trailing "(Live;" is the real tag) ----
SELF_PRD="$HOME/Documents/PRDs/build-queue/PRD-build-live-ac-no-defer.md"
if [ -f "$SELF_PRD" ]; then
  self_ids="$(lint_ids "$SELF_PRD" failures)$(lint_ids "$SELF_PRD" warnings)"
  ck "self-lint: this PRD's own file raises no live-ac-* diagnostic" \
    '[[ "$self_ids" != *live-ac* ]]' "ids: $self_ids"
  self_live_acs="$(PRD_DIR="$HOME/Documents/PRDs" "$SCAN" 2>/dev/null | python3 -c "
import json,sys
for d in json.load(sys.stdin):
    if d.get('slug') == 'build-live-ac-no-defer':
        print(d['live_acs'])
")"
  ck "self-scan: scan-prds.sh finds exactly AC11 as this PRD's own (Live AC" \
    '[ "$self_live_acs" = "[11]" ]' "got: $self_live_acs"
fi

rm -rf "$T"

# ---- Anti-orphan: every script this PRD ships must have a caller in the
# real loop's own contract files. live-ac-reality-check.sh was written,
# selftested green, and then reachable from NOTHING for a full day --
# SKILL.md and build-contract.md both said "the reality check" without
# naming it, and the only script by that name (reality-check.sh) has no
# `(Live` handling at all. A (Live mechanism that no caller ever runs is
# precisely the failure shape this whole PRD exists to prevent, so the
# wiring is asserted mechanically here rather than trusted to prose.
#
# PRD-build-branch-contract-split moved the coordinator's full phase
# procedure (where these two scripts are actually named) out of SKILL.md
# and into docs/operator.md -- SKILL.md is now a 200-line index with no
# per-script prose at all, so this check follows the content to its new
# home instead of the file it used to live in. ----
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
for doc in docs/operator.md build-contract.md; do
  ck "anti-orphan: $doc names scripts/live-ac-reality-check.sh as the (Live retry runner" \
    'grep -q "live-ac-reality-check.sh" "$REPO_ROOT/$doc"' \
    "$doc never names the runner -- the (Live built->shipped flip has no caller"
  ck "anti-orphan: $doc names scripts/archive-live-ac-refusal.sh as the archive refusal" \
    'grep -q "archive-live-ac-refusal.sh" "$REPO_ROOT/$doc"' \
    "$doc never names the archive refusal script"
done
# The two reality checks are distinct scripts; both contract files must say
# so out loud, because substituting one for the other is a silent no-op.
# (No backticks in these patterns -- ck evals its argument, so a backtick
# inside the pattern would be command-substituted, not matched.)
for doc in docs/operator.md build-contract.md; do
  ck "anti-orphan: $doc warns the two reality checks are not interchangeable" \
    'grep -q "do not substitute one for the other" "$REPO_ROOT/$doc"' \
    "$doc does not warn that reality-check.sh is the wrong script for (Live ACs"
done
# This suite must itself be reachable from the one selftest entrypoint,
# or a regression in any of the above is invisible to run-selftests.sh --all.
ck "anti-orphan: run-selftests.sh --all registry includes live-ac-selftest.sh" \
  'grep -q "scripts/live-ac-selftest.sh" "$REPO_ROOT/scripts/run-selftests.sh"' \
  "live-ac-selftest.sh is not in SELFTEST_REGISTRY"

echo "=== $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$FAIL"
