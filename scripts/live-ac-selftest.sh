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
# evidence appears), R7/R8g (`(Real-box` wins over `(Live` when both are
# present, in both the lint layer AND the derive layer), and R9
# (live-ac-report.sh: the one-time deferred-live/real/box report, never
# re-opening anything). That is PRD ACs 1, 2, 3, 4, 5, 8, 9.
# AC6/AC7 (the reality check's built->shipped flip and its
# LIVE_AC_MAX_TICKS decision-open) and AC10's full-suite claim remain
# follow-on chained steps, blocked needs-user on this PRD's own open
# question (LIVE_AC_MAX_TICKS default) -- NOT asserted here yet; the PRD
# stays `in_progress`, not `built`, until they land and this file grows
# their fixtures too. Never claim green on a rule that isn't wired.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/prd-lint.sh"
SCAN="$HERE/scan-prds.sh"
VC="$HERE/verified-completed.sh"
ARCHIVE_REFUSAL="$HERE/archive-live-ac-refusal.sh"
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

echo "=== $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$FAIL"
