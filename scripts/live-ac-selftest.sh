#!/usr/bin/env bash
# live-ac-selftest.sh — acceptance harness for the `(Live` AC marker
# (PRD-build-live-ac-no-defer). Hermetic: every fixture lives under a
# tempdir, never touches ~/Documents/PRDs, ~/.claude/skills/build/state, or
# ~/brain/journal. Run: bash scripts/live-ac-selftest.sh
#
# Coverage in THIS revision: the lint-layer requirements landed so far --
# R1 (marker + scan-prds.sh live_acs), R2 (loop-tooling scope file), R3
# (prd-lint.sh live-ac-deferred / live-ac-missing), and R7/R8g (`(Real-box`
# wins over `(Live` when both are present). That is PRD ACs 1, 2, 3, 8.
# ACs 4-7 (verified-completed.sh pairing, archive refusal, the reality
# check) and AC9/AC10's full-suite claim are follow-on chained steps --
# NOT asserted here yet; the PRD stays `building`, not `built`, until they
# land and this file grows their fixtures too. Never claim green on a rule
# that isn't wired.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/prd-lint.sh"
SCAN="$HERE/scan-prds.sh"
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
