#!/usr/bin/env bash
# tests/fixtures/bgscope-common.sh — shared fixture-building for the
# bgscope_ac*.sh test files (PRD-build-branch-gate-scope-artifacts). Not a
# standalone test; `source`d by tests/bgscope_ac*.sh files that need a
# real `extend-gate.sh --scope branch` run against a disposable crate.
#
# Design mirrors scripts/extend-gate-branch-scope-realfixture-selftest.sh
# (the fuller integration selftest this PRD also ships, req6/AC8) but
# factors the fixture-building + hybrid fake-toolchain into reusable
# functions, and adds a SHARED, cached "correct"/"incorrect" run (keyed by
# a fixed path under $TMPDIR, flock-guarded) so AC3/AC4/AC5/AC6 — which
# all read different facts off the SAME two gate runs — don't each pay
# for their own independent cargo compile + gate pass. AC1/AC2 need a
# DIFFERENT fixture shape (no tag at all) and build their own, small,
# fixture directly.
set -uo pipefail

BGSCOPE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BGSCOPE_EXTEND_GATE="$BGSCOPE_REPO_ROOT/scripts/extend-gate.sh"
BGSCOPE_WORKTREE_EXTEND="$BGSCOPE_REPO_ROOT/scripts/worktree-extend.sh"
BGSCOPE_REAL_AUTOBUILDER="$(command -v autobuilder || true)"
BGSCOPE_REAL_CARGO="$(command -v cargo || true)"

# bgscope_write_fixture_crate <repo-dir> — the disposable 2-file crate
# every bgscope test gates against (never a real product, never mcphost).
bgscope_write_fixture_crate() {
  local repo="$1" rollback_model="${2:-}"
  mkdir -p "$repo/src" "$repo/agent" "$repo/tests" "$repo/scripts"
  cat > "$repo/Cargo.toml" <<'EOF'
[package]
name = "bgscope-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF
  cat > "$repo/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
  cat > "$repo/tests/bgscope_ac1.rs" <<'EOF'
use bgscope_fixture::add;

#[test]
fn ac1_add_returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF
  cat > "$repo/agent/intent-card.json" <<'EOF'
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "bgscope-fixture",
  "root_motivation": "Disposable fixture crate for bgscope_ac*.sh tests (PRD-build-branch-gate-scope-artifacts) -- not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/bgscope_ac1.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none -- fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give bgscope_ac*.sh tests a disposable rust-extend fixture"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-16T00:00:00Z"
}
EOF
  # AC1's redeploy-tag scenario (autobuilder's rollback.rs `resolve_
  # rollback_model`: an explicit `rollback_model` key in intent-card.json
  # takes precedence over the revert-commits default) -- inject it in
  # place rather than templating the whole intent-card, so both variants
  # stay byte-identical apart from this one key.
  if [ -n "$rollback_model" ]; then
    jq --arg m "$rollback_model" '. + {rollback_model: $m}' "$repo/agent/intent-card.json" \
      > "$repo/agent/intent-card.json.tmp" && mv "$repo/agent/intent-card.json.tmp" "$repo/agent/intent-card.json"
  fi
  cat > "$repo/agent/proof-lanes.toml" <<'EOF'
[[lane]]
id = "rust-source"
description = "fixture lane"
globs = ["src/**/*.rs"]
required_commands = ["cargo check"]
EOF
  cat > "$repo/scripts/run-metrics.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
head_sha="$(git rev-parse HEAD)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p target/autobuilder
jq -n --arg head "$head_sha" --arg ts "$captured_at" '{
  schema: "autobuilder.metrics.v1", head_sha: $head,
  scalars: {acceptance_tests_passing_count: 1},
  ac_passing_count: 1, ac_total_count: 1,
  audit: {blocking_count: 0, advisory_count: 0},
  clippy_warning_count: 0, captured_at: $ts
}' > target/autobuilder/metrics.json
EOF
  chmod +x "$repo/scripts/run-metrics.sh"
  cat > "$repo/.gitignore" <<'EOF'
/target
/.cargo
EOF
  ( cd "$repo" && cargo generate-lockfile >/dev/null 2>&1 ) || true
  git -C "$repo" init -q
  git -C "$repo" -c user.name="bgscope-test" -c user.email="selftest@example.com" add -A
  git -C "$repo" -c user.name="bgscope-test" -c user.email="selftest@example.com" commit -q -m "initial"
  # worktree-extend.sh integrate (AC7's land path) expects the target
  # repo's default branch to be literally named "main"; this host's own
  # `git init` default is "master" (bug found live: gate-then-land.sh's
  # own stale-base check compares against a hardcoded "main" and never
  # matched, exhausting all 3 retries with an unchanged sha every time).
  git -C "$repo" branch -M main
}

# bgscope_add_origin <repo-dir> <origin-dir> — real bare remote + push.
bgscope_add_origin() {
  local repo="$1" origin="$2" branch
  branch="$(git -C "$repo" symbolic-ref --short HEAD)"
  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q origin "$branch" --tags
}

# bgscope_write_fakebin <dir> — the hybrid toolchain: real autobuilder for
# rollback-plan/ci-checks/reviewer-agent, stubbed everywhere else, real
# cargo (bypassing cargo-budget-bin) for the fake `loop` subcommand's own
# test run. See scripts/extend-gate-branch-scope-realfixture-selftest.sh's
# header for the full rationale (this is the same design, factored out).
bgscope_write_fakebin() {
  local fakebin="$1"
  mkdir -p "$fakebin"
  cat > "$fakebin/autobuilder" <<EOF
#!/usr/bin/env bash
set -uo pipefail
REAL="$BGSCOPE_REAL_AUTOBUILDER"
REAL_CARGO="$BGSCOPE_REAL_CARGO"
sub="\${1:-}"; shift || true
get_project() {
  local p="." args=("\$@") i=0
  while [ \$i -lt \${#args[@]} ]; do
    if [ "\${args[\$i]}" = "--project" ]; then p="\${args[\$((i+1))]}"; fi
    i=\$((i+1))
  done
  printf '%s\n' "\$p"
}
case "\$sub" in
  intake) exit 0 ;;
  loop)
    proj="\$(get_project "\$@")"
    mkdir -p "\$proj/target/autobuilder/receipts"
    if ( cd "\$proj" && "\$REAL_CARGO" test --quiet ) >/tmp/bgscope-fixture-cargo-test.log 2>&1; then
      printf '{"verdict":"pass"}' > "\$proj/target/autobuilder/receipts/proof-receipt.json"; exit 0
    else
      printf '{"verdict":"block","reason":"cargo-test-failed"}' > "\$proj/target/autobuilder/receipts/proof-receipt.json"; exit 1
    fi
    ;;
  vti-plan) exit 0 ;;
  rollback-plan)   exec "\$REAL" rollback-plan "\$@" ;;
  ci-checks)       exec "\$REAL" ci-checks "\$@" ;;
  reviewer-agent)  exec "\$REAL" reviewer-agent "\$@" ;;
  gate)
    proj="\$(get_project "\$@")"
    rdir="\$proj/target/autobuilder/receipts"
    pass_n=0; block_n=0; names=""
    if [ -d "\$rdir" ]; then
      for f in "\$rdir"/*.json; do
        [ -f "\$f" ] || continue
        v="\$(jq -r '.verdict // .decision // "unknown"' "\$f" 2>/dev/null)"
        case "\$v" in
          pass|skipped|concern) pass_n=\$((pass_n+1)) ;;
          *) block_n=\$((block_n+1)); names="\$names,\$(basename "\$f" .json)" ;;
        esac
      done
    fi
    head_sha="\$(cd "\$proj" && git rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "\$block_n" -eq 0 ]; then
      echo "gate: head=\$head_sha receipts=\$((pass_n+block_n)) pass=\$pass_n block=0 verdict=pass"; exit 0
    else
      echo "gate: head=\$head_sha receipts=\$((pass_n+block_n)) pass=\$pass_n block=\$block_n verdict=block blocking=\${names#,}"; exit 1
    fi
    ;;
  --version) exec "\$REAL" --version ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/autobuilder"

  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
head_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
intent_sha="sha256:$(sha256sum agent/intent-card.json 2>/dev/null | awk '{print $1}')"
cat <<JSON
{"schema":"autobuilder.reviewer_agent_receipt.v1","head_sha":"$head_sha","intent_card_sha":"$intent_sha","decision":"pass","block_reasons":[],"concern_reasons":[],"falsification":{"test_audit":"stubbed for bgscope_ac*.sh -- no real model spend","panic_audit":"n/a (fixture stub)","unsafe_audit":"n/a (fixture stub)","public_api_audit":"n/a (fixture stub)","deps_audit":"n/a (fixture stub)","drift_audit":"n/a (fixture stub)","counter_attack":{"description":"n/a (fixture stub)","test_skeleton":""}}}
JSON
exit 0
EOF
  chmod +x "$fakebin/claude"

  cat > "$fakebin/extended-receipts.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fakebin/extended-receipts.sh"

  cat > "$fakebin/ship-tag.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fakebin/ship-tag.sh"
}

# bgscope_run_gate <fakebin> <reviewer-prompt> <worktree> <head> <slug> <journal> <out>
# -> runs extend-gate.sh --scope branch --force, returns its exit code.
bgscope_run_gate() {
  local fakebin="$1" prompt="$2" wt="$3" head="$4" slug="$5" journal="$6" out="$7"
  env \
    "PATH=$fakebin:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
    "REAL_AUTOBUILDER_BIN=$BGSCOPE_REAL_AUTOBUILDER" \
    "RUSTBUILD_SCRIPTS=$fakebin" \
    "REVIEWER_PROMPT=$prompt" \
    "CI_CHECKS_BRANCH_WAIT=3" \
    "CI_CHECKS_BRANCH_POLL=1" \
    "BRANCH_GATE_PUSH=${BGSCOPE_BRANCH_GATE_PUSH:-1}" \
    "EXTEND_GATE_JOURNAL=$journal" \
    timeout -k 5 180 "$BGSCOPE_EXTEND_GATE" "$wt" --head "$head" --scope branch --slug "$slug" --force >"$out" 2>&1
}

# bgscope_ensure_shared_run <kind: correct|incorrect> -> stdout: shared dir
# path. Builds the fixture + runs the branch gate ONCE per kind, cached
# under a fixed path (flock-guarded so concurrent AC test files racing
# for the same kind don't double-build); a marker's mtime older than 1h
# is treated as stale and rebuilt (tolerates a wiped /tmp between runs).
bgscope_ensure_shared_run() {
  local kind="$1"
  local dir="${TMPDIR:-/tmp}/bgscope-shared-$kind-$(id -u)"
  local lock="$dir.lock"
  mkdir -p "$(dirname "$dir")"
  (
    exec 8>"$lock"
    flock 8
    if [ -f "$dir/DONE" ] && [ "$(find "$dir/DONE" -mmin -60 2>/dev/null)" ]; then
      exit 0
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    bgscope_write_fixture_crate "$dir/repo"
    bgscope_add_origin "$dir/repo" "$dir/origin.git"
    bgscope_write_fakebin "$dir/fakebin"
    printf 'shared reviewer prompt for bgscope_ac*.sh\n' > "$dir/reviewer-prompt.md"

    local slug="bgscope-shared-$kind"
    local wt
    wt="$(BUILD_TARGET_ROOT="$dir/offroot" "$BGSCOPE_WORKTREE_EXTEND" add "$dir/repo" "$slug" 2>>"$dir/setup.log")"
    if [ "$kind" = correct ]; then
      echo "docs: harmless change (correct branch)" >> "$wt/README.md"
      git -C "$wt" -c user.name="bgscope-test" -c user.email="selftest@example.com" add README.md
      git -C "$wt" -c user.name="bgscope-test" -c user.email="selftest@example.com" commit -q -m "docs: harmless change (correct branch)"
    else
      sed -i 's/assert_eq!(add(2, 2), 4);/assert_eq!(add(2, 2), 5);/' "$wt/tests/bgscope_ac1.rs"
      git -C "$wt" -c user.name="bgscope-test" -c user.email="selftest@example.com" add tests/bgscope_ac1.rs
      git -C "$wt" -c user.name="bgscope-test" -c user.email="selftest@example.com" commit -q -m "break the test (incorrect branch)"
    fi
    local head_sha; head_sha="$(git -C "$wt" rev-parse HEAD)"
    printf '%s\n' "$wt" > "$dir/WORKTREE"
    printf '%s\n' "$head_sha" > "$dir/HEAD"
    printf '%s\n' "$slug" > "$dir/SLUG"

    BGSCOPE_BRANCH_GATE_PUSH=1 bgscope_run_gate "$dir/fakebin" "$dir/reviewer-prompt.md" "$wt" "$head_sha" "$slug" "$dir/journal.md" "$dir/out.log"
    echo "$?" > "$dir/RC"

    local target; target="$(readlink -f "$wt/target" 2>/dev/null || true)"
    printf '%s\n' "$target" > "$dir/TARGET"
    date -u +%FT%TZ > "$dir/DONE"
  )
  printf '%s\n' "$dir"
}
