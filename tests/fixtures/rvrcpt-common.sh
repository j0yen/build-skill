#!/usr/bin/env bash
# tests/fixtures/rvrcpt-common.sh — shared fixture-building for the
# rvrcpt_ac*.sh test files (PRD-build-reviewer-receipt-primary,
# test_prefix rvrcpt). Modeled directly on tests/fixtures/routepar-
# common.sh; `source`d by tests that need a real extend-gate.sh run
# against a disposable crate, through the fake toolchain at
# tests/fixtures/rvrcpt-fake/.
set -uo pipefail

RVRCPT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RVRCPT_EXTEND_GATE="$RVRCPT_REPO_ROOT/scripts/extend-gate.sh"
RVRCPT_FAKE="$RVRCPT_REPO_ROOT/tests/fixtures/rvrcpt-fake"

# rvrcpt_write_fixture_crate <repo-dir> — the disposable 2-file crate
# every rvrcpt test gates against (never a real product, never mcphost).
rvrcpt_write_fixture_crate() {
  local repo="$1"
  mkdir -p "$repo/src"
  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "rvrcpt-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"
EOF
  cat > "$repo/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
  echo "/target" > "$repo/.gitignore"
  git -C "$repo" init -q
  git -C "$repo" -c user.name=t -c user.email=t@t add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init
}

# rvrcpt_run_gate <repo> <journal-file> [extra extend-gate.sh args...]
# Every caller-exported FAKE_*/BUILD_BURST_ENABLED/BURST_LANE var is
# inherited from the calling shell — this wrapper only pins the fixed
# plumbing every rvrcpt test needs identically (fake toolchain on $PATH,
# fake RUSTBUILD_SCRIPTS, a nonexistent canonical Cargo.toml so the
# install-freshness guard no-ops, a real REVIEWER_PROMPT file containing
# this PRD's own R7 contract lines so AC7's own check has something real
# to read, the per-test journal file).
rvrcpt_run_gate() {
  local repo="$1" journal="$2"; shift 2
  mkdir -p "$(dirname "$journal")"
  local prompt="$(dirname "$journal")/reviewer-prompt.md"
  [ -f "$prompt" ] || cat > "$prompt" <<'EOF'
# fake reviewer prompt (rvrcpt fixture)
target/autobuilder/receipts/reviewer-agent.json is the deliverable.
final message is the receipt JSON alone.
no background or parallel agents.
EOF
  PATH="$RVRCPT_FAKE:$PATH" \
  AUTOBUILDER_CANONICAL_CARGO_TOML="$(dirname "$journal")/no-such-canonical/Cargo.toml" \
  RUSTBUILD_SCRIPTS="$RVRCPT_FAKE" \
  REVIEWER_PROMPT="$prompt" \
  EXTEND_GATE_JOURNAL="$journal" \
  BURST_LANE_SH="$RVRCPT_FAKE/burst-lane.sh" \
  CARGO_BUDGET="$RVRCPT_REPO_ROOT/tests/fixtures/gatephase-fake/cargo-budget.sh" \
  FAKE_GH_AUTH_RC="${FAKE_GH_AUTH_RC:-0}" \
  bash "$RVRCPT_EXTEND_GATE" "$repo" --force "$@"
}
