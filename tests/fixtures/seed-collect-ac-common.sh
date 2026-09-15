#!/usr/bin/env bash
# seed-collect-ac-common.sh — shared fixture for seed-collect_ac*.sh tests
# (PRD-prd-seed-inbox). Builds an isolated PRDs-repo fixture (a fresh git
# init, no remote) and a fixture build-journal, then exports the SEED_*
# env vars seed-collect.sh reads so every test runs against its own
# throwaway state instead of the real ~/Documents/PRDs / ~/brain/journal.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/seed-collect.sh"

seed_fixture_setup() {
  SEED_TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/seed-collect-ac.XXXXXX")"
  export SEED_PRD_DIR="$SEED_TMPROOT/prds"
  export SEED_JOURNAL_DIR="$SEED_TMPROOT/journal"
  export SEED_SYNTHORG_DIRS="$SEED_TMPROOT/no-such-synthorg"
  export SEED_COLLECT_PUSH=0
  mkdir -p "$SEED_PRD_DIR" "$SEED_JOURNAL_DIR"
  git -C "$SEED_PRD_DIR" init -q
  git -C "$SEED_PRD_DIR" config user.email test@example.com
  git -C "$SEED_PRD_DIR" config user.name "seed-collect-ac-test"
  git -C "$SEED_PRD_DIR" commit -q --allow-empty -m init
}

seed_fixture_teardown() {
  [ -n "${SEED_TMPROOT:-}" ] && rm -rf "$SEED_TMPROOT"
}

# One journal line with exactly two failed phases (ci-checks, receipts) —
# AC1's "two digest failure families".
seed_fixture_two_family_journal() {
  cat > "$SEED_JOURNAL_DIR/2026-09-15.md" <<'EOF'
2026-09-15T04:16:25Z  gate  worktree  reviewer-skipped  (blocks=1 head=2d309b4)
2026-09-15T04:27:03Z  gate  mcphost  block  (head=48230f7 base=v0.52.0 gate: head=48230f7 receipts=25 pass=22 block=3 verdict=block blocking=ci-checks phases=risk-gate:1,intake:0,proof-receipt:261,vti-plan:0,rollback-plan:1,ci-checks:0!,receipts:168!,reviewer:skip,gate:5 lock_wait=0s cargo=burst:0/local:0) verdict=block inherited=2
EOF
}

ok() { echo "ok  $1"; }
fail() { echo "FAIL  $1" >&2; exit 1; }

assert_eq() {
  # $1=got $2=want $3=label
  [ "$1" = "$2" ] || fail "$3 (got: $1 want: $2)"
  ok "$3"
}
