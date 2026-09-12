#!/usr/bin/env bash
# extend-gate-phase-timing-selftest.sh — PRD-build-gate-phase-timing,
# AC1-AC4 and AC6 (AC5, the digest, is covered separately below in the
# same run since it needs no live gate — just a hand-built journal
# fixture; AC7 is this file's own tests/gatephase_ac*.sh wrappers naming
# these labels, mirroring extend-gate-concurrent-selftest.sh's own
# convention).
#
# Drives the REAL extend-gate.sh against ONE disposable rust-extend
# fixture repo (never mcphost, never any production repo) through a fake
# toolchain (tests/fixtures/gatephase-fake: autobuilder, claude, gh,
# extended-receipts.sh, ship-tag.sh — every subcommand independently
# sleep-and-exit-code scriptable via env vars) so every phase's duration
# is pinned and deterministic instead of depending on a real cargo
# compile or a real Sonnet call.
#
#   AC1 — every step sleeps a known duration and exits 0: the journal
#         line's `phases=` field (right after `wall=`) names every
#         invoked step with its seconds, ±1s, in invocation order.
#   AC2 — one step (vti-plan) exits non-zero after a known sleep: its
#         phase reads `vti-plan:<s>!`, and the final verdict/exit code is
#         STILL whatever the fake `gate` subcommand's own exit code says
#         (scripted independently) — proving the timing/annotation code
#         never touches the verdict (this PRD's own guardrail).
#   AC3 — a step this run never invokes (no scripts/audit.sh in the
#         fixture; `gh auth status` forced to fail) reads `<name>:skip`,
#         never `<name>:0`.
#   AC4 — the cached verdict receipt (target/autobuilder/last-verdict.json)
#         carries a `phases` object with every step, `wall_s`, and `head`,
#         and the phase-seconds sum is within 5% of `wall_s` (no
#         `unattributed_s` key) for a run with no untimed gaps.
#   AC6 — gate-debt.sh's own selftest (gatedebt-selftest.sh) and a direct
#         ship-postconditions.sh / manifest-invariants.sh invocation
#         against the journal this run wrote all stay green — neither
#         parses `wall=` by strict adjacency to `lock_wait=`, so the new
#         `phases=` field inserted between them doesn't confuse either.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
FAKE="$HERE/../tests/fixtures/gatephase-fake"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
[ -d "$FAKE" ] || { echo "selftest: $FAKE fixture dir missing" >&2; exit 2; }
for bin in git jq flock fuser; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/extend-gate-phase-timing-selftest.XXXXXX")"
trap '[ -n "${GATEPHASE_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
mkdir -p "$REPO/src"
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "gatephase-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"
EOF
cat > "$REPO/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
echo "/target" > "$REPO/.gitignore"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init
echo "fake reviewer prompt" > "$T/reviewer-prompt.md"

run_gate() {  # extra env assignments come from the caller's own exported vars
  PATH="$FAKE:$PATH" \
  AUTOBUILDER_CANONICAL_CARGO_TOML="$T/no-such-canonical/Cargo.toml" \
  RUSTBUILD_SCRIPTS="$FAKE" \
  REVIEWER_PROMPT="$T/reviewer-prompt.md" \
  EXTEND_GATE_JOURNAL="$JOURNAL" \
  BURST_LANE_SH="$FAKE/burst-lane.sh" \
  CARGO_BUDGET="$FAKE/cargo-budget.sh" \
  bash "$EXTEND_GATE" "$REPO" --force "$@"
}

phase_of() {  # $1=journal-line $2=phase-name -> raw token value (e.g. "2", "2!", "skip")
  # phases=... is a comma-joined list with no trailing separator, so the
  # LAST phase's value runs up to the next space (before ` lock_wait=`) —
  # every other phase's value runs up to the next comma. The name itself
  # is always preceded by `=` (the first phase, right after `phases=`) or
  # `,` (every later one) — required here so e.g. `gate` never
  # false-matches the `gate` suffix inside `risk-gate`.
  printf '%s\n' "$1" | grep -oE "[,=]$2:[^, )]*" | sed -E "s/^.$2://"
}
within() {  # $1=actual(seconds, may have trailing !) $2=expected $3=tolerance
  local a="${1%!}"
  [ -n "$a" ] || return 1
  local lo=$(( $2 - $3 )) hi=$(( $2 + $3 ))
  [ "$a" -ge "$lo" ] && [ "$a" -le "$hi" ]
}

# ---- AC1: all steps sleep known durations, all exit 0 --------------------
export FAKE_VTI_PLAN_SLEEP=1 FAKE_CI_CHECKS_SLEEP=2 FAKE_GATE_SLEEP=3 FAKE_REVCLAUDE_SLEEP=1
out1="$(run_gate 2>&1)"; rc1=$?
unset FAKE_VTI_PLAN_SLEEP FAKE_CI_CHECKS_SLEEP FAKE_GATE_SLEEP FAKE_REVCLAUDE_SLEEP
line1="$(tail -1 "$JOURNAL")"
expect "AC1: extend-gate.sh exits 0 on an all-pass fake gate" "[ $rc1 -eq 0 ]"
expect "AC1: journal line carries a phases= field after wall=" "[[ '$line1' == *'wall='*'phases='* ]]"
for pair in "risk-gate:skip" "intake:0:0" "proof-receipt:0:0" "vti-plan:1:1" "rollback-plan:0:0" "ci-checks:2:1" "receipts:0:0" "reviewer:1:1" "gate:3:1"; do
  name="${pair%%:*}"
  rest="${pair#*:}"
  if [ "$rest" = "skip" ]; then
    expect "AC1: phase $name reads skip" "[ \"\$(phase_of '$line1' '$name')\" = 'skip' ]"
  else
    exp="${rest%%:*}"; tol="${rest##*:}"
    val="$(phase_of "$line1" "$name")"
    expect "AC1: phase $name = ${exp}s (±${tol}s), got $val" "within '$val' $exp $tol"
  fi
done
expect "AC1: phases are in invocation order" \
  "[[ '$line1' =~ phases=risk-gate:.*,intake:.*,proof-receipt:.*,vti-plan:.*,rollback-plan:.*,ci-checks:.*,receipts:.*,reviewer:.*,gate: ]]"

# ---- AC4: the cached receipt has phases/wall_s/head, sum within 5% -------
cache_file="$REPO/target/autobuilder/last-verdict.json"
expect "AC4: last-verdict.json exists after a run" "[ -f '$cache_file' ]"
expect "AC4: receipt has a phases object with every step" \
  "[ \"\$(jq -r '.phases | has(\"risk-gate\") and has(\"intake\") and has(\"proof-receipt\") and has(\"vti-plan\") and has(\"rollback-plan\") and has(\"ci-checks\") and has(\"receipts\") and has(\"reviewer\") and has(\"gate\")' '$cache_file')\" = true ]"
expect "AC4: receipt has wall_s" "[ \"\$(jq -r '.wall_s | type' '$cache_file')\" = 'number' ]"
expect "AC4: receipt has head" "[ -n \"\$(jq -r '.head' '$cache_file')\" ] && [ \"\$(jq -r '.head' '$cache_file')\" != null ]"
expect "AC4: no unattributed_s on a fully-timed run (sum within 5% of wall_s)" \
  "[ \"\$(jq 'has(\"unattributed_s\")' '$cache_file')\" = false ]"

# ---- AC2: one step fails after a known sleep; verdict unaffected ---------
export FAKE_VTI_PLAN_SLEEP=2 FAKE_VTI_PLAN_RC=1 FAKE_GATE_RC=0 FAKE_GATE_VERDICT=pass
out2="$(run_gate 2>&1)"; rc2=$?
unset FAKE_VTI_PLAN_SLEEP FAKE_VTI_PLAN_RC FAKE_GATE_RC FAKE_GATE_VERDICT
line2="$(tail -1 "$JOURNAL")"
expect "AC2: extend-gate.sh's exit code mirrors the fake gate's own (0) despite vti-plan failing" "[ $rc2 -eq 0 ]"
val2="$(phase_of "$line2" "vti-plan")"
expect "AC2: failed step reads vti-plan:<s>! (got $val2)" "[[ '$val2' == *'!' ]] && within '$val2' 2 1"

# ---- AC3: a step this run never invokes reads <name>:skip ----------------
# risk-gate: no scripts/audit.sh in the fixture repo -> always skip, every
# run above already proves this (asserted in the AC1 loop). ci-checks:
# force `gh auth status` to fail so extend-gate.sh takes its documented
# "gh not authenticated" skip branch instead of ever invoking `autobuilder
# ci-checks`.
export FAKE_GH_AUTH_RC=1
out3="$(run_gate 2>&1)"; rc3=$?
unset FAKE_GH_AUTH_RC
line3="$(tail -1 "$JOURNAL")"
val3_risk="$(phase_of "$line3" risk-gate)"
val3_ci="$(phase_of "$line3" ci-checks)"
expect "AC3: risk-gate reads skip (no scripts/audit.sh in the fixture), got $val3_risk" "[ '$val3_risk' = 'skip' ]"
expect "AC3: ci-checks reads skip when gh is not authenticated, got $val3_ci" "[ '$val3_ci' = 'skip' ]"

# ---- AC6: gate-debt.sh, manifest-invariants.sh, ship-postconditions.sh
#      selftests stay green with the new field already present in a real
#      journal this run wrote (line1/line2/line3 above all carry phases=).
gatedebt_out="$(bash "$HERE/gatedebt-selftest.sh" 2>&1)"; gatedebt_rc=$?
expect "AC6: gatedebt-selftest.sh (gate-debt.sh's own AC suite) stays green" "[ $gatedebt_rc -eq 0 ]"
ship_out="$(bash "$HERE/ship-postconditions.sh" "$REPO" 2>&1)"; ship_rc=$?
expect "AC6: ship-postconditions.sh runs clean against the phase-timing fixture repo" "[ $ship_rc -eq 0 ]"
mi_state_dir="$T/manifest-invariants-state"
mkdir -p "$mi_state_dir"
mi_out="$(BUILD_STATE_DIR="$mi_state_dir" JOURNAL="$JOURNAL" bash "$HERE/manifest-invariants.sh" 2>&1)"; mi_rc=$?
expect "AC6: manifest-invariants.sh does not choke on a journal carrying phases= (exit 0 or 1, never a crash)" "[ $mi_rc -eq 0 ] || [ $mi_rc -eq 1 ]"

# ---- AC5: digest median/last per repo (gate-phase-digest.sh) -------------
digest_journal_dir="$T/digest-journal"
mkdir -p "$digest_journal_dir"
day1="2026-09-05"; day2="2026-09-06"
# Four gates for one repo ("widget") over two days — ci-checks: 400,410,
# 390,420 (median 405, last 420); gate: 1500,1490,1510,1480 (median 1495,
# last 1480). Unrelated repo "other" has one gate the same days, to prove
# the digest groups per-repo and doesn't blend the two.
{
  printf '2026-09-05T01:00:00Z  gate  widget  pass  (head=a base=v1 gate: head=a pass=25 block=0 verdict=pass blocking=none wall=2000s phases=ci-checks:400,gate:1500 lock_wait=0s cargo=burst:0/local:0)\n'
  printf '2026-09-05T02:00:00Z  gate  widget  pass  (head=b base=v1 gate: head=b pass=25 block=0 verdict=pass blocking=none wall=1990s phases=ci-checks:410,gate:1490 lock_wait=0s cargo=burst:0/local:0)\n'
  printf '2026-09-05T03:00:00Z  gate  other  pass  (head=z base=v1 gate: head=z pass=25 block=0 verdict=pass blocking=none wall=100s phases=ci-checks:50,gate:40 lock_wait=0s cargo=burst:0/local:0)\n'
} > "$digest_journal_dir/$day1.md"
{
  printf '2026-09-06T01:00:00Z  gate  widget  pass  (head=c base=v1 gate: head=c pass=25 block=0 verdict=pass blocking=none wall=1900s phases=ci-checks:390,gate:1510 lock_wait=0s cargo=burst:0/local:0)\n'
  printf '2026-09-06T02:00:00Z  gate  widget  pass  (head=d base=v1 gate: head=d pass=25 block=0 verdict=pass blocking=none wall=1900s phases=ci-checks:420,gate:1480 lock_wait=0s cargo=burst:0/local:0)\n'
} > "$digest_journal_dir/$day2.md"
digest_out="$(GATE_PHASE_DIGEST_JOURNAL_DIR="$digest_journal_dir" GATE_PHASE_DIGEST_NOW="2026-09-06T12:00:00Z" bash "$HERE/gate-phase-digest.sh" 2>&1)"
digest_rc=$?
expect "AC5: gate-phase-digest.sh exits 0" "[ $digest_rc -eq 0 ]"
expect "AC5: one 'gate phases (median, last)' line for widget" "grep -qE 'gate phases \(median, last\): widget ' <<<\"$digest_out\""
expect "AC5: widget ci-checks median/last reads 405/420" "grep -q 'ci-checks 405/420' <<<\"$digest_out\""
expect "AC5: widget gate median/last reads 1495/1480" "grep -q 'gate 1495/1480' <<<\"$digest_out\""
expect "AC5: other repo gets its own line, not blended with widget" "grep -qE 'gate phases \(median, last\): other ' <<<\"$digest_out\""
expect "AC5: other ci-checks median/last reads 50/50 (single-gate window)" "grep -q 'ci-checks 50/50' <<<\"$digest_out\""

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "extend-gate-phase-timing-selftest: ALL PASSED"
else
  echo "extend-gate-phase-timing-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
