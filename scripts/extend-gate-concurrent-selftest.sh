#!/usr/bin/env bash
# extend-gate-concurrent-selftest.sh — regression coverage for the exact
# 2026-09-09 mcphost incident: N concurrent extend-gate.sh invocations
# against one shared build_into repo clobbering each other's receipts.
# PRD-build-extend-gate-concurrent-isolation, requirement 3 / AC1-3.
#
# Builds ONE disposable rust-extend fixture repo under $TMPDIR (never
# mcphost, never any production repo — this PRD's own verification must
# never touch production gate state) and launches two extend-gate.sh
# invocations against it within ~0.2s of each other, then asserts:
#
#   AC1 — both invocations report an IDENTICAL `gate: ... pass=N block=M`
#         line at the same HEAD (no flip).
#   AC2 — neither invocation's producer-writing phase ever overlaps the
#         other's in wall-clock time (proof that no receipt write from one
#         invocation is ever visible to, or clobbered by, the other while
#         either is mid-run) — verified via a "sleep-instrumented fixture
#         producer" per the PRD's own Verification note: the fixture's own
#         scripts/audit.sh (the FIRST producer extend-gate.sh runs after
#         taking the integration lock) appends a start/end timestamp to a
#         marker log and sleeps for
#         $GATECONCURRENT_AUDIT_SLEEP seconds — widening the race window
#         to several real seconds so exclusion is trivial to observe
#         without racing sub-second timing. This instruments the FIXTURE,
#         not extend-gate.sh itself (a repo may or may not ship
#         scripts/audit.sh; extend-gate.sh already runs it unmodified when
#         present — see extend-gate.sh's producer #1).
#   AC3 — an invocation that cannot acquire producer access within its
#         configured ceiling (requirement 2, EXTEND_GATE_PRODUCER_LOCK_WAIT)
#         exits non-zero naming the contending PID and never prints a
#         `gate: ... pass=.../block=...` verdict line — fail-closed, not
#         fail-wrong. Bounded wall time (no deadlock) is asserted for every
#         invocation this script runs, via an outer `timeout`.
#
# Never runs against mcphost or any other production repo (dispatch
# instruction + PRD's own Verification section). A separate, manual,
# read-only dry-run comparison against a real repo is out of scope for
# this automated selftest.
#
# The reviewer-agent producer is deliberately disabled here (REVIEWER_PROMPT
# pointed at a path that doesn't exist, an already-supported extend-gate.sh
# override — see its own header note on RUSTBUILD_SCRIPTS/REVIEWER_PROMPT
# being "overridable so tests/ ... without touching production behavior").
# Without this, every run of this selftest would spawn a real `claude -p`
# Sonnet subagent call (confirmed by a manual dry run while developing this
# selftest — it produced a genuine, several-hundred-word review) — correct
# production behavior, but wrong for a selftest meant to be re-run cheaply
# and deterministically. Disabling it only removes one producer's live
# network call; the concurrency guarantee under test does not depend on
# what any individual producer checks (isolation, not correctness — see the
# PRD's own Non-goals).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
for bin in git jq flock fuser cargo autobuilder; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/extend-gate-concurrent-selftest.XXXXXX")"
trap 'kill %1 %2 2>/dev/null; [ -n "${EXTEND_GATE_CONCURRENT_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
MARKERS="$T/markers"
mkdir -p "$REPO/src" "$REPO/agent" "$REPO/tests" "$REPO/scripts" "$MARKERS"

# --- disposable rust-extend fixture (never mcphost, never any real repo) ---
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "gateconcurrent-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF

cat > "$REPO/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF

cat > "$REPO/tests/gateconcurrent_ac1.rs" <<'EOF'
use gateconcurrent_fixture::add;

#[test]
fn ac1_add_returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF

cat > "$REPO/agent/intent-card.json" <<'EOF'
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "gateconcurrent-fixture",
  "root_motivation": "Disposable fixture crate for extend-gate-concurrent-selftest.sh (PRD-build-extend-gate-concurrent-isolation) — not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/gateconcurrent_ac1.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none — fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give extend-gate-concurrent-selftest.sh a disposable rust-extend fixture"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-09T00:00:00Z"
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

# scripts/audit.sh — the sleep-instrumented fixture producer (see header):
# extend-gate.sh runs this unmodified as its own producer #1, immediately
# after taking the integration lock and before any receipt write. Marking
# its own start/end here, with a real multi-second sleep in between, is
# what makes the two concurrent invocations' producer-writing windows easy
# to prove non-overlapping without racing sub-second timing.
cat > "$REPO/scripts/audit.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
marker_dir="${GATECONCURRENT_MARKER_DIR:-}"
sleep_s="${GATECONCURRENT_AUDIT_SLEEP:-0}"
if [ -n "$marker_dir" ]; then
  printf '%s %s\n' "$$" "$EPOCHREALTIME" >> "$marker_dir/audit-start.log"
fi
if [ "$sleep_s" != "0" ]; then
  sleep "$sleep_s"
fi
if [ -n "$marker_dir" ]; then
  printf '%s %s\n' "$$" "$EPOCHREALTIME" >> "$marker_dir/audit-end.log"
fi
exit 0
EOF
chmod +x "$REPO/scripts/audit.sh"

# /target MUST be gitignored: extend-gate.sh refuses a dirty tree (AC2 of
# PRD-build-extend-gate-receipts) before any producer runs, and the FIRST
# invocation's own receipts/build output under target/ would otherwise
# dirty the tree for every subsequent invocation against this same repo —
# exactly the shared-checkout shape this PRD's fixture needs to exercise.
cat > "$REPO/.gitignore" <<'EOF'
/target
EOF

# Pre-generate Cargo.lock and commit it: without this, the FIRST
# invocation's own `cargo` calls would write a fresh, never-committed
# Cargo.lock, leaving the tree "dirty" (untracked file) for every
# subsequent invocation's own dirty-tree refusal (extend-gate.sh AC2) —
# a fixture-setup gap, not a real concurrency bug, but one that would
# make AC1/AC2 below untestable against a genuinely SHARED repo.
( cd "$REPO" && cargo generate-lockfile >/dev/null 2>&1 ) || true

git -C "$REPO" init -q
git -C "$REPO" -c user.name="extend-gate-concurrent-selftest" -c user.email="selftest@example.com" add -A
git -C "$REPO" -c user.name="extend-gate-concurrent-selftest" -c user.email="selftest@example.com" commit -q -m "initial"
git -C "$REPO" tag v0.1.0
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# Common env for every invocation below: never a real journal file, never
# a real reviewer subagent call (see header), route cargo through the
# shared concurrency budget shim per the standing build-skill contract.
COMMON_ENV=(
  "PATH=$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH"
  "REVIEWER_PROMPT=/nonexistent/extend-gate-concurrent-selftest-reviewer-prompt.md"
  "EXTEND_GATE_JOURNAL=$T/journal.md"
  "GATECONCURRENT_MARKER_DIR=$MARKERS"
)

TIMEOUT_S="${EXTEND_GATE_CONCURRENT_SELFTEST_TIMEOUT:-60}"

extract_gate_line() {
  grep -m1 '^gate: head=' "$1" 2>/dev/null || true
}

# =========================================================================
# AC1 + AC2 — two concurrent invocations against the SAME fixture repo
# =========================================================================
echo "=== AC1/AC2: two concurrent extend-gate.sh runs, one shared repo ==="

AUDIT_SLEEP=4
out1="$T/out1.log"; out2="$T/out2.log"
: > "$out1"; : > "$out2"

# --force on both: without it, whichever invocation acquires the lock
# SECOND at an unchanged HEAD hits the verdict cache (PRD-build-gate-delta-
# baseline P1) and replays instead of regenerating — correct, efficient
# production behavior, but it would make this test observe one real
# producer run plus one cache replay instead of the two independent,
# concurrent producer regenerations this PRD's isolation guarantee is
# actually about.

env "${COMMON_ENV[@]}" GATECONCURRENT_AUDIT_SLEEP="$AUDIT_SLEEP" \
  timeout -k 5 "$TIMEOUT_S" "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" --force >"$out1" 2>&1 &
pid1=$!
sleep 0.2
env "${COMMON_ENV[@]}" GATECONCURRENT_AUDIT_SLEEP="$AUDIT_SLEEP" \
  timeout -k 5 "$TIMEOUT_S" "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" --force >"$out2" 2>&1 &
pid2=$!

t_wait_start="$EPOCHREALTIME"
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
t_wait_end="$EPOCHREALTIME"
wall="$(awk -v a="$t_wait_start" -v b="$t_wait_end" 'BEGIN{printf "%.1f", (b-a)}')"

expect "AC1: run1 exits 0 (pass or delta-pass/block, but completes)" "[ $rc1 -eq 0 ] || [ $rc1 -eq 1 ]"
expect "AC1: run2 exits 0 (pass or delta-pass/block, but completes)" "[ $rc2 -eq 0 ] || [ $rc2 -eq 1 ]"
expect "AC1: neither run timed out (rc != 124/137)" "[ $rc1 -ne 124 ] && [ $rc1 -ne 137 ] && [ $rc2 -ne 124 ] && [ $rc2 -ne 137 ]"

line1="$(extract_gate_line "$out1")"
line2="$(extract_gate_line "$out2")"
expect "AC1: run1 produced a gate verdict line" "[ -n \"$line1\" ]"
expect "AC1: run2 produced a gate verdict line" "[ -n \"$line2\" ]"
expect "AC1: both invocations report an IDENTICAL gate line (no flip at the same HEAD)" "[ \"$line1\" = \"$line2\" ] && [ -n \"$line1\" ]"
echo "  run1: $line1"
echo "  run2: $line2"

# AC2: prove the two producer-writing windows never overlapped, using the
# sleep-instrumented scripts/audit.sh markers (start/end timestamps per
# invocation's OWN pid). If isolation were broken, two audit.sh runs could
# both be inside their sleep window at once; here that must never happen.
starts="$(sort -k2 -n "$MARKERS/audit-start.log" 2>/dev/null || true)"
ends="$(sort -k2 -n "$MARKERS/audit-end.log" 2>/dev/null || true)"
n_starts="$(printf '%s\n' "$starts" | grep -c . || true)"
n_ends="$(printf '%s\n' "$ends" | grep -c . || true)"
expect "AC2: exactly 2 audit.sh producer windows were recorded (one per invocation)" "[ \"$n_starts\" -eq 2 ] && [ \"$n_ends\" -eq 2 ]"

if [ "$n_starts" -eq 2 ] && [ "$n_ends" -eq 2 ]; then
  s1_pid=$(printf '%s\n' "$starts" | sed -n '1p' | awk '{print $1}')
  s1_ts=$(printf '%s\n' "$starts" | sed -n '1p' | awk '{print $2}')
  s2_pid=$(printf '%s\n' "$starts" | sed -n '2p' | awk '{print $1}')
  s2_ts=$(printf '%s\n' "$starts" | sed -n '2p' | awk '{print $2}')
  e1_ts=$(grep "^$s1_pid " "$MARKERS/audit-end.log" | awk '{print $2}')
  # The second invocation's audit.sh must not have STARTED before the
  # first invocation's audit.sh ENDED — i.e. the lock genuinely serialized
  # the two producer-writing phases rather than merely serializing the
  # final accounting step.
  expect "AC2: second invocation's producer phase starts only after the first's ends (no overlap)" \
    "awk -v s2=\"$s2_ts\" -v e1=\"$e1_ts\" 'BEGIN{exit !(s2 >= e1)}'"
  gap="$(awk -v s2="$s2_ts" -v e1="$e1_ts" 'BEGIN{printf "%.2f", (s2-e1)}')"
  echo "  serialization gap: ${gap}s (second invocation's audit.sh started this long after the first's audit.sh ended)"
  expect "AC2: distinct PIDs ran the two producer phases (genuinely two separate invocations)" "[ \"$s1_pid\" != \"$s2_pid\" ]"
fi

expect "AC1/AC2: total wall time bounded (no deadlock, < 2x per-run timeout)" "awk -v w=\"$wall\" -v t=\"$TIMEOUT_S\" 'BEGIN{exit !(w < 2*t)}'"
echo "  total wall time for both concurrent runs: ${wall}s"

# =========================================================================
# AC3 — bounded wait, explicit fail-closed on producer-lock contention
# =========================================================================
echo "=== AC3: producer-lock contended past the configured ceiling ==="

# Let AC1/AC2's cargo/rustc activity fully quiesce first — `fuser` reads
# live /proc state, and a just-exited compiler subprocess's pid can still
# be transiently visible (or its inode reused by another fixture) for a
# few hundred ms after `wait` returns, which would otherwise pollute the
# "who holds this lock" signal below with unrelated noise.
sleep 1

LOCKFILE="$REPO/.git/autobuilder-integrate.lock"
# Externally hold the SAME lock extend-gate.sh takes, for longer than the
# short ceiling we're about to give the invocation under test. Bash's own
# tail-call optimization (last simple command in a subshell, no job
# control) execs `sleep` in place of the subshell here, so $! (holder_job)
# IS the pid that actually holds the flock — verified directly rather than
# inferred, so this doesn't depend on that optimization either.
( exec 9>"$LOCKFILE"; flock -x 9; sleep 8 ) &
holder_job=$!
# Give the holder a moment to actually acquire the flock before racing it.
sleep 0.3
holder_alive() { kill -0 "$holder_job" 2>/dev/null; }
expect "AC3 setup: external holder process is alive" "holder_alive"
holder_pids="$(fuser "$LOCKFILE" 2>/dev/null | tr -s ' \t' '\n' | grep -E '^[0-9]+$' | sort -u)"
expect "AC3 setup: fuser confirms the known holder pid ($holder_job) has the lock file open" \
  "printf '%s\n' \"$holder_pids\" | grep -qx \"$holder_job\""

ac3_out="$T/ac3.log"
t0="$EPOCHREALTIME"
env "${COMMON_ENV[@]}" EXTEND_GATE_PRODUCER_LOCK_WAIT=2 \
  timeout -k 5 20 "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" >"$ac3_out" 2>&1
ac3_rc=$?
t1="$EPOCHREALTIME"
ac3_wall="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)}')"

expect "AC3: contended invocation exits non-zero" "[ $ac3_rc -ne 0 ]"
expect "AC3: contended invocation exits with the documented lock-contention code (4)" "[ $ac3_rc -eq 4 ]"
expect "AC3: failure message names the reserved phrase producer-lock-contended" "grep -q 'producer-lock-contended' \"$ac3_out\""
expect "AC3: failure message names a pid=" "grep -qE 'pid=[0-9]+(,[0-9]+)*' \"$ac3_out\""

pid_named_includes_known_holder() {
  local pid_in_msg
  pid_in_msg="$(grep -oE 'pid=[0-9]+(,[0-9]+)*' "$ac3_out" | head -1 | sed 's/pid=//')"
  [ -n "$pid_in_msg" ] || return 1
  # Ground-truth check against $holder_job (the pid we ourselves started
  # and independently confirmed above via kill -0 and fuser) rather than
  # a second fuser snapshot — fuser reports every pid with the file open,
  # which can include transient noise a split second apart, but the
  # actually-known holder must always be among the names extend-gate.sh
  # prints, or the message isn't naming a real, actionable pid.
  printf '%s\n' "$pid_in_msg" | tr ',' '\n' | grep -qx "$holder_job"
}
expect "AC3: named pid includes the actual known external holder ($holder_job)" "pid_named_includes_known_holder"
expect "AC3: no gate verdict line was ever printed (fail-closed, not fail-wrong)" "! grep -q '^gate: head=' \"$ac3_out\""
expect "AC3: bounded wait — completed near the 2s ceiling, not the 8s holder sleep or a hang" "awk -v w=\"$ac3_wall\" 'BEGIN{exit !(w < 6)}'"
echo "  ac3 wall time: ${ac3_wall}s rc=$ac3_rc"

wait "$holder_job" 2>/dev/null || true

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "extend-gate-concurrent-selftest: ALL PASS"
  exit 0
else
  echo "extend-gate-concurrent-selftest: assertion(s) FAILED"
  exit 1
fi
