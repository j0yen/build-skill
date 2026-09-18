#!/usr/bin/env bash
# tests/rvblk_p0_acs.sh — PRD-build-reviewer-block-inherited-attribution,
# P0 ACs 1-6 plus P1 R7/AC9 (test_prefix rvblk).
#
# A reviewer block whose every reason restates an already-inherited
# receipt or a pre-branch commit must be attributed inherited, not
# in-scope (Grounding: burst-lane-gate-debt-2b2982e gate 14:24:13Z:
# inherited=1 in-scope=1, the in-scope block being the reviewer restating
# the SAME rollback-plan finding already attributed inherited).
#
# AC1-AC4 (resolution rules) and the attribution-merge/prompt-section
# helpers are exercised directly against the SHIPPED extend-gate.sh code
# (extracted by the "BEGIN/END rvblk-shared-helpers" marker and sourced —
# the same "prove the shipped code, not a transcription" convention
# tests/inhblocks_p0_acs.sh already uses for its own marker blocks) rather
# than reimplemented here.
#
# AC5 (unparsable reasons_csv leaves the block untouched) and AC6 (the
# reviewer prompt carries the inherited list) are exercised via a real
# `extend-gate.sh --scope branch` run through a disposable fixture crate
# (tests/fixtures/rvblk-fake/), never a real product.
#
# AC7 (every previously-green selftest stays green) is the responsibility
# of scripts/run-selftests.sh's own sweep, not this file.
# AC8 (Live, burst-lane-gate-debt-2b2982e's next real gate) is not
# exercised here — it needs a real authenticated gate to run; see the
# PRD's own AC8 evidence clause.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
EXTEND_GATE="$SKILL_DIR/scripts/extend-gate.sh"
GATE_ATTRIBUTION="$SKILL_DIR/scripts/gate-attribution.sh"
RVBLK_FAKE="$SKILL_DIR/tests/fixtures/rvblk-fake"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

# ---------------------------------------------------------------------
# Source the shipped resolution/prompt-section/attribution-merge helpers
# straight out of extend-gate.sh (BEGIN/END rvblk-shared-helpers marker).
# ---------------------------------------------------------------------
helpers_block="$(sed -n '/BEGIN rvblk-shared-helpers/,/END rvblk-shared-helpers/p' "$EXTEND_GATE")"
expect "helpers: rvblk-shared-helpers block is present in extend-gate.sh" \
  "[ -n \"\$helpers_block\" ]"
HELPERS_FILE="$(mktemp "${TMPDIR:-/tmp}/rvblk-helpers.XXXXXX.sh")"
printf '%s\n' "$helpers_block" > "$HELPERS_FILE"
GATE_ATTRIBUTION="$GATE_ATTRIBUTION"
# shellcheck source=/dev/null
source "$HELPERS_FILE"

T="$(mktemp -d "${TMPDIR:-/tmp}/rvblk-p0.XXXXXX")"
trap '[ -n "${RVBLK_KEEP:-}" ] || rm -rf "$T" "$HELPERS_FILE"' EXIT

# Fixture lineage: PRE -> BASE -> HEAD -> HEAD2, so PRE is an ancestor of
# BASE (pre-branch) and HEAD/HEAD2 are inside base..head (this branch's
# own commits) — the real burst-lane-gate-debt-2b2982e shape (guilty
# commit 31f733d pre-dates the branch base).
git init -q "$T/repo"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m pre
PRE="$(git -C "$T/repo" rev-parse HEAD)"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
BASE="$(git -C "$T/repo" rev-parse HEAD)"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m head
HEAD_C="$(git -C "$T/repo" rev-parse HEAD)"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m head2
HEAD2_C="$(git -C "$T/repo" rev-parse HEAD)"

INHERITED_JSON='[{"receipt":"rollback-plan","finding":"commits since v0.1.0 are not all revert-clean","commits":"'"$PRE"'"}]'

# --- AC1: a reason resolving to the inherited set (receipt-name AND ------
# ------- commit-ancestor match) is inherited, restated names the -------
# ------- receipt --------------------------------------------------------
reason_ac1="rollback-plan-commit-${PRE:0:7}-not-revert-clean"
out1="$(_reviewer_resolve_block_reasons "$T/repo" "$BASE" "$HEAD2_C" "$reason_ac1" "$INHERITED_JSON")"
expect "AC1: scope=inherited" \
  "[ \"\$(echo \"\$out1\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"scope\"])')\" = inherited ]"
expect "AC1: restated names the reason, new is empty" \
  "[ \"\$(echo \"\$out1\" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[\"restated\"]==[\"'\"\$reason_ac1\"'\"] and d[\"new\"]==[])')\" = True ]"
expect "AC1: restated_receipts names rollback-plan" \
  "[ \"\$(echo \"\$out1\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"restated_receipts\"])')\" = \"['rollback-plan']\" ]"

# attribution-merge half of AC1: the reviewer-agent block in a real
# attribution document flips to scope=inherited attribution=reviewer-
# restated, and in_scope/inherited recount.
attr_ac1='{"blocks":[{"receipt":"rollback-plan","scope":"inherited","attribution":"commit-range","commits":"'"$PRE"'"},{"receipt":"reviewer-agent","scope":"in-scope","finding":"decision=block reasons='"$reason_ac1"'","attribution":"unknown-inputs"}],"in_scope":1,"inherited":1}'
merged1="$(_reviewer_apply_resolution "$attr_ac1" "$out1")"
expect "AC1: merged attribution scope=inherited attribution=reviewer-restated" \
  "[ \"\$(echo \"\$merged1\" | python3 -c 'import json,sys;b=[x for x in json.load(sys.stdin)[\"blocks\"] if x[\"receipt\"]==\"reviewer-agent\"][0];print(b[\"scope\"],b.get(\"attribution\"))')\" = 'inherited reviewer-restated' ]"
expect "AC1: merged in_scope=0 inherited=2" \
  "[ \"\$(echo \"\$merged1\" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[\"in_scope\"],d[\"inherited\"])')\" = '0 2' ]"

# --- AC2: mixed reasons -> in-scope, restated/new split correctly -------
reason_new="tests-ac3-missing-assert"
reasons_ac2="${reason_ac1},${reason_new}"
out2="$(_reviewer_resolve_block_reasons "$T/repo" "$BASE" "$HEAD2_C" "$reasons_ac2" "$INHERITED_JSON")"
expect "AC2: scope=in-scope (mixed)" \
  "[ \"\$(echo \"\$out2\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"scope\"])')\" = in-scope ]"
expect "AC2: restated has the inherited reason, new has the other" \
  "[ \"\$(echo \"\$out2\" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[\"restated\"]==[\"'\"\$reason_ac1\"'\"] and d[\"new\"]==[\"'\"\$reason_new\"'\"])')\" = True ]"
merged2="$(_reviewer_apply_resolution "$attr_ac1" "$out2")"
expect "AC2: merged block scope=in-scope, no attribution key" \
  "[ \"\$(echo \"\$merged2\" | python3 -c 'import json,sys;b=[x for x in json.load(sys.stdin)[\"blocks\"] if x[\"receipt\"]==\"reviewer-agent\"][0];print(b[\"scope\"], \"attribution\" in b)')\" = 'in-scope False' ]"

# --- AC3: a reason naming a commit INSIDE base..head is in-scope, -------
# ------- regardless of a receipt name it also mentions ------------------
reason_ac3="rollback-plan-commit-${HEAD_C:0:7}-not-revert-clean"
out3="$(_reviewer_resolve_block_reasons "$T/repo" "$BASE" "$HEAD2_C" "$reason_ac3" "$INHERITED_JSON")"
expect "AC3: scope=in-scope despite the receipt-name match" \
  "[ \"\$(echo \"\$out3\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"scope\"])')\" = in-scope ]"
expect "AC3: restated is empty (the veto beat the receipt-name match)" \
  "[ \"\$(echo \"\$out3\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"restated\"])')\" = '[]' ]"

# --- AC4: a reason naming nothing resolvable -> in-scope, conservative --
out4="$(_reviewer_resolve_block_reasons "$T/repo" "$BASE" "$HEAD2_C" "$reason_new" "$INHERITED_JSON")"
expect "AC4: scope=in-scope" \
  "[ \"\$(echo \"\$out4\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"scope\"])')\" = in-scope ]"
expect "AC4: restated_receipts is empty (reviewer_restated_inherited=[])" \
  "[ \"\$(echo \"\$out4\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"restated_receipts\"])')\" = '[]' ]"

# --- prompt-section formatting: TWO inherited receipts, both listed -----
two_inherited='[{"receipt":"rollback-plan","finding":"not revert-clean","commits":"'"$PRE"'"},{"receipt":"intake","finding":"schema violation","commits":""}]'
section="$(_reviewer_inherited_prompt_section "$two_inherited")"
expect "prompt-section: header present" \
  "echo \"\$section\" | grep -q 'already attributed inherited'"
expect "prompt-section: names rollback-plan with its commit" \
  "echo \"\$section\" | grep -q \"receipt=rollback-plan commit=${PRE}\""
expect "prompt-section: names intake too (both receipts listed)" \
  "echo \"\$section\" | grep -q 'receipt=intake'"
expect "prompt-section: empty input -> empty output (no section grown)" \
  "[ -z \"\$(_reviewer_inherited_prompt_section '[]')\" ]"

# --- R7/AC9: reason-scoped baseline parity in gate-attribution.sh -------
git -C "$T/repo" -c user.email=t@t -c user.name=t tag v0.1.0 >/dev/null 2>&1 || true
mkdir -p "$T/repo/agent"
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[{"name":"reviewer-agent:%s"}]}\n' "$reason_ac1" \
  > "$T/repo/agent/gate-baseline.json"
git -C "$T/repo" add -A
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q -m baseline
BASE_COMMIT="$(git -C "$T/repo" rev-parse HEAD)"

ac9_run() { # $1 = receipt(relabelled) $2 = reasons body -> "scope|attribution"
  local receipt="$1" body="$2"
  printf '%s\t%s\n' "$receipt" "$body" > "$T/notes.tsv"
  "$GATE_ATTRIBUTION" compute "$T/repo" "$BASE_COMMIT" "$BASE_COMMIT" "$T/notes.tsv" 2>/dev/null \
    | python3 -c 'import json,sys; b=json.load(sys.stdin)["blocks"][0]; print(b["scope"], b.get("attribution",""), sep="|")'
}

ac9_hit="$(ac9_run "reviewer-agent:${reason_ac1}" "decision=block reasons=${reason_ac1}")"
expect "AC9: an exactly-matching reason-scoped baseline entry is inherited" \
  "[ \"\${ac9_hit%%|*}\" = inherited ]"
expect "AC9: the rescue is tagged baseline-witness" \
  "[ \"\${ac9_hit##*|}\" = baseline-witness ]"

ac9_miss="$(ac9_run "reviewer-agent:some-other-reason" "decision=block reasons=some-other-reason")"
expect "AC9: a DIFFERENT reviewer reason under the same reason-scoped baseline stays in-scope" \
  "[ \"\${ac9_miss%%|*}\" = in-scope ]"

# Blanket "reviewer-agent" baseline entry keeps its pre-existing meaning:
# it excuses every reason, not just one.
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[{"name":"reviewer-agent"}]}\n' \
  > "$T/repo/agent/gate-baseline.json"
git -C "$T/repo" add -A
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q -m blanket
ac9_blanket="$(ac9_run "reviewer-agent:anything-goes" "decision=block reasons=anything-goes")"
expect "AC9: a blanket reviewer-agent baseline entry still excuses every reason" \
  "[ \"\${ac9_blanket%%|*}\" = inherited ]"

# --- structural: R7's relabeling call site, and the journal/prompt -----
# ------- wiring are all present in the shipped script -------------------
expect "structural: note_block relabels the reviewer block's receipt name" \
  "grep -q 'note_block \"\${_reviewer_note_label} — decision=block' \"\$EXTEND_GATE\""
expect "structural: journal_suffix carries reviewer_restated_inherited=" \
  "grep -q 'journal_suffix reviewer_restated_inherited=' \"\$EXTEND_GATE\""
expect "structural: run_reviewer's prompt splices in the inherited section" \
  "grep -q '\\\${_reviewer_inherited_prompt_section_text:-}' \"\$EXTEND_GATE\""
expect "structural: the receipt on disk is patched with restated_inherited" \
  "grep -q 'restated_inherited: \\\$ri' \"\$EXTEND_GATE\""

# ---------------------------------------------------------------------
# AC5/AC6: a real --scope branch extend-gate.sh run through the rvblk-fake
# toolchain (autobuilder/gh/systemctl/... copied verbatim from revauth-
# fake, same lightweight no-real-cargo shape).
# ---------------------------------------------------------------------
rvblk_write_crate() {
  local repo="$1"
  mkdir -p "$repo/src"
  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "rvblk-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"
EOF
  cat > "$repo/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
  echo "/target" > "$repo/.gitignore"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=t -c user.email=t@t add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init
}

rvblk_run_gate() { # $1=repo $2=slug $3=prd-dir $4=journal [extra args...]
  local repo="$1" slug="$2" prd_dir="$3" journal="$4"; shift 4
  mkdir -p "$(dirname "$journal")" "$prd_dir/build-queue"
  cat > "$prd_dir/build-queue/PRD-$slug.md" <<EOF
# PRD: $slug -- disposable rvblk fixture PRD, never a real product
EOF
  local prompt="$(dirname "$journal")/reviewer-prompt.md"
  [ -f "$prompt" ] || cat > "$prompt" <<'EOF'
# fake reviewer prompt (rvblk fixture)
target/autobuilder/receipts/reviewer-agent.json is the deliverable.
EOF
  PATH="$RVBLK_FAKE:$PATH" \
  AUTOBUILDER_CANONICAL_CARGO_TOML="$(dirname "$journal")/no-such-canonical/Cargo.toml" \
  RUSTBUILD_SCRIPTS="$RVBLK_FAKE" \
  REVIEWER_PROMPT="$prompt" \
  EXTEND_GATE_JOURNAL="$journal" \
  BURST_LANE_SH="$RVBLK_FAKE/burst-lane.sh" \
  CARGO_BUDGET="$SKILL_DIR/tests/fixtures/gatephase-fake/cargo-budget.sh" \
  INTENT_CARD_REFRESH_BIN="$RVBLK_FAKE/intent-card-refresh.sh" \
  GATE_PATIENCE_PRD_DIR="$prd_dir" \
  BRANCH_GATE_PUSH=0 \
  FAKE_GH_AUTH_RC=0 \
  CLAUDE_CODE_OAUTH_TOKEN="rvblk-fixture-token" \
  bash "$EXTEND_GATE" "$repo" --scope branch --slug "$slug" --force "$@"
}

T6="$(mktemp -d "${TMPDIR:-/tmp}/rvblk-ac6.XXXXXX")"
trap '[ -n "${RVBLK_KEEP:-}" ] || rm -rf "$T" "$HELPERS_FILE" "$T6"' EXIT
REPO6="$T6/repo"
rvblk_write_crate "$REPO6"
# An inherited block BEFORE the reviewer runs: rollback-plan fails, and
# the receipt's producer is unmapped/pathless, so it fails closed to
# in-scope UNLESS the committed baseline witnesses it (AC11 mechanism,
# reused here only to manufacture a real inherited block — never
# reimplemented) — exactly the scope-computation path R4/AC6 needs to
# already have run once BEFORE reviewer-agent, for the prompt.
mkdir -p "$REPO6/agent"
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[{"name":"rollback-plan"}]}\n' \
  > "$REPO6/agent/gate-baseline.json"
git -C "$REPO6" add -A
git -C "$REPO6" -c user.name=t -c user.email=t@t commit -q -m baseline

PROMPT_CAPTURE="$T6/captured-prompt.txt"
JOURNAL6="$T6/journal.md"
out6="$(
  FAKE_ROLLBACK_PLAN_RC=1 FAKE_RVBLK_DECISION=pass FAKE_RVBLK_PROMPT_CAPTURE="$PROMPT_CAPTURE" \
  rvblk_run_gate "$REPO6" rvblk-ac6-slug "$T6/prds" "$JOURNAL6" 2>&1
)"
rc6=$?
echo "$out6" >&2
expect "AC6: extend-gate.sh ran the producer sequence (rc 0/1, never 9=incomplete)" \
  "[ $rc6 -eq 0 ] || [ $rc6 -eq 1 ]"
expect "AC6: the reviewer prompt was captured" "[ -s \"\$PROMPT_CAPTURE\" ]"
expect "AC6: the captured prompt carries the already-inherited section header" \
  "grep -q 'already attributed inherited' \"\$PROMPT_CAPTURE\""
expect "AC6: the captured prompt names rollback-plan (the pre-existing inherited block)" \
  "grep -q 'receipt=rollback-plan' \"\$PROMPT_CAPTURE\""
expect "AC6: the section instructs the reviewer not to block on these" \
  "grep -q 'do not block on' \"\$PROMPT_CAPTURE\""

# AC6 (second half): an armed reviewer-prompt-inject-once.json still wins
# the prompt-FILE choice — the inherited section still composes on top of
# whichever base prompt text was actually used.
T6B="$(mktemp -d "${TMPDIR:-/tmp}/rvblk-ac6b.XXXXXX")"
trap '[ -n "${RVBLK_KEEP:-}" ] || rm -rf "$T" "$HELPERS_FILE" "$T6" "$T6B"' EXIT
REPO6B="$T6B/repo"
rvblk_write_crate "$REPO6B"
mkdir -p "$REPO6B/agent"
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[{"name":"rollback-plan"}]}\n' \
  > "$REPO6B/agent/gate-baseline.json"
git -C "$REPO6B" add -A
git -C "$REPO6B" -c user.name=t -c user.email=t@t commit -q -m baseline

INJECT_FILE="$T6B/inject-once.json"
INJECTED_PROMPT="$T6B/injected-reviewer-prompt.md"
printf '# INJECTED MARKER PROMPT (rvblk AC6)\ntarget/autobuilder/receipts/reviewer-agent.json is the deliverable.\n' \
  > "$INJECTED_PROMPT"
python3 -c 'import json,sys; print(json.dumps({"slug_glob":"*","reviewer_prompt":sys.argv[1],"decision":"rvblk-ac6-test","armed_at":"2026-09-18T00:00:00Z"}))' \
  "$INJECTED_PROMPT" > "$INJECT_FILE"

PROMPT_CAPTURE_B="$T6B/captured-prompt.txt"
JOURNAL6B="$T6B/journal.md"
out6b="$(
  FAKE_ROLLBACK_PLAN_RC=1 FAKE_RVBLK_DECISION=pass FAKE_RVBLK_PROMPT_CAPTURE="$PROMPT_CAPTURE_B" \
  REVIEWER_PROMPT_INJECT_ONCE="$INJECT_FILE" \
  rvblk_run_gate "$REPO6B" rvblk-ac6b-slug "$T6B/prds" "$JOURNAL6B" 2>&1
)"
rc6b=$?
echo "$out6b" >&2
expect "AC6 (inject-once): still exit 0/1, never incomplete" \
  "[ $rc6b -eq 0 ] || [ $rc6b -eq 1 ]"
expect "AC6 (inject-once): the injected marker prompt text won" \
  "grep -q 'INJECTED MARKER PROMPT' \"\$PROMPT_CAPTURE_B\""
expect "AC6 (inject-once): the inherited section STILL composes on top of it" \
  "grep -q 'already attributed inherited' \"\$PROMPT_CAPTURE_B\""

# --- AC1 end-to-end: the reviewer actually BLOCKS, restating the SAME ---
# ------- rollback-plan finding already attributed inherited -- the -----
# ------- exact burst-lane-gate-debt-2b2982e shape (Grounding) -- must ---
# ------- land as verdict=delta-pass with the restatement named, not -----
# ------- re-enter the verdict as a second in-scope block -----------------
T6C="$(mktemp -d "${TMPDIR:-/tmp}/rvblk-ac1e2e.XXXXXX")"
trap '[ -n "${RVBLK_KEEP:-}" ] || rm -rf "$T" "$HELPERS_FILE" "$T6" "$T6B" "$T6C"' EXIT
REPO6C="$T6C/repo"
rvblk_write_crate "$REPO6C"
mkdir -p "$REPO6C/agent"
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[{"name":"rollback-plan"}]}\n' \
  > "$REPO6C/agent/gate-baseline.json"
git -C "$REPO6C" add -A
git -C "$REPO6C" -c user.name=t -c user.email=t@t commit -q -m baseline

JOURNAL6C="$T6C/journal.md"
out6c="$(
  FAKE_ROLLBACK_PLAN_RC=1 FAKE_RVBLK_DECISION=block \
  FAKE_RVBLK_BLOCK_REASONS="rollback-plan-not-revert-clean" \
  rvblk_run_gate "$REPO6C" rvblk-ac1e2e-slug "$T6C/prds" "$JOURNAL6C"
)"
rc6c=$?
echo "$out6c" >&2
expect "AC1 e2e: extend-gate.sh's own outcome reads verdict=delta-pass" \
  "printf '%s' \"\$out6c\" | grep -q 'delta verdict=delta-pass'"
expect "AC1 e2e: inherited_blocks names both rollback-plan and the now-inherited reviewer block" \
  "printf '%s' \"\$out6c\" | grep -q 'inherited_blocks=rollback-plan,reviewer-agent:rollback-plan-not-revert-clean\$'"
expect "AC1 e2e: exit 0 (delta-pass, not block)" "[ \$rc6c -eq 0 ]"
expect "AC1 e2e: journal line carries reviewer_restated_inherited=[rollback-plan]" \
  "grep -q 'reviewer_restated_inherited=\[rollback-plan\]' \"\$JOURNAL6C\""
expect "AC1 e2e: journal line carries in-scope=0 (the reviewer's own block never re-entered as in-scope)" \
  "grep -q 'in-scope=0' \"\$JOURNAL6C\""

# --- AC5 end-to-end: decision=block with an EMPTY block_reasons array ---
# ------- (the unparsable/no-reasons case) leaves the reviewer block -----
# ------- exactly as gate-attribution.sh's generic rule computed it — ----
# ------- bare "reviewer-agent" name, in-scope/unknown-inputs, no override
T6D="$(mktemp -d "${TMPDIR:-/tmp}/rvblk-ac5.XXXXXX")"
trap '[ -n "${RVBLK_KEEP:-}" ] || rm -rf "$T" "$HELPERS_FILE" "$T6" "$T6B" "$T6C" "$T6D"' EXIT
REPO6D="$T6D/repo"
rvblk_write_crate "$REPO6D"
mkdir -p "$REPO6D/agent"
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[{"name":"rollback-plan"}]}\n' \
  > "$REPO6D/agent/gate-baseline.json"
git -C "$REPO6D" add -A
git -C "$REPO6D" -c user.name=t -c user.email=t@t commit -q -m baseline

JOURNAL6D="$T6D/journal.md"
out6d="$(
  FAKE_ROLLBACK_PLAN_RC=1 FAKE_RVBLK_DECISION=block \
  rvblk_run_gate "$REPO6D" rvblk-ac5-slug "$T6D/prds" "$JOURNAL6D"
)"
rc6d=$?
echo "$out6d" >&2
expect "AC5: an empty block_reasons array still blocks (unchanged, no override applied)" \
  "printf '%s' \"\$out6d\" | grep -q 'delta verdict=block'"
expect "AC5: exit 1 (block, not delta-pass — the empty-reasons block stayed in-scope)" \
  "[ \$rc6d -eq 1 ]"
expect "AC5: the bare reviewer-agent name is untouched (no reason to relabel with)" \
  "printf '%s' \"\$out6d\" | grep -q 'new_blocks=reviewer-agent '"
expect "AC5: journal shows reviewer_restated_inherited=[] (nothing resolved, no reasons to resolve)" \
  "grep -q 'reviewer_restated_inherited=\[\]' \"\$JOURNAL6D\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "rvblk_p0_acs: ALL PASS"
else
  echo "rvblk_p0_acs: FAILED" >&2
fi
exit "$fail"
