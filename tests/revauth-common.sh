#!/usr/bin/env bash
# tests/revauth-common.sh — shared fixture-building for revauth_ac*.sh
# (PRD-build-reviewer-agent-auth-contract, test_prefix revauth). Not a
# standalone test; `source`d by tests/revauth_ac*.sh files that need a
# real `extend-gate.sh --scope branch` run through tests/fixtures/
# revauth-fake/ — the same lightweight, no-real-cargo toolchain
# tests/fixtures/rvrcpt-fake/ uses (autobuilder/gh/ship-tag.sh/extended-
# receipts.sh/burst-lane.sh copied verbatim from there), plus this PRD's
# own auth-aware `claude` and `systemctl` doubles and a no-op
# intent-card-refresh.sh (so --scope branch's pre-gate refresh never
# marks the card stale and skips the reviewer, which every revauth test
# needs to actually run).
set -uo pipefail

REVAUTH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REVAUTH_EXTEND_GATE="$REVAUTH_REPO_ROOT/scripts/extend-gate.sh"
REVAUTH_FAKE="$REVAUTH_REPO_ROOT/tests/fixtures/revauth-fake"
REVAUTH_TOKEN="revauth-fixture-token-9f3c"

# revauth_write_fixture_crate <repo-dir> -- the disposable crate every
# revauth test gates against (never a real product, never mcphost).
revauth_write_fixture_crate() {
  local repo="$1"
  mkdir -p "$repo/src"
  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "revauth-fixture"
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

# revauth_run_gate <repo> <slug> <prd-dir> <journal> [extra extend-gate.sh
# args...] -- runs a real --scope branch extend-gate.sh through the
# revauth-fake toolchain. Every caller-exported FAKE_*/REVIEWER_AUTH_FILE/
# CLAUDE_CODE_OAUTH_TOKEN var is inherited from the calling shell -- this
# wrapper only pins the fixed plumbing every revauth test needs
# identically.
revauth_run_gate() {
  local repo="$1" slug="$2" prd_dir="$3" journal="$4"; shift 4
  mkdir -p "$(dirname "$journal")" "$prd_dir/build-queue"
  cat > "$prd_dir/build-queue/PRD-$slug.md" <<EOF
# PRD: $slug -- disposable revauth fixture PRD, never a real product
EOF
  local prompt="$(dirname "$journal")/reviewer-prompt.md"
  [ -f "$prompt" ] || cat > "$prompt" <<'EOF'
# fake reviewer prompt (revauth fixture)
target/autobuilder/receipts/reviewer-agent.json is the deliverable.
EOF
  PATH="$REVAUTH_FAKE:$PATH" \
  AUTOBUILDER_CANONICAL_CARGO_TOML="$(dirname "$journal")/no-such-canonical/Cargo.toml" \
  RUSTBUILD_SCRIPTS="$REVAUTH_FAKE" \
  REVIEWER_PROMPT="$prompt" \
  EXTEND_GATE_JOURNAL="$journal" \
  BURST_LANE_SH="$REVAUTH_FAKE/burst-lane.sh" \
  CARGO_BUDGET="$REVAUTH_REPO_ROOT/tests/fixtures/gatephase-fake/cargo-budget.sh" \
  INTENT_CARD_REFRESH_BIN="$REVAUTH_FAKE/intent-card-refresh.sh" \
  GATE_PATIENCE_PRD_DIR="$prd_dir" \
  BRANCH_GATE_PUSH=0 \
  FAKE_GH_AUTH_RC="${FAKE_GH_AUTH_RC:-0}" \
  bash "$REVAUTH_EXTEND_GATE" "$repo" --scope branch --slug "$slug" --force "$@"
}
