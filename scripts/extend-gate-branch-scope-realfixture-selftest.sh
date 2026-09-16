#!/usr/bin/env bash
# extend-gate-branch-scope-realfixture-selftest.sh — PRD-build-branch-gate-
# scope-artifacts requirement 6 (P0) / AC8: the branch-scope selftest
# fixture gains a REAL `origin` remote and a REAL tag lineage (v0.1.0) —
# the shape every real branch gate actually sees (Problem statement: mcphost
# had exactly this shape, tag + origin, and every one of 14 branch gates on
# 2026-09-15 blocked on scope artifacts anyway) — and exercises BOTH the
# AC5 shape (a correct branch reaches `pass`, `deferred=ci-checks`) and the
# AC6 shape (an incorrect branch — a failing test — reaches `block` with a
# `reviewer-agent` receipt present) against the REAL `extend-gate.sh`.
#
# Design: a hybrid toolchain, not a fully-real cargo/autobuilder crate (that
# would also need every one of the 17 extended-gates producers — supply-
# audit, mutation-kill, flake-audit, etc. — individually satisfied, which
# has nothing to do with THIS PRD's scope-defer logic and would make this
# selftest a multi-hour reverse-engineering project instead of a fast,
# deterministic regression check):
#   - `rollback-plan`, `ci-checks`, `reviewer-agent prepare|finalize` run
#     the REAL `autobuilder` binary (real git tag/remote reachability, real
#     receipt-writing, real reviewer schema validation) — these are
#     EXACTLY the producers this PRD's scope policy touches.
#   - `intake`, `vti-plan` are stubbed to instant-pass (untouched by this
#     PRD, Non-goals).
#   - `loop` (proof-receipt) runs a REAL `cargo test` against the fixture
#     crate and writes its own verdict from the real result — this is what
#     gives AC6's "a branch with a failing test" a REAL failing test,
#     rather than a scripted block.
#   - `gate` (the 25-receipt aggregator) is stubbed to scan whatever
#     receipts actually exist on disk under target/autobuilder/receipts/
#     and block iff any carries a verdict/decision outside
#     pass|skipped|concern — this reproduces the real aggregator's
#     "any-receipt-not-passing blocks" contract without requiring the other
#     16 extended-gates producer binaries to independently pass on a
#     fixture crate that isn't a real product.
#   - `claude` (the reviewer subagent spawn) is stubbed to a canned, valid
#     `autobuilder.reviewer_agent_receipt.v1` response with head_sha/
#     intent_card_sha computed FOR REAL from the worktree (finalize
#     validates both against the actual HEAD/intent-card.json) — no real
#     model spend, but the real `autobuilder reviewer-agent finalize`
#     binary still validates and writes the receipt for real.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
WORKTREE_EXTEND="$HERE/worktree-extend.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
[ -x "$WORKTREE_EXTEND" ] || { echo "selftest: $WORKTREE_EXTEND not executable" >&2; exit 2; }
for bin in git jq cargo autobuilder sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done
REAL_AUTOBUILDER_BIN="$(command -v autobuilder)"
# Real cargo, captured BEFORE any PATH override below -- the fake `loop`
# subcommand's internal `cargo test` runs THIS directly, bypassing
# cargo-budget-bin's shared concurrency budget. That budget is meant to
# throttle real crate builds against real production PRDs sharing this
# host; a two-file fixture crate's own pass/fail test does not need to
# queue behind unrelated sibling /build load, and doing so blew this
# selftest's timeout out under a busy tick (2026-09-16, first attempt).
REAL_CARGO_BIN="$(command -v cargo)"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/extend-gate-branch-realfixture-selftest.XXXXXX")"
trap '[ -n "${EXTEND_GATE_REALFIXTURE_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
ORIGIN="$T/origin.git"
FAKEBIN="$T/fakebin"
mkdir -p "$REPO/src" "$REPO/agent" "$REPO/tests" "$REPO/scripts" "$FAKEBIN"

# --- fixture crate (same shape as extend-gate-scope-selftest.sh's, PRD-
#     build-gate-before-land) --------------------------------------------
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "bgscope-realfixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF

cat > "$REPO/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF

cat > "$REPO/tests/bgscope_ac1.rs" <<'EOF'
use bgscope_realfixture::add;

#[test]
fn ac1_add_returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF

cat > "$REPO/agent/intent-card.json" <<'EOF'
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "bgscope-realfixture",
  "root_motivation": "Disposable fixture crate for extend-gate-branch-scope-realfixture-selftest.sh (PRD-build-branch-gate-scope-artifacts req6/AC8) -- not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/bgscope_ac1.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none -- fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give extend-gate-branch-scope-realfixture-selftest.sh a disposable rust-extend fixture with a real origin+tag"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-16T00:00:00Z"
}
EOF

cat > "$REPO/agent/proof-lanes.toml" <<'EOF'
[[lane]]
id = "rust-source"
description = "fixture lane"
globs = ["src/**/*.rs"]
required_commands = ["cargo check"]
EOF

cat > "$REPO/scripts/run-metrics.sh" <<'EOF'
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
chmod +x "$REPO/scripts/run-metrics.sh"

cat > "$REPO/.gitignore" <<'EOF'
/target
/.cargo
EOF

( cd "$REPO" && cargo generate-lockfile >/dev/null 2>&1 ) || true

git -C "$REPO" init -q
git -C "$REPO" -c user.name="bgscope-selftest" -c user.email="selftest@example.com" add -A
git -C "$REPO" -c user.name="bgscope-selftest" -c user.email="selftest@example.com" commit -q -m "initial"
MAIN_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
git -C "$REPO" tag v0.1.0
INITIAL_SHA="$(git -C "$REPO" rev-parse HEAD)"

# --- real bare origin + push + tag lineage (requirement 6 / AC8) --------
git init -q --bare "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin "$MAIN_BRANCH" --tags

expect "setup: origin remote is a real (bare) git repo" "[ -d \"$ORIGIN\" ]"
origin_tags="$(git -C "$ORIGIN" tag)"
expect "setup: tag v0.1.0 landed on origin" "printf '%s' \"$origin_tags\" | grep -qx v0.1.0"

# --- fake toolchain: real autobuilder for rollback-plan/ci-checks/
#     reviewer-agent, stubbed everywhere else (see file header) ---------
cat > "$FAKEBIN/autobuilder" <<EOF
#!/usr/bin/env bash
set -uo pipefail
REAL="$REAL_AUTOBUILDER_BIN"
REAL_CARGO="$REAL_CARGO_BIN"
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
    if ( cd "\$proj" && "\$REAL_CARGO" test --quiet ) >/tmp/bgscope-realfixture-cargo-test.log 2>&1; then
      printf '{"verdict":"pass"}' > "\$proj/target/autobuilder/receipts/proof-receipt.json"
      exit 0
    else
      printf '{"verdict":"block","reason":"cargo-test-failed"}' > "\$proj/target/autobuilder/receipts/proof-receipt.json"
      exit 1
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
      echo "gate: head=\$head_sha receipts=\$((pass_n+block_n)) pass=\$pass_n block=0 verdict=pass"
      exit 0
    else
      echo "gate: head=\$head_sha receipts=\$((pass_n+block_n)) pass=\$pass_n block=\$block_n verdict=block blocking=\${names#,}"
      exit 1
    fi
    ;;
  --version)       exec "\$REAL" --version ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/autobuilder"

cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
# Fake `claude` CLI -- stands in for the headless Sonnet reviewer spawn.
# head_sha/intent_card_sha are computed FOR REAL from cwd (the worktree)
# because the REAL `autobuilder reviewer-agent finalize` validates both
# against the actual HEAD and agent/intent-card.json -- a hardcoded value
# would be rejected. No real model call, no token spend.
set -uo pipefail
head_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
# autobuilder's own sha256_hex() prepends "sha256:" (see review-request.json's
# intent_card_sha256 field) -- finalize compares against that exact form.
intent_sha="sha256:$(sha256sum agent/intent-card.json 2>/dev/null | awk '{print $1}')"
cat <<JSON
{"schema":"autobuilder.reviewer_agent_receipt.v1","head_sha":"$head_sha","intent_card_sha":"$intent_sha","decision":"pass","block_reasons":[],"concern_reasons":[],"falsification":{"test_audit":"stubbed for extend-gate-branch-scope-realfixture-selftest.sh (PRD-build-branch-gate-scope-artifacts req6) -- no real model spend","panic_audit":"n/a (fixture stub)","unsafe_audit":"n/a (fixture stub)","public_api_audit":"n/a (fixture stub)","deps_audit":"n/a (fixture stub)","drift_audit":"n/a (fixture stub)","counter_attack":{"description":"n/a (fixture stub)","test_skeleton":""}}}
JSON
exit 0
EOF
chmod +x "$FAKEBIN/claude"

cat > "$FAKEBIN/extended-receipts.sh" <<'EOF'
#!/usr/bin/env bash
# Stub for the 17 extended-gates producers -- out of this PRD's scope
# (Non-goals); the fake `gate` subcommand above only scans whatever
# receipts actually exist, so writing none here is a legitimate "no
# opinion" rather than a silent false-pass.
exit 0
EOF
chmod +x "$FAKEBIN/extended-receipts.sh"

cat > "$FAKEBIN/ship-tag.sh" <<'EOF'
#!/usr/bin/env bash
# Stub -- extend-gate.sh only checks this exists+executable under
# $RUSTBUILD_SCRIPTS at startup (line ~454); a branch-scope gate run never
# calls it (ship-tag.sh only ever runs at ship time, after land).
exit 0
EOF
chmod +x "$FAKEBIN/ship-tag.sh"

cat > "$T/reviewer-prompt.md" <<'EOF'
Fixture reviewer prompt for extend-gate-branch-scope-realfixture-selftest.sh.
EOF

COMMON_ENV=(
  "PATH=$FAKEBIN:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH"
  "REAL_AUTOBUILDER_BIN=$REAL_AUTOBUILDER_BIN"
  "RUSTBUILD_SCRIPTS=$FAKEBIN"
  "REVIEWER_PROMPT=$T/reviewer-prompt.md"
  "CI_CHECKS_BRANCH_WAIT=3"
  "CI_CHECKS_BRANCH_POLL=1"
  "BRANCH_GATE_PUSH=1"
)

run_branch_gate() {  # $1=worktree $2=head $3=slug $4=journal -> writes $out, returns extend-gate.sh's rc
  local wt="$1" head="$2" slug="$3" journal="$4" out="$5"
  env "${COMMON_ENV[@]}" EXTEND_GATE_JOURNAL="$journal" \
    timeout -k 5 180 "$EXTEND_GATE" "$wt" --head "$head" --scope branch --slug "$slug" --force >"$out" 2>&1
}

# ============================= AC5 shape: correct branch =================
echo "=== AC5: a correct branch reaches pass, deferred=ci-checks ==="
SLUG_A="bgscope-correct-$$"
WT_A="$(BUILD_TARGET_ROOT="$T/offroot-a" "$WORKTREE_EXTEND" add "$REPO" "$SLUG_A")"
expect "AC5 setup: worktree A created" "[ -d \"$WT_A\" ]"
echo "docs: correct-branch commit" >> "$WT_A/README.md"
git -C "$WT_A" -c user.name="bgscope-selftest" -c user.email="selftest@example.com" add README.md
git -C "$WT_A" -c user.name="bgscope-selftest" -c user.email="selftest@example.com" commit -q -m "docs: harmless change (correct branch)"
HEAD_A="$(git -C "$WT_A" rev-parse HEAD)"

JOURNAL_A="$T/journal-a.md"
OUT_A="$T/out-a.log"
run_branch_gate "$WT_A" "$HEAD_A" "$SLUG_A" "$JOURNAL_A" "$OUT_A"
RC_A=$?
cat "$OUT_A"
expect "AC5: extend-gate.sh exits 0 (pass)" "[ $RC_A -eq 0 ]"

line_a="$(grep '  gate  ' "$JOURNAL_A" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
echo "  journal A: $line_a"
expect "AC5: journal line carries scope=branch slug=$SLUG_A" "printf '%s' \"$line_a\" | grep -q 'scope=branch slug=$SLUG_A '"
expect "AC5: journal line's outcome is pass" "printf '%s' \"$line_a\" | grep -q '  pass  (scope=branch'"
expect "AC5: journal line names deferred=ci-checks" "printf '%s' \"$line_a\" | grep -q 'deferred=ci-checks'"
expect "AC5: journal line does NOT defer rollback-plan (real tag lineage lets it pass outright)" \
  "! printf '%s' \"$line_a\" | grep -qE 'deferred=(rollback-plan|[a-z-]+,rollback-plan)'"

WT_A_TARGET="$(readlink -f "$WT_A/target" 2>/dev/null || true)"
verdict_a="$WT_A_TARGET/autobuilder/last-verdict.json"
expect "AC5: last-verdict.json exists" "[ -f \"$verdict_a\" ]"
deferred_a="$(jq -c '.deferred_receipts // []' "$verdict_a" 2>/dev/null || echo '[]')"
echo "  last-verdict.json deferred_receipts: $deferred_a"
# Precompute the match as a plain true/false token before handing it to
# expect()'s eval -- nesting a literal `["ci-checks"]` (brackets AND
# quotes) inside an already-escaped cond string is exactly the double-
# escaping trap this file's own AC1a/b/c comment (below) warns about.
deferred_a_matches=false
[ "$deferred_a" = '["ci-checks"]' ] && deferred_a_matches=true
expect "AC5: last-verdict.json.deferred_receipts == [\"ci-checks\"]" "[ \"$deferred_a_matches\" = true ]"
expect "AC5: reviewer-agent receipt is present (branch scope always runs it)" \
  "[ -f \"$WT_A_TARGET/autobuilder/receipts/reviewer-agent.json\" ]"

# origin gained the pushed branch ref (requirement 2)
expect "AC5: BRANCH_GATE_PUSH pushed the branch ref to origin" \
  "git -C \"$ORIGIN\" show-ref --verify --quiet refs/heads/autobuilder/$SLUG_A"

# ============================ AC6 shape: incorrect branch =================
echo "=== AC6: a branch with a failing test reaches block, reviewer-agent present ==="
SLUG_B="bgscope-incorrect-$$"
WT_B="$(BUILD_TARGET_ROOT="$T/offroot-b" "$WORKTREE_EXTEND" add "$REPO" "$SLUG_B")"
expect "AC6 setup: worktree B created" "[ -d \"$WT_B\" ]"
sed -i 's/assert_eq!(add(2, 2), 4);/assert_eq!(add(2, 2), 5);/' "$WT_B/tests/bgscope_ac1.rs"
git -C "$WT_B" -c user.name="bgscope-selftest" -c user.email="selftest@example.com" add tests/bgscope_ac1.rs
git -C "$WT_B" -c user.name="bgscope-selftest" -c user.email="selftest@example.com" commit -q -m "break the test (incorrect branch)"
HEAD_B="$(git -C "$WT_B" rev-parse HEAD)"

JOURNAL_B="$T/journal-b.md"
OUT_B="$T/out-b.log"
run_branch_gate "$WT_B" "$HEAD_B" "$SLUG_B" "$JOURNAL_B" "$OUT_B"
RC_B=$?
cat "$OUT_B"
expect "AC6: extend-gate.sh exits non-zero (block)" "[ $RC_B -ne 0 ]"

line_b="$(grep '  gate  ' "$JOURNAL_B" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
echo "  journal B: $line_b"
expect "AC6: journal line carries scope=branch slug=$SLUG_B" "printf '%s' \"$line_b\" | grep -q 'scope=branch slug=$SLUG_B '"
expect "AC6: journal line's outcome is block" "printf '%s' \"$line_b\" | grep -q '  block  (scope=branch'"
expect "AC6: journal line names the failing test as an in-scope block (proof-receipt)" \
  "printf '%s' \"$line_b\" | grep -q 'proof-receipt'"

WT_B_TARGET="$(readlink -f "$WT_B/target" 2>/dev/null || true)"
expect "AC6: reviewer-agent receipt is present despite the in-scope block (req3, AC4/AC6)" \
  "[ -f \"$WT_B_TARGET/autobuilder/receipts/reviewer-agent.json\" ]"
expect "AC6: no reviewer-skipped journal line was written" \
  "! grep -q 'reviewer-skipped' \"$JOURNAL_B\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "extend-gate-branch-scope-realfixture-selftest: ALL PASS"
  exit 0
else
  echo "extend-gate-branch-scope-realfixture-selftest: assertion(s) FAILED"
  exit 1
fi
