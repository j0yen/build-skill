#!/usr/bin/env bash
# tests/gateinfra_ac13_head_after_intent_card_refresh.sh — PRD-build-gate-
# infra-outcome, regression test for the defect the AC13 live probe found
# (2026-09-17T21:28-21:46Z, real mcphost branch gate, slug
# gateinfra-live-probe, evidence receipt
# ~/brain/journal/build/receipts/2026-09-17-build-gate-infra-outcome-ac13-probe2.txt).
#
# What the probe showed: R1's `infra:` skip receipt WAS written (the reviewer
# phase ran and failed on a missing prompt, exactly as designed) and the
# journal line carried `infra=reviewer-agent` — but the gate still came out
# `block`, with `reviewer-agent` itself listed among the blockers. The receipt
# carried head_sha=f8f55dd while the gated head was 06cb1a4: the pre-gate
# intent-card refresh had COMMITTED a new card in between, and extend-gate.sh
# captured $head_now once, before that commit. A receipt stamped with the
# pre-refresh sha reads as stale to the aggregator, which counts it as a
# block — so `incomplete` was structurally unreachable on any live branch
# gate, because PRD-build-intent-card-pregate-refresh makes that mid-gate
# commit routine.
#
# Why the existing AC1 fixture did not catch it: it asserts only that the
# receipt HAS a head_sha, and its own gate run never commits mid-gate, so the
# stale value and the live value were the same string. This test makes the
# refresh phase commit (a stub INTENT_CARD_REFRESH_BIN that does exactly what
# the real one does — write a file and commit it) and then asserts the
# receipt's head_sha against the repo's ACTUAL head, which is the property
# the aggregator checks.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac13-head.XXXXXX")"
cleanup() { [ -n "${GATEINFRA_KEEP:-}" ] || rm -rf "$T"; }
trap cleanup EXIT

REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

SLUG="gateinfra-head-probe"

# A PRD file so extend-gate.sh's own readability check on
# <GATE_PATIENCE_PRD_DIR>/build-queue/PRD-<slug>.md passes and the refresh
# phase actually runs (a missing card is the prd-not-found path, which never
# reaches the commit this test is about).
mkdir -p "$T/prds/build-queue"
cat > "$T/prds/build-queue/PRD-$SLUG.md" <<EOF
# PRD — $SLUG (fixture)

- Status: queued
- build_target: rust-extend

## Acceptance criteria

1. P0 — Given a fixture, When it runs, Then it passes.
EOF

# Stub refresh: does what the real intent-card-refresh.sh does to the repo —
# writes its card and COMMITS it — and nothing else. Exits 0 (the "refreshed
# something" path).
STUB="$T/intent-card-refresh-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
repo="$1"
mkdir -p "$repo/agent"
printf '{"schema":"autobuilder.intent_card.v1","fixture":"%s"}\n' "$(date -u +%s%N)" > "$repo/agent/intent-card.json"
git -C "$repo" add -A -- agent/intent-card.json >/dev/null 2>&1
git -C "$repo" -c user.email=f@x -c user.name=f commit -q -m "intent-card: refresh (fixture)" -- agent/intent-card.json >/dev/null 2>&1
echo "fixture refresh committed"
exit 0
EOF
chmod +x "$STUB"

head_before="$(git -C "$REPO" rev-parse HEAD)"

echo "=== gate runs with a refresh phase that commits mid-gate ==="
export FAKE_REVCLAUDE_RC=1     # reviewer cannot run -> R1 writes the infra skip receipt
export FAKE_GH_AUTH_RC=0
out="$(INTENT_CARD_REFRESH_BIN="$STUB" \
       GATE_PATIENCE_PRD_DIR="$T/prds" \
       rvrcpt_run_gate "$REPO" "$JOURNAL" --scope branch --slug "$SLUG" 2>&1)"
rc=$?
unset FAKE_REVCLAUDE_RC FAKE_GH_AUTH_RC

head_after="$(git -C "$REPO" rev-parse HEAD)"
receipt="$REPO/target/autobuilder/receipts/reviewer-agent.json"

printf '%s\n' "$out" > "$T/gate-out.txt"

expect "the refresh phase actually moved HEAD (fixture precondition)" \
  "[ '$head_before' != '$head_after' ]"
expect "reviewer-agent infra receipt was written" "[ -f '$receipt' ]"
expect "receipt skip_reason starts infra:reviewer-agent:" \
  "[[ \"\$(jq -r '.skip_reason // empty' '$receipt' 2>/dev/null)\" == infra:reviewer-agent:* ]]"

# The property the aggregator actually checks, and the one the live probe
# found violated: the receipt describes the tree that was gated.
expect "receipt head_sha equals the gated head, not the pre-refresh head" \
  "[ \"\$(jq -r '.head_sha // empty' '$receipt' 2>/dev/null)\" = '$head_after' ]"
expect "receipt head_sha is NOT the pre-refresh head (the live defect)" \
  "[ \"\$(jq -r '.head_sha // empty' '$receipt' 2>/dev/null)\" != '$head_before' ]"

expect "journal records the head advance with its cause" \
  "grep -q 'head-advanced  (cause=intent-card-refresh' '$JOURNAL'"

if [ "$fail" -ne 0 ]; then
  echo "--- gate output (tail) ---" >&2
  tail -40 "$T/gate-out.txt" >&2
  echo "--- journal ---" >&2
  cat "$JOURNAL" >&2
  echo "gateinfra_ac13_head_after_intent_card_refresh: FAIL (rc=$rc)" >&2
  exit 1
fi
echo "gateinfra_ac13_head_after_intent_card_refresh: PASS (gate rc=$rc)"
