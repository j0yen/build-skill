#!/usr/bin/env bash
# tests/fixtures/xrepo-common.sh — shared fixture builder for the
# xrepo_ac*.sh selftests (PRD-build-cross-repo-commit-gate, requirement 4).
#
# Builds a disposable rust-extend TARGET repo (stands in for mcphost) with
# a real `agent/proof-lanes.toml` naming exactly ONE lane whose globs cover
# only `src/**/*.rs`, runs a real `extend-gate.sh --record-baseline` on it
# (this crate's own risk-gate/reviewer-agent/ac-traceability/flake-audit
# producers block on a fixture this small — see extend-gate-scope-
# selftest.sh's own comment for the same observation — so those known
# blocks are committed as the baseline, isolating vti-plan's "is this file
# routed" check as the ONE thing that flips between refused and pass in
# the AC2/AC3 selftests) and commits that baseline, so a later worktree
# branch's own delta verdict is pass/delta-pass|block on vti-plan alone.
#
# Must be sourced, not executed. Callers: tests/xrepo_ac*.sh.
set -uo pipefail

XREPO_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XREPO_SCRIPTS="$(cd "$XREPO_HERE/../scripts" && pwd)"
XREPO_WORKTREE_EXTEND="$XREPO_SCRIPTS/worktree-extend.sh"
XREPO_GATED_TARGETS="$XREPO_SCRIPTS/gated-targets.sh"
XREPO_EXTEND_GATE="$XREPO_SCRIPTS/extend-gate.sh"

xrepo_fail=0
xrepo_expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label ($cond)" >&2
    xrepo_fail=1
  fi
}

xrepo_gitid() { git -c user.name="xrepo-selftest" -c user.email="xrepo-selftest@example.invalid" "$@"; }

# xrepo_mkfixture_manifest <path> <target-repo-realpath> <owner-slug> --
# writes a manifest.json declaring <target-repo-realpath> as <owner-slug>'s
# rust-extend build_into — the fixture stand-in for the real manifest
# cache gated-targets.sh reads (requirement 1).
xrepo_mkfixture_manifest() {
  local path="$1" target="$2" owner="$3"
  jq -n --arg t "$target" --arg o "$owner" \
    '{prds: {($o): {build_target: "rust-extend", build_into: $t}}, built_at: "2026-09-16T00:00:00Z"}' \
    > "$path"
}

# xrepo_mk_target_repo <workdir> -> prints the target repo's path on
# stdout. Leaves it at a green (baseline-recorded, committed) HEAD, tagged
# v0.1.0, with a single proof-lanes.toml lane covering src/**/*.rs only.
xrepo_mk_target_repo() {
  local root="${1:?xrepo_mk_target_repo: missing workdir}"
  local repo="$root/target-repo"
  mkdir -p "$repo/src" "$repo/agent" "$repo/tests" "$repo/scripts"

  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "xrepo-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF

  cat > "$repo/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF

  cat > "$repo/tests/xrepo_ac1.rs" <<'EOF'
use xrepo_fixture::add;

#[test]
fn ac1_add_returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF

  cat > "$repo/agent/intent-card.json" <<'EOF'
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "xrepo-fixture",
  "root_motivation": "Disposable fixture crate for xrepo_ac*.sh (PRD-build-cross-repo-commit-gate) — not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/xrepo_ac1.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none — fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give xrepo_ac*.sh a disposable rust-extend fixture with a routed/unrouted proof-lanes.toml split"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-16T00:00:00Z"
}
EOF

  # One lane, covering src/**/*.rs and agent/** (so routing-config changes
  # themselves — proof-lanes.toml and gate-baseline.json — are never
  # "unrouted" on their own) but NOT config/** — a file under config/ is
  # "unrouted" until a later commit extends this lane (or adds a new one)
  # to cover it, which is exactly the AC2 (refused) / AC3 (pass) split
  # requirement 4 wants.
  cat > "$repo/agent/proof-lanes.toml" <<'EOF'
[[lane]]
id = "rust-source"
description = "fixture lane — src + routing config only"
globs = ["src/**/*.rs", "agent/**"]
required_commands = ["cargo check"]
EOF

  cat > "$repo/scripts/run-metrics.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
head_sha="$(git rev-parse HEAD)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p target/autobuilder
jq -n --arg head "$head_sha" --arg ts "$captured_at" '{
  schema: "autobuilder.metrics.v1",
  head_sha: $head,
  scalars: {acceptance_tests_passing_count: 1},
  ac_passing_count: 1,
  ac_total_count: 1,
  audit: {blocking_count: 0, advisory_count: 0},
  clippy_warning_count: 0,
  captured_at: $ts
}' > target/autobuilder/metrics.json
EOF
  chmod +x "$repo/scripts/run-metrics.sh"

  cat > "$repo/.gitignore" <<'EOF'
/target
/.cargo
EOF

  ( cd "$repo" && cargo generate-lockfile >/dev/null 2>&1 ) || true

  git -C "$repo" init -q -b main
  xrepo_gitid -C "$repo" add -A
  xrepo_gitid -C "$repo" commit -q -m "initial"

  # --- record + commit the baseline (known-blocking receipt set for THIS
  #     minimal fixture) so a later branch's delta verdict turns on
  #     vti-plan alone. ------------------------------------------------
  ( cd "$repo" && \
    PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
    REVIEWER_PROMPT=/nonexistent/xrepo-selftest-reviewer-prompt.md \
    EXTEND_GATE_JOURNAL="$root/baseline-journal.md" \
    timeout -k 5 90 "$XREPO_EXTEND_GATE" "$repo" --record-baseline --force >"$root/baseline.out" 2>&1 ) || true

  if [ -f "$repo/agent/gate-baseline.json" ]; then
    # This minimal fixture crate has no scripts/audit.sh, no reachable
    # reviewer prompt, and a trivial single-AC intent-card — risk-gate,
    # reviewer-agent, and ac-traceability block every run, deterministically.
    # flake-audit does NOT (observed both pass and block across runs on this
    # shared host, load-dependent) — force all four into the baseline
    # regardless of what THIS record run happened to see, so a later
    # branch's delta verdict is decided by vti-plan alone (the one thing
    # AC2/AC3 actually vary), never by flake-audit's own non-determinism.
    jq '.receipts = ((.receipts // []) + [
          {"name": "risk-gate", "reason": "fixture: no scripts/audit.sh"},
          {"name": "reviewer-agent", "reason": "fixture: no reachable reviewer prompt"},
          {"name": "ac-traceability", "reason": "fixture: trivial single-AC intent-card"},
          {"name": "flake-audit", "reason": "fixture: known load-dependent on a shared host"}
        ] | unique_by(.name))' \
      "$repo/agent/gate-baseline.json" > "$repo/agent/gate-baseline.json.tmp" \
      && mv "$repo/agent/gate-baseline.json.tmp" "$repo/agent/gate-baseline.json"
    xrepo_gitid -C "$repo" add agent/gate-baseline.json
    xrepo_gitid -C "$repo" commit -q -m "record gate baseline"
  fi

  # Tag AFTER the baseline commit (not at "initial") — a branch's own
  # vti-plan diff is computed against this tag, so gate-baseline.json
  # itself (committed above, and covered by no lane) never shows up as an
  # "unrouted" file on every subsequent branch; only files the branch
  # itself adds/changes do.
  git -C "$repo" tag v0.1.0

  printf '%s\n' "$repo"
}
