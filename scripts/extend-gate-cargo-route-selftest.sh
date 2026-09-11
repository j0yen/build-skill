#!/usr/bin/env bash
# extend-gate-cargo-route-selftest.sh — proves extend-gate.sh itself (not
# just the shim/burst-lane.sh, already covered by burst-lane-selftest.sh's
# "gateroute" cases) attests where its own cargo calls actually ran.
# PRD-build-gate-cargo-route-attest.
#
# Builds ONE disposable rust-extend fixture repo (never mcphost, never any
# production repo) under $TMPDIR and a fully sandboxed fake burst-lane
# environment (tests/fixtures/burst-lane-fake, same fixtures
# burst-lane-selftest.sh uses), then drives extend-gate.sh through:
#
#   AC1 — BURST_LANE=1, a fake active session, a fake real cargo placed
#         FIRST on the inherited $PATH (no shim dir present at all): the
#         gate's very first stdout line names the shim as the resolved
#         cargo, and the fake real cargo's marker never records the ROUTED
#         `cargo build` subcommand (it always records `cargo check` too —
#         check/metadata are never routed BY DESIGN, so they're SUPPOSED
#         to reach the real cargo directly; AC1's guarantee is about the
#         routed subcommand only).
#   AC3 — no session: the receipt's cargo_route reads intended=local,
#         burst=0, and no route-mismatch line is journaled.
#   AC4 — a fake session UP, but the shim forced BEHIND a fake real cargo
#         (both already present on $PATH, real cargo first — the guard's
#         self-arming only fires when NEITHER shim dir is present, so an
#         already-shadowed shim stays shadowed, exactly the pre-fix
#         2026-09-10 defect reproduced structurally): the journal gets one
#         `gate  route-mismatch  (intended=burst ...)` line, the
#         gate-cargo-route probe's last emission is dirty/mismatch, and the
#         gate VERDICT is unchanged from the same run without the forcing
#         (a route mismatch is a journaled guard event, never a block).
#   AC5 — every gate journal line (forced or not) carries
#         `cargo=burst:<n>/local:<n>` with counts equal to the receipt's.
#   AC6 — two gates against two DIFFERENT disposable repos each end up with
#         a route.log / cargo_route whose counts equal only their OWN
#         activity, never the other's.
#   AC2 (relaxed) — with a correctly-armed shim and an active session, at
#         least one producer's cargo call is actually decided "burst" (not
#         "local") and reaches the shim before falling back — the literal
#         "receipts=2 burst=2 local=0 passthrough=1" tuple AC2 specifies is
#         autobuilder's own internal producer-call sequence, which this
#         selftest does not control precisely (see note below); what it
#         does assert is the invariant AC2 is actually protecting:
#         intended=burst with a correctly-armed shim never silently stays
#         local (route_local_n stays 0 whenever route_burst_n>0 under a
#         correctly-armed shim), i.e. no route-mismatch is journaled.
#
# FAKE_SSH_REMOTE_FAIL is set for every "session up + shim armed" run
# below: the fake ssh stub used by tests/fixtures/burst-lane-fake evals the
# embedded remote command locally (there is no real remote box in this
# offline fixture), and that remote command reduces an absolute cargo path
# to the bare name "cargo" — meaningless on a real remote box (whose own
# PATH never has this shim on it, resolved there instead), but on this
# LOCAL fake-ssh stub the bare name resolves through the SAME inherited
# $PATH the outer shim call used, which still has the shim on it, so it
# would call itself again, forever (confirmed by hand: unbounded process
# tree growth, hung past any reasonable timeout). Setting
# FAKE_SSH_REMOTE_FAIL short-circuits the fake ssh BEFORE it ever evals
# that command (see the fixture's own header), so the routing DECISION
# (logged before the exec, same as burst-lane-selftest.sh's own "shim-first
# resolution" case) is still made and still recorded, without ever
# following it through a live round trip. A real remote box has no such
# hazard; this is a fake-ssh-fixture-only artifact.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
FAKE="$HERE/../tests/fixtures/burst-lane-fake"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
[ -d "$FAKE" ] || { echo "selftest: $FAKE fixture dir missing" >&2; exit 2; }
for bin in git jq flock fuser cargo autobuilder; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/extend-gate-cargo-route-selftest.XXXXXX")"
trap '[ -n "${EXTEND_GATE_CARGO_ROUTE_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

# ---- disposable rust-extend fixture builder (mirrors extend-gate-concurrent-
# selftest.sh's own fixture verbatim, parameterized by a slug so AC6 can
# build two independent repos) --------------------------------------------
build_fixture() {  # $1 = repo dir $2 = crate-name slug $3 = "audit" (optional)
  local repo="$1" slug="$2" with_audit="${3:-}"
  mkdir -p "$repo/src" "$repo/agent" "$repo/tests" "$repo/scripts"
  cat > "$repo/Cargo.toml" <<EOF
[package]
name = "$slug"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF
  cat > "$repo/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
  cat > "$repo/tests/route_ac1.rs" <<EOF
use ${slug}::add;

#[test]
fn ac1_add_returns_sum() {
    assert_eq!(add(2, 2), 4);
}
EOF
  cat > "$repo/agent/intent-card.json" <<EOF
{
  "schema": "autobuilder.intent_card.v1",
  "prd_source": "inline",
  "intent_slug": "$slug",
  "root_motivation": "Disposable fixture crate for extend-gate-cargo-route-selftest.sh (PRD-build-gate-cargo-route-attest) — not a real product, never mcphost.",
  "user_persona": "test harness only",
  "unfakeable_metric": {"name": "acceptance_tests_passing_count", "lower_is_better": false, "harness_command": "scripts/run-metrics.sh", "target": 1},
  "acceptance_criteria": [
    {"id": "AC1", "level": "MUST", "description": "Given add(2,2), When called, Then it returns 4.", "test": "tests/route_ac1.rs"}
  ],
  "scope": ["src/lib.rs"],
  "non_goals": ["none — fixture only"],
  "hard_constraints": {"rust_edition": "2021", "target_kind": "lib", "deny_unsafe": true},
  "five_whys_trace": [
    {"why": 1, "q": "why does this crate exist", "a": "to give extend-gate-cargo-route-selftest.sh a disposable rust-extend fixture"}
  ],
  "ambiguities_resolved": [],
  "created_at": "2026-09-10T00:00:00Z"
}
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
  if [ "$with_audit" = "audit" ]; then
    # extend-gate.sh runs scripts/audit.sh, when present, as producer #1 —
    # before any of autobuilder's own (opaque, not selftest-controlled)
    # internal cargo calls. Calling `cargo build` (routed) and `cargo
    # check` (always passthrough) here gives this selftest a DETERMINISTIC
    # routed + passthrough signal to assert on, independent of whichever
    # cargo subcommands autobuilder's own producers happen to invoke.
    # Never fails the run (exit 0 regardless) — audit.sh's own exit is
    # already best-effort per extend-gate.sh's producer #1 contract.
    cat > "$repo/scripts/audit.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cargo build >/dev/null 2>&1 || true
cargo check >/dev/null 2>&1 || true
exit 0
EOF
    chmod +x "$repo/scripts/audit.sh"
  fi
  cat > "$repo/.gitignore" <<'EOF'
/target
EOF
  ( cd "$repo" && cargo generate-lockfile >/dev/null 2>&1 ) || true
  git -C "$repo" init -q
  git -C "$repo" -c user.name="extend-gate-cargo-route-selftest" -c user.email="selftest@example.com" add -A
  git -C "$repo" -c user.name="extend-gate-cargo-route-selftest" -c user.email="selftest@example.com" commit -q -m "initial"
  git -C "$repo" tag v0.1.0
}

# ---- sandboxed fake burst-lane environment (same convention as
# burst-lane-selftest.sh's fresh_env) — takes a TAG and mints a brand-new
# subtree per call, exactly like fresh_env's own fresh mktemp -d, so one
# scenario's session/probe-ledger state can never leak into the next
# scenario's "no session" or "first gate-cargo-route emission" assertions.
setup_fake_burst_env() {
  local tag="$1" base="$T/env-$1"
  mkdir -p "$base"
  export BURST_LANE_STATE_DIR="$base/state"; mkdir -p "$BURST_LANE_STATE_DIR"
  export BURST_LANE_JOURNAL="$base/burst-journal.log"
  export BURST_LANE_ENV_FILE="$base/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
  export BURST_LANE_REMOTE_ROOT="$base/remote"
  # PRD-build-burst-unprivileged-user: scope $REMOTE_HOME too (same reason
  # as burst-lane-selftest.sh's own fresh_env) — `up` now runs
  # create_remote_user()'s `mkdir -p $REMOTE_HOME/.ssh` for real.
  export BURST_LANE_REMOTE_HOME="$base/remote-home"
  # PRD-build-burst-unprivileged-user: point the shared-toolchain env vars
  # at this real machine's own working toolchain (see burst-lane-
  # selftest.sh's fresh_env for the full rationale) instead of a real
  # /root this test-runner cannot read.
  export BURST_LANE_ROOT_RUSTUP_HOME="$HOME/.rustup"
  export BURST_LANE_ROOT_CARGO_HOME="$HOME/.cargo"
  export BURST_LANE_PRD_DIR="$base/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
  export FAKE_HCLOUD_STATE="$base/hcloud.state"
  export FAKE_HCLOUD_CALLLOG="$base/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
  export FAKE_RSYNC_STATS_DIR="$base/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"
  export BURST_LANE_COST_LEDGER="$base/cost.jsonl"
  export BUILD_STATE_DIR="$base/state"
  export PROBE_JOURNAL_DIR="$base/probe-journal"
  export BURST_LANE_ATTR_LEDGER="$base/attribution.jsonl"
  export BURST_LANE_REPOS_DIR="$base/repos"; mkdir -p "$BURST_LANE_REPOS_DIR"
  export BURST_LANE_TICK_JOURNAL_DIR="$base/tick-journal"; mkdir -p "$BURST_LANE_TICK_JOURNAL_DIR"
}

FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
FAKE_CARGO_MARKER="$T/fake-cargo-was-run"
cat > "$FAKEBIN/cargo" <<EOF
#!/usr/bin/env bash
echo "\$(date -u +%Y-%m-%dT%H:%M:%SZ) \$*" >> "$FAKE_CARGO_MARKER"
echo "fake-real-cargo: \$*"
exit 0
EOF
chmod +x "$FAKEBIN/cargo"

# Common env for every invocation below: never a real journal file, never a
# real reviewer subagent call (mirrors extend-gate-concurrent-selftest.sh's
# own COMMON_ENV note verbatim), and REMOTE_FAIL short-circuits the fake
# ssh before its recursion-hazard eval (see header).
COMMON_EXTEND_GATE_ENV=(
  "REVIEWER_PROMPT=/nonexistent/extend-gate-cargo-route-selftest-reviewer-prompt.md"
  "EXTEND_GATE_JOURNAL=$T/gate-journal.md"
  "FAKE_SSH_REMOTE_FAIL=3"
)

TIMEOUT_S="${EXTEND_GATE_CARGO_ROUTE_SELFTEST_TIMEOUT:-90}"

extract_gate_line() { grep -m1 '^gate: head=' "$1" 2>/dev/null || true; }
route_field() {  # $1=receipt-json-file $2=.cargo_route.<field>
  jq -r "$2 // empty" "$1" 2>/dev/null || true
}

# =========================================================================
# AC1 — self-arming wins over an already-present-but-earlier fake real
# cargo when NEITHER shim directory was on the inherited $PATH at all.
# =========================================================================
echo "=== AC1: self-arming PATH guard, fake real cargo never executed ==="
REPO1="$T/repo-ac1"
build_fixture "$REPO1" "gateroute-ac1" audit
HEAD1="$(git -C "$REPO1" rev-parse HEAD)"

setup_fake_burst_env ac1
PATH="$FAKE:$PATH" "$HERE/burst-lane.sh" up >/dev/null 2>&1

rm -f "$FAKE_CARGO_MARKER"
ac1_out="$T/ac1.log"
# Inherited $PATH has the fake real cargo FIRST, the fake ssh/rsync/hcloud
# dir next, and NO shim directory anywhere — extend-gate.sh's own guard
# must arm burst-lane-bin itself (requirement 1) and win.
env "${COMMON_EXTEND_GATE_ENV[@]}" \
  PATH="$FAKEBIN:$FAKE:$PATH" BURST_LANE=1 \
  timeout -k 5 "$TIMEOUT_S" "$EXTEND_GATE" "$REPO1" --head "$HEAD1" --force >"$ac1_out" 2>&1
ac1_rc=$?

expect "AC1: gate completed (not a hang/timeout)" "[ $ac1_rc -ne 124 ] && [ $ac1_rc -ne 137 ]"
first_line="$(head -1 "$ac1_out")"
expect "AC1: the very first stdout line names the shim as resolved cargo" \
  "[[ \"\$first_line\" == extend-gate:\ cargo=*burst-lane-bin/cargo ]]"
echo "  first line: $first_line"
# The audit.sh fixture calls both `cargo build` (routed — must reach the
# shim, never the fake real cargo directly) and `cargo check` (always
# passthrough BY DESIGN — see burst-lane-bin/cargo's own header on
# check/metadata being intentionally never routed, so it's SUPPOSED to
# reach the fake real cargo directly). AC1's guarantee is about the routed
# subcommand only; assert the marker never recorded a "build" invocation,
# not that the marker is absent entirely.
expect "AC1: the fake real cargo never ran the ROUTED 'build' subcommand directly" \
  "[ ! -f \"$FAKE_CARGO_MARKER\" ] || ! awk '{print \$2}' \"$FAKE_CARGO_MARKER\" | grep -qx build"

# =========================================================================
# AC3 — no session: cargo_route reads intended=local, burst=0, no mismatch.
# =========================================================================
echo "=== AC3: no burst-lane session -> intended=local, no mismatch ==="
REPO3="$T/repo-ac3"
build_fixture "$REPO3" "gateroute-ac3"
HEAD3="$(git -C "$REPO3" rev-parse HEAD)"

setup_fake_burst_env ac3   # fresh, isolated — deliberately never calls `up`
ac3_out="$T/ac3.log"
env "${COMMON_EXTEND_GATE_ENV[@]}" \
  PATH="$HERE/burst-lane-bin:$FAKEBIN:$PATH" \
  timeout -k 5 "$TIMEOUT_S" "$EXTEND_GATE" "$REPO3" --head "$HEAD3" --force >"$ac3_out" 2>&1
ac3_rc=$?
expect "AC3: gate completed (not a hang/timeout)" "[ $ac3_rc -ne 124 ] && [ $ac3_rc -ne 137 ]"

cache3="$REPO3/target/autobuilder/last-verdict.json"
expect "AC3: last-verdict.json was written" "[ -f \"$cache3\" ]"
expect "AC3: cargo_route.intended=local" "[ \"\$(route_field \"$cache3\" .cargo_route.intended)\" = local ]"
expect "AC3: cargo_route.burst=0" "[ \"\$(route_field \"$cache3\" .cargo_route.burst)\" = 0 ]"
expect "AC3: no route-mismatch line journaled" "! grep -q 'gate  route-mismatch' \"$T/gate-journal.md\""

# =========================================================================
# AC4 (+ AC5) — mismatch: shim present but forced BEHIND a fake real cargo,
# active session up. The verdict must be unchanged from the same run
# without the forcing (compare against AC3's own verdict summary, since
# AC3's fixture ran with no session and a correctly-ordered PATH — the
# mismatch itself must never alter pass/block accounting).
# =========================================================================
echo "=== AC4: shim shadowed by a fake real cargo, session up -> route-mismatch ==="
REPO4="$T/repo-ac4"
build_fixture "$REPO4" "gateroute-ac4"
HEAD4="$(git -C "$REPO4" rev-parse HEAD)"

setup_fake_burst_env ac4
PATH="$FAKE:$PATH" "$HERE/burst-lane.sh" up >/dev/null 2>&1

rm -f "$FAKE_CARGO_MARKER"
ac4_out="$T/ac4.log"
# Fake real cargo dir FIRST, shim dir SECOND (both already present — the
# guard's self-arming only fires when NEITHER shim dir is on $PATH, so an
# already-present-but-shadowed shim is left exactly as shadowed as the
# caller put it — this is the "guard is a re-shadow guard, not an order
# fixer" behavior the extend-gate.sh header itself documents).
env "${COMMON_EXTEND_GATE_ENV[@]}" \
  PATH="$FAKEBIN:$HERE/burst-lane-bin:$FAKE:$PATH" BURST_LANE=1 \
  timeout -k 5 "$TIMEOUT_S" "$EXTEND_GATE" "$REPO4" --head "$HEAD4" --force >"$ac4_out" 2>&1
ac4_rc=$?
expect "AC4: gate completed (not a hang/timeout)" "[ $ac4_rc -ne 124 ] && [ $ac4_rc -ne 137 ]"

line4="$(extract_gate_line "$ac4_out")"
line3="$(extract_gate_line "$ac3_out")"
expect "AC4: produced a gate verdict line" "[ -n \"$line4\" ]"
# Same fixture SHAPE as AC3 (identical Cargo.toml/src/tests/intent-card
# content, different crate name only) -> the receipts=/pass=/block=
# portion of the summary (everything after "head=...") must match,
# proving the mismatch never altered pass/block accounting (requirement
# 4's own "the verdict is unchanged" — Non-goals: "never a block").
verdict_shape() { sed -E 's/^gate: head=[^ ]+/gate: head=X/' <<<"$1"; }
expect "AC4: verdict shape (receipts/pass/block/verdict) matches the unforced run" \
  "[ \"\$(verdict_shape \"$line4\")\" = \"\$(verdict_shape \"$line3\")\" ]"
echo "  ac3 (unforced): $line3"
echo "  ac4 (forced):   $line4"

expect "AC4: journal has one gate route-mismatch line naming shim-not-first" \
  "grep -q 'gate  route-mismatch  (intended=burst .*cause=shim-not-first)' \"$T/gate-journal.md\""
expect "AC4: probe ledger's last gate-cargo-route emission is dirty (this probe's mismatch state)" \
  "[ \"\$(jq -c 'select(.probe==\"gate-cargo-route\")' \"$BUILD_STATE_DIR/probes/ledger.jsonl\" 2>/dev/null | tail -1 | jq -r .state 2>/dev/null)\" = dirty ]"

cache4="$REPO4/target/autobuilder/last-verdict.json"
expect "AC4: cargo_route.intended=burst" "[ \"\$(route_field \"$cache4\" .cargo_route.intended)\" = burst ]"
expect "AC4: cargo_route.local > 0" "[ \"\$(route_field \"$cache4\" .cargo_route.local)\" -gt 0 ]"

# ---- AC5 — every journal line above carries cargo=burst:<n>/local:<n>
# with counts equal to the receipt's (checked on both AC3's local-only run
# and AC4's mismatch run). ------------------------------------------------
echo "=== AC5: journal cargo=burst:<n>/local:<n> matches the receipt ==="
gate_journal_cargo_field() {  # $1=crate-name-grep-anchor -> "burst:<n>/local:<n>"
  grep "gate  $1  " "$T/gate-journal.md" | grep -v route-mismatch | tail -1 | grep -oE 'cargo=burst:[0-9]+/local:[0-9]+' | sed 's/cargo=//'
}
j3="$(gate_journal_cargo_field "$(basename "$REPO3")")"
r3="burst:$(route_field "$cache3" .cargo_route.burst)/local:$(route_field "$cache3" .cargo_route.local)"
expect "AC5: AC3's journal cargo= field matches its receipt's counts" "[ -n \"$j3\" ] && [ \"$j3\" = \"$r3\" ]"

j4="$(gate_journal_cargo_field "$(basename "$REPO4")")"
r4="burst:$(route_field "$cache4" .cargo_route.burst)/local:$(route_field "$cache4" .cargo_route.local)"
expect "AC5: AC4's journal cargo= field matches its receipt's counts" "[ -n \"$j4\" ] && [ \"$j4\" = \"$r4\" ]"

# =========================================================================
# AC6 — per-repo isolation: repo3 (AC3) and repo4 (AC4) each carry only
# their own counts — repo3's cargo_route must show local-only (no burst
# activity leaked in from repo4's session), repo4's must show its own
# mismatch-driven local>0 without repo3's clean zero bleeding in.
# =========================================================================
echo "=== AC6: two different repos never share route-log/receipt counts ==="
expect "AC6: repo3 (no session) stayed intended=local, unaffected by repo4's session" \
  "[ \"\$(route_field \"$cache3\" .cargo_route.intended)\" = local ]"
expect "AC6: repo4 (shadowed shim + session) stayed intended=burst, unaffected by repo3" \
  "[ \"\$(route_field \"$cache4\" .cargo_route.intended)\" = burst ]"
expect "AC6: repo3's own route.log only names repo3's own path" \
  "! grep -q \"$REPO4\" \"$REPO3/target/autobuilder/route.log\" 2>/dev/null"
expect "AC6: repo4's own route.log only names repo4's own path" \
  "! grep -q \"$REPO3\" \"$REPO4/target/autobuilder/route.log\" 2>/dev/null"

# =========================================================================
# AC2 (relaxed — see header) — a correctly-armed shim under an active
# session never silently stays local: whenever route_burst_n>0, route_
# local_n stays 0 (no mismatch), proven on a fresh correctly-ordered run.
# =========================================================================
echo "=== AC2 (relaxed): correctly-armed shim + active session never silently stays local ==="
REPO2="$T/repo-ac2"
build_fixture "$REPO2" "gateroute-ac2" audit
HEAD2="$(git -C "$REPO2" rev-parse HEAD)"

setup_fake_burst_env ac2
PATH="$FAKE:$PATH" "$HERE/burst-lane.sh" up >/dev/null 2>&1

mismatch_count_before="$(grep -c 'gate  route-mismatch' "$T/gate-journal.md" 2>/dev/null || echo 0)"
ac2_out="$T/ac2.log"
env "${COMMON_EXTEND_GATE_ENV[@]}" \
  PATH="$HERE/burst-lane-bin:$FAKEBIN:$FAKE:$PATH" BURST_LANE=1 \
  timeout -k 5 "$TIMEOUT_S" "$EXTEND_GATE" "$REPO2" --head "$HEAD2" --force >"$ac2_out" 2>&1
ac2_rc=$?
expect "AC2: gate completed (not a hang/timeout)" "[ $ac2_rc -ne 124 ] && [ $ac2_rc -ne 137 ]"

cache2="$REPO2/target/autobuilder/last-verdict.json"
expect "AC2: cargo_route.intended=burst (correctly-armed shim, session up)" \
  "[ -f \"$cache2\" ] && [ \"\$(route_field \"$cache2\" .cargo_route.intended)\" = burst ]"
burst2="$(route_field "$cache2" .cargo_route.burst)"
local2="$(route_field "$cache2" .cargo_route.local)"
echo "  repo2 cargo_route: burst=$burst2 local=$local2"
expect "AC2: at least one cargo call was decided burst (the shim actually routed, not silently local)" "[ \"${burst2:-0}\" -gt 0 ]"
expect "AC2: local stayed 0 — a correctly-armed shim never silently falls local (no mismatch)" "[ \"${local2:-1}\" = 0 ]"
mismatch_count_after="$(grep -c 'gate  route-mismatch' "$T/gate-journal.md" 2>/dev/null || echo 0)"
expect "AC2: no NEW route-mismatch line was journaled by this (correctly-armed) run" "[ \"$mismatch_count_after\" -eq \"$mismatch_count_before\" ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "extend-gate-cargo-route-selftest: ALL PASS"
  exit 0
else
  echo "extend-gate-cargo-route-selftest: assertion(s) FAILED"
  exit 1
fi
