#!/usr/bin/env bash
# tests/fixtures/routepar-common.sh — shared fixture-building for the
# routepar_ac*.sh test files (PRD-build-gate-route-parity-ledger). Not a
# standalone test; `source`d by tests/routepar_ac*.sh files that need a
# real `extend-gate.sh` run against a disposable crate, through the fake
# toolchain at tests/fixtures/routepar-fake/ (autobuilder/claude/gh/
# extended-receipts.sh/burst-lane.sh/ship-tag.sh — every subcommand
# independently scriptable via env vars, and unlike tests/fixtures/
# gatephase-fake/, this one's autobuilder fake actually WRITES a receipt
# JSON per producer, since this PRD's own tests need something on disk to
# stamp `.route` onto).
set -uo pipefail

ROUTEPAR_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ROUTEPAR_EXTEND_GATE="$ROUTEPAR_REPO_ROOT/scripts/extend-gate.sh"
ROUTEPAR_FAKE="$ROUTEPAR_REPO_ROOT/tests/fixtures/routepar-fake"

# routepar_write_fixture_crate <repo-dir> — the disposable 2-file crate
# every routepar test gates against (never a real product, never mcphost).
routepar_write_fixture_crate() {
  local repo="$1"
  mkdir -p "$repo/src"
  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "routepar-fixture"
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

# routepar_run_gate <repo> <journal-file> [extra extend-gate.sh args...]
# Every caller-exported FAKE_*/CARGO_ROUTE_STATUS_JSON/BUILD_BURST_ENABLED/
# BURST_LANE var is inherited from the calling shell (bash exports
# propagate into this function's own subshell-free invocation) — this
# wrapper only pins the fixed plumbing every routepar test needs
# identically (the fake toolchain on $PATH, the fake RUSTBUILD_SCRIPTS,
# a nonexistent canonical Cargo.toml so the install-freshness guard
# no-ops, the per-test journal file).
routepar_run_gate() {
  local repo="$1" journal="$2"; shift 2
  mkdir -p "$(dirname "$journal")"
  local prompt="$(dirname "$journal")/reviewer-prompt.md"
  [ -f "$prompt" ] || echo "fake reviewer prompt" > "$prompt"
  PATH="$ROUTEPAR_FAKE:$PATH" \
  AUTOBUILDER_CANONICAL_CARGO_TOML="$(dirname "$journal")/no-such-canonical/Cargo.toml" \
  RUSTBUILD_SCRIPTS="$ROUTEPAR_FAKE" \
  REVIEWER_PROMPT="$(dirname "$journal")/reviewer-prompt.md" \
  EXTEND_GATE_JOURNAL="$journal" \
  BURST_LANE_SH="$ROUTEPAR_FAKE/burst-lane.sh" \
  CARGO_BUDGET="$ROUTEPAR_REPO_ROOT/tests/fixtures/gatephase-fake/cargo-budget.sh" \
  bash "$ROUTEPAR_EXTEND_GATE" "$repo" --force "$@"
}

# routepar_receipt_route <repo> <name> -> stdout the .route field of
# target/autobuilder/receipts/<name>.json, or empty if absent/unparsable.
routepar_receipt_route() {
  local repo="$1" name="$2"
  jq -r '.route // empty' "$repo/target/autobuilder/receipts/$name.json" 2>/dev/null
}
