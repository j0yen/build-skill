#!/usr/bin/env bash
# gatepat-common.sh — shared fixtures for tests/gatepat_ac*.sh
# (PRD-build-gate-patience-from-queue-depth).
#
# The real producer sequence (autobuilder's 25 receipts) is slow and, on
# this box, already red at a clean HEAD for reasons unrelated to this PRD
# (see extend-gate-concurrent-selftest.sh's own AC1/AC2, which fail
# identically against an unmodified extend-gate.sh) — exercising it here
# would make these tests flaky for a cause this PRD does not touch. Every
# fixture below instead makes the repo DIRTY (an untracked file) so
# extend-gate.sh reaches (and exercises) the lock/patience/holder logic
# this PRD actually adds, then refuses at its existing "dirty tree" check
# (AC2 of PRD-build-gate-extend-receipts, exit 3) BEFORE any producer runs
# — a real, unmodified code path, just one that returns fast and
# deterministically.
set -uo pipefail

GATEPAT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEPAT_SCRIPTS="$(cd "$GATEPAT_HERE/../scripts" && pwd)"
EXTEND_GATE="$GATEPAT_SCRIPTS/extend-gate.sh"
GATE_THEN_LAND="$GATEPAT_SCRIPTS/gate-then-land.sh"
LANE_STATUS="$GATEPAT_SCRIPTS/lane-status.sh"

# extend-gate.sh resolves its own extended-receipts.sh dependency off
# $HOME (RUSTBUILD_SCRIPTS="${RUSTBUILD_SCRIPTS:-$HOME/.claude/skills/
# rustbuild/scripts}"), unrelated to this PRD. Under run-selftests.sh's
# structural isolation (BUILD_TEST=1), $HOME is redirected to a scratch
# root that doesn't have that skill installed — pin RUSTBUILD_SCRIPTS back
# at the REAL one (BUILD_TEST_REAL_HOME when isolation is active, else the
# ambient $HOME) so a real extend-gate.sh invocation still finds it,
# exactly the same convention isolation.sh itself uses for
# RUSTUP_HOME/CARGO_HOME.
GATEPAT_REAL_HOME="${BUILD_TEST_REAL_HOME:-$HOME}"
GATEPAT_RUSTBUILD_SCRIPTS="${RUSTBUILD_SCRIPTS:-$GATEPAT_REAL_HOME/.claude/skills/rustbuild/scripts}"

gatepat_fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; gatepat_fail=1; fi
}

# make_dirty_repo <dir> — a minimal rust-extend-shaped fixture (Cargo.toml
# required by extend-gate.sh's own project-root search, run BEFORE the
# lock section) that is always dirty. Prints the committed HEAD sha.
make_dirty_repo() {
  local dir="$1"
  mkdir -p "$dir/src"
  cat > "$dir/Cargo.toml" <<'EOF'
[package]
name = "gatepat-fixture"
version = "0.1.0"
edition = "2021"
EOF
  echo 'pub fn x() {}' > "$dir/src/lib.rs"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=gatepat -c user.email=gatepat@example.com add -A
  git -C "$dir" -c user.name=gatepat -c user.email=gatepat@example.com commit -q -m init
  touch "$dir/dirty.txt"
  git -C "$dir" rev-parse HEAD
}

# make_fake_lane_claim <out_path> <json-claims-array-literal>
# Writes a fake lane-claim.sh that only implements `--json` (gate-patience.sh's
# only call site) — never a real PRD clone.
make_fake_lane_claim() {
  local out="$1" claims_json="$2"
  cat > "$out" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--json" ]; then
  cat <<JSON
{"schema_version":1,"claims":$claims_json}
JSON
  exit 0
fi
exit 4
EOF
  chmod +x "$out"
}

# write_prd_fixture <dir> <slug> <build_into>
write_prd_fixture() {
  local dir="$1" slug="$2" build_into="$3"
  mkdir -p "$dir/build-queue"
  printf '# fixture (gatepat selftest, disposable, never a real PRD)\n- build_into: %s\n' "$build_into" \
    > "$dir/build-queue/PRD-$slug.md"
}
