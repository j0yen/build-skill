#!/usr/bin/env bash
# tests/cardpre_ac4_schema_block.sh — PRD-build-intent-card-pregate-
# refresh AC4: "Given the refreshed card fails autobuilder intake
# --validate, When the gate runs, Then the block is intent-card-stale
# (cause=schema)."
#
# intent-card-refresh.sh's own card-lint validation (exit 5) is what
# extend-gate.sh maps to cause=schema — reliably forcing a REAL card-lint
# failure would mean reverse-engineering card-lint.sh's exact rules, so
# this test instead substitutes INTENT_CARD_REFRESH_BIN with a fixture
# script that always exits 5 (extend-gate.sh's own overridable-for-tests
# convention, same as RUSTBUILD_SCRIPTS/EXTEND_GATE elsewhere in this
# repo) — the real script's OWN exit-5 contract is covered separately by
# docs/intent-card-schema.md's "failed card-lint.sh validation" behavior
# (unchanged by this PRD); this test's job is only extend-gate.sh's
# rc-to-cause mapping and the reviewer-skip that follows it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/cardpre-common.sh
source "$HERE/fixtures/cardpre-common.sh"

echo "=== AC4: refresh script exit 5 (card-lint failure) -> intent-card-stale (cause=schema) ==="

DIR="$(mktemp -d "${TMPDIR:-/tmp}/cardpre-ac4.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT

bgscope_write_fixture_crate "$DIR/repo"
bgscope_write_fakebin "$DIR/fakebin"
printf 'reviewer prompt for cardpre_ac4\n' > "$DIR/reviewer-prompt.md"

slug="cardpre-ac4-fixture"
mkdir -p "$DIR/prds/build-queue"
cardpre_write_prd "$DIR/prds/build-queue/PRD-$slug.md" "$slug" schemafail
jq -n --arg slug "$slug" --arg path "$DIR/prds/build-queue/PRD-$slug.md" \
  '{prds: {($slug): {path: $path}}}' > "$DIR/manifest.json"

wt="$(BUILD_TARGET_ROOT="$DIR/offroot" "$CARDPRE_WORKTREE_EXTEND" add "$DIR/repo" "$slug" 2>>"$DIR/setup.log")"

cat > "$DIR/fake-intent-card-refresh.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake-intent-card-refresh: simulated card-lint validation failure" >&2
exit 5
EOF
chmod +x "$DIR/fake-intent-card-refresh.sh"

head1="$(git -C "$wt" rev-parse HEAD)"
env \
  "PATH=$DIR/fakebin:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  "REAL_AUTOBUILDER_BIN=$BGSCOPE_REAL_AUTOBUILDER" \
  "RUSTBUILD_SCRIPTS=$DIR/fakebin" \
  "REVIEWER_PROMPT=$DIR/reviewer-prompt.md" \
  "CI_CHECKS_BRANCH_WAIT=3" "CI_CHECKS_BRANCH_POLL=1" "BRANCH_GATE_PUSH=1" \
  "BURST_LANE_SH=$CARDPRE_BURST_LANE_FAKE" \
  "EXTEND_GATE_JOURNAL=$DIR/journal.md" \
  "INTENT_CARD_REFRESH_MANIFEST=$DIR/manifest.json" \
  "GATE_PATIENCE_PRD_DIR=$DIR/prds" \
  "INTENT_CARD_REFRESH_BIN=$DIR/fake-intent-card-refresh.sh" \
  timeout -k 5 180 "$CARDPRE_EXTEND_GATE" "$wt" --head "$head1" --scope branch --slug "$slug" --force \
    >"$DIR/out.log" 2>&1
rc=$?
echo "  extend-gate.sh exit: $rc"

expect "block note names intent-card-stale (cause=schema)" \
  "grep -q 'intent-card-stale (cause=schema)' \"$DIR/out.log\""
expect "no reviewer-agent decision line (reviewer-agent skipped on a stale card)" \
  "! grep -q 'reviewer-agent — decision=' \"$DIR/out.log\""
target="$(readlink -f "$wt/target" 2>/dev/null || true)"
expect "no reviewer-agent.json receipt was written" \
  "[ ! -f \"$target/autobuilder/receipts/reviewer-agent.json\" ]"
expect "no intent-card commit was made (fake script never wrote a card)" \
  "! git -C \"$wt\" log --oneline | grep -q 'intent-card: refresh'"

echo "-----"
if [ "$cardpre_fail" -eq 0 ]; then echo "cardpre_ac4: ALL PASS"; else echo "cardpre_ac4: assertion(s) FAILED"; fi
exit "$cardpre_fail"
