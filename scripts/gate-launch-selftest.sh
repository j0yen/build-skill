#!/usr/bin/env bash
# gate-launch-selftest.sh — PRD-build-gate-launch-survives-tick. Exercises
# gate-launch.sh, gate-status.sh, and chain-guard.sh's gate-inflight
# consultation against a fake systemd-run/systemctl pair
# (tests/fixtures/gatelaunch-fake) that reproduces the real, observed
# 2026-09-15 behavior of `--collect` (a finished unit's properties become
# unreadable — LoadState=not-found — almost immediately, and a lying
# ExecMainStatus=0 default comes back for it) plus a fake extend-gate.sh
# controlled entirely by env vars. Never touches real systemd, real git
# repos beyond disposable fixtures, or the real journal.
#
# tests/gatelaunch_ac<N>_*.sh wrapper files each run this suite and
# require specific "ok  <label>" lines in its output — same pattern as
# tests/fixtures/gatephase-ac-common.sh / burst-lane-ac-common.sh: no
# separate, hand-duplicated per-AC test body, so an edit to the real
# gate-launch.sh/gate-status.sh/chain-guard.sh logic can't silently drop
# coverage without this suite itself failing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXDIR="$HERE/../tests/fixtures/gatelaunch-fake"
GATE_LAUNCH="$HERE/gate-launch.sh"
GATE_STATUS="$HERE/gate-status.sh"
CHAIN_GUARD="$HERE/chain-guard.sh"

for f in "$GATE_LAUNCH" "$GATE_STATUS" "$CHAIN_GUARD" "$FIXDIR/systemd-run" "$FIXDIR/systemctl" "$FIXDIR/extend-gate.sh"; do
  [ -x "$f" ] || { echo "gate-launch-selftest: missing/non-executable: $f" >&2; exit 2; }
done

fail=0
expect() { # <label> <shell-cond-string>
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-launch-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

new_repo() { # <name> -> path, a fresh git repo with one commit
  local d="$T/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo "$d"
}

# Every gate-launch.sh / gate-status.sh invocation below shares this env:
export FAKE_SYSTEMD_STATE_DIR="$T/systemd-state"
mkdir -p "$FAKE_SYSTEMD_STATE_DIR"
export GATE_LAUNCH_EXTEND_GATE="$FIXDIR/extend-gate.sh"
export GATE_LAUNCH_SYSTEMD_RUN="$FIXDIR/systemd-run"
export GATE_LAUNCH_SYSTEMCTL="$FIXDIR/systemctl"
export GATE_STATUS_SYSTEMCTL="$FIXDIR/systemctl"
export GATE_LAUNCH_BURST_ENV="$T/no-such-wm-burst-env"
export GATE_LAUNCH_CARGO_ROUTE_LIB="$T/no-such-cargo-route.sh"
export GATE_LAUNCH_JOURNAL="$T/gate-launch-journal.md"
export CHAIN_GUARD_JOURNAL="$T/chain-guard-journal.md"
export CHAIN_GUARD_GATE_STATUS="$GATE_STATUS"
export CHAIN_GUARD_GATE_LAUNCH="$GATE_LAUNCH"

# ---------------------------------------------------------------------------
# AC(a): launch writes marker + returns unit
# ---------------------------------------------------------------------------
echo "== AC(a): launch writes marker + returns unit =="
REPO_A="$(new_repo repo-a)"
SHA_A="$(git -C "$REPO_A" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-a"
unset FAKE_EXTEND_GATE_SLEEP FAKE_EXTEND_GATE_RC FAKE_EXTEND_GATE_WRITE_RECEIPT FAKE_EXTEND_GATE_VERDICT
export FAKE_EXTEND_GATE_SLEEP=2
unit_a="$("$GATE_LAUNCH" "$REPO_A" --head "$SHA_A" --scope main --slug slug-a 2>/dev/null)"
marker_a="$BUILD_STATE_DIR/gate-inflight/slug-a.json"
expect "prints a unit name" "[ -n \"$unit_a\" ]"
expect "unit name matches gate-<slug>-<sha7> shape" "[[ \"$unit_a\" == gate-slug-a-${SHA_A:0:7}* ]]"
expect "marker file was written" "[ -f \"$marker_a\" ]"
expect "marker has the launched unit" "[ \"\$(jq -r .unit \"$marker_a\")\" = \"$unit_a\" ]"
expect "marker has the requested head" "[ \"\$(jq -r .head \"$marker_a\")\" = \"$SHA_A\" ]"
expect "marker has the requested scope" "[ \"\$(jq -r .scope \"$marker_a\")\" = main ]"
expect "marker has the repo path" "[ \"\$(jq -r .repo \"$marker_a\")\" = \"$REPO_A\" ]"
expect "marker has a started_ts" "[ -n \"\$(jq -r .started_ts \"$marker_a\")\" ]"
expect "gate-status.sh sees it running while it's mid-flight" "[ \"\$(\"$GATE_STATUS\" slug-a)\" = running ]"
sleep 3

# ---------------------------------------------------------------------------
# AC(b): --wait returns the gate's own rc
# ---------------------------------------------------------------------------
echo "== AC(b): --wait returns the gate rc =="
REPO_B1="$(new_repo repo-b1)"
SHA_B1="$(git -C "$REPO_B1" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-b1"
export FAKE_EXTEND_GATE_SLEEP=1 FAKE_EXTEND_GATE_RC=0 FAKE_EXTEND_GATE_WRITE_RECEIPT=1 FAKE_EXTEND_GATE_VERDICT=pass
"$GATE_LAUNCH" "$REPO_B1" --head "$SHA_B1" --scope main --slug slug-b1 --wait >/dev/null 2>&1
rc_b1=$?
expect "pass fixture: --wait exits 0" "[ $rc_b1 -eq 0 ]"

REPO_B2="$(new_repo repo-b2)"
SHA_B2="$(git -C "$REPO_B2" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-b2"
export FAKE_EXTEND_GATE_SLEEP=1 FAKE_EXTEND_GATE_RC=1 FAKE_EXTEND_GATE_WRITE_RECEIPT=1 FAKE_EXTEND_GATE_VERDICT=block
"$GATE_LAUNCH" "$REPO_B2" --head "$SHA_B2" --scope main --slug slug-b2 --wait >/dev/null 2>&1
rc_b2=$?
expect "block fixture: --wait exits 1" "[ $rc_b2 -eq 1 ]"

# ---------------------------------------------------------------------------
# AC(c): already-running idempotence
# ---------------------------------------------------------------------------
echo "== AC(c): already-running idempotence =="
REPO_C="$(new_repo repo-c)"
SHA_C="$(git -C "$REPO_C" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-c"
export FAKE_EXTEND_GATE_SLEEP=3 FAKE_EXTEND_GATE_RC=0 FAKE_EXTEND_GATE_WRITE_RECEIPT=1
first_unit_c="$("$GATE_LAUNCH" "$REPO_C" --head "$SHA_C" --scope main --slug slug-c 2>/dev/null)"
second_unit_c="$("$GATE_LAUNCH" "$REPO_C" --head "$SHA_C" --scope main --slug slug-c 2>/dev/null)"
rc_second_c=$?
expect "second launch, same head, exits 0" "[ $rc_second_c -eq 0 ]"
expect "second launch prints the SAME unit" "[ \"$second_unit_c\" = \"$first_unit_c\" ]"
expect "already-running is journaled" "grep -q 'already-running' \"$GATE_LAUNCH_JOURNAL\""
sleep 4

# ---------------------------------------------------------------------------
# AC(d): head-conflict refusal
# ---------------------------------------------------------------------------
echo "== AC(d): head-conflict refusal =="
REPO_D="$(new_repo repo-d)"
SHA_D1="$(git -C "$REPO_D" rev-parse HEAD)"
git -C "$REPO_D" commit -q --allow-empty -m two
SHA_D2="$(git -C "$REPO_D" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-d"
export FAKE_EXTEND_GATE_SLEEP=3 FAKE_EXTEND_GATE_RC=0 FAKE_EXTEND_GATE_WRITE_RECEIPT=1
"$GATE_LAUNCH" "$REPO_D" --head "$SHA_D1" --scope main --slug slug-d >/dev/null 2>&1
"$GATE_LAUNCH" "$REPO_D" --head "$SHA_D2" --scope main --slug slug-d >/dev/null 2>&1
rc_conflict=$?
expect "a different head while active exits 2" "[ $rc_conflict -eq 2 ]"
expect "head-conflict is journaled" "grep -q 'head-conflict' \"$GATE_LAUNCH_JOURNAL\""
sleep 4

# ---------------------------------------------------------------------------
# AC(e): gate-status.sh reports `lost` when the unit vanished before a receipt
# ---------------------------------------------------------------------------
echo "== AC(e): status lost when the unit vanished before a receipt =="
REPO_E="$(new_repo repo-e)"
SHA_E="$(git -C "$REPO_E" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-e"
export FAKE_EXTEND_GATE_SLEEP=5 FAKE_EXTEND_GATE_WRITE_RECEIPT=0
unit_e="$("$GATE_LAUNCH" "$REPO_E" --head "$SHA_E" --scope main --slug slug-e 2>/dev/null)"
expect "gate-status.sh sees it running before the vanish" "[ \"\$(\"$GATE_STATUS\" slug-e)\" = running ]"
# Simulate the exact 2026-09-15 defect: the unit's cgroup is torn down with
# no trace and no receipt was ever written.
rm -rf "${FAKE_SYSTEMD_STATE_DIR:?}/$unit_e"
expect "gate-status.sh reports lost" "[ \"\$(\"$GATE_STATUS\" slug-e)\" = lost ]"

# A unit that vanishes AFTER writing a receipt is NOT lost — it's finished,
# read from the verdict cache (the --collect near-instant-GC path).
echo "== AC(e2): status finished:<rc> from receipts when the unit is already collected =="
REPO_E2="$(new_repo repo-e2)"
SHA_E2="$(git -C "$REPO_E2" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-e2"
export FAKE_EXTEND_GATE_SLEEP=1 FAKE_EXTEND_GATE_RC=0 FAKE_EXTEND_GATE_WRITE_RECEIPT=1 FAKE_EXTEND_GATE_VERDICT=block
unit_e2="$("$GATE_LAUNCH" "$REPO_E2" --head "$SHA_E2" --scope main --slug slug-e2 2>/dev/null)"
sleep 2
expect "gate-status.sh reads finished:1 from the collected unit's receipts" "[ \"\$(\"$GATE_STATUS\" slug-e2)\" = finished:1 ]"

# ---------------------------------------------------------------------------
# AC(f): chain-guard relaunches a lost gate ONCE, then blocks on a second loss
# ---------------------------------------------------------------------------
echo "== AC(f): chain-guard relaunches once then blocks on the second loss =="
REPO_F="$(new_repo repo-f)"
SHA_F="$(git -C "$REPO_F" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-f"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
# manifest-sidecar.sh (invoked internally by chain-guard.sh's $SIDECAR call)
# reads STATE_DIR/STATUS_DIR, a DIFFERENT env var than chain-guard.sh's own
# BUILD_STATE_DIR convention -- both must point at this sandbox or the
# sidecar write lands in the real skill's state dir instead.
export STATE_DIR="$BUILD_STATE_DIR"
export STATUS_DIR="$STATE_DIR/status"
mkdir -p "$BUILD_STATE_DIR"
cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"slug-f": {"slug": "slug-f", "status": "in_progress", "build_target": "rust-extend", "blockers": [], "last_error": "Gate is running in the background (can take several minutes)."}}}
JSON

export FAKE_EXTEND_GATE_SLEEP=5 FAKE_EXTEND_GATE_WRITE_RECEIPT=0
unit_f1="$("$GATE_LAUNCH" "$REPO_F" --head "$SHA_F" --scope main --slug slug-f 2>/dev/null)"
rm -rf "${FAKE_SYSTEMD_STATE_DIR:?}/$unit_f1"
expect "pre-check: gate-status.sh agrees it's lost" "[ \"\$(\"$GATE_STATUS\" slug-f)\" = lost ]"

out_f1="$("$CHAIN_GUARD" check slug-f --skip-select-guard --prd-dir "$T" 2>&1)"; rc_f1=$?
expect "first lost: chain-guard stops (never continues on narration)" "[ $rc_f1 -eq 1 ]"
expect "first lost: reason is gate-relaunched" "grep -q 'stop: slug-f: gate-relaunched' <<<\"$out_f1\""
expect "first lost: journaled as gate lost relaunching" "grep -q '  slug-f  gate  lost  ' \"$CHAIN_GUARD_JOURNAL\""
marker_f="$BUILD_STATE_DIR/gate-inflight/slug-f.json"
unit_f2="$(jq -r .unit "$marker_f" 2>/dev/null)"
expect "a fresh marker exists after relaunch" "[ -n \"$unit_f2\" ]"
expect "the fresh marker is stamped relaunch_count=1" "[ \"\$(jq -r '.relaunch_count // 0' \"$marker_f\")\" = 1 ]"

# The relaunched attempt ALSO gets lost (systemd-run reused the sleep-30,
# no-receipt fixture, so it's still "running" — force the same vanish).
rm -rf "${FAKE_SYSTEMD_STATE_DIR:?}/$unit_f2"
expect "the relaunched unit is also lost" "[ \"\$(\"$GATE_STATUS\" slug-f)\" = lost ]"

out_f2="$("$CHAIN_GUARD" check slug-f --skip-select-guard --prd-dir "$T" 2>&1)"; rc_f2=$?
expect "second lost: chain-guard stops" "[ $rc_f2 -eq 1 ]"
expect "second lost: reason is gate-lost-twice" "grep -q 'stop: slug-f: gate-lost-twice' <<<\"$out_f2\""
sidecar_f="$BUILD_STATE_DIR/status/slug-f.json"
expect "second lost: sidecar records status=blocked" "[ \"\$(jq -r .status \"$sidecar_f\" 2>/dev/null)\" = blocked ]"
expect "second lost: sidecar records last_error=gate-lost-twice" "[ \"\$(jq -r .last_error \"$sidecar_f\" 2>/dev/null)\" = gate-lost-twice ]"

# Narration alone (no marker at all) must never be trusted or relaunched.
echo "== AC(f2): narration with no marker falls through to normal preconditions =="
export BUILD_STATE_DIR="$T/state-f2"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR"
cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"slug-f2": {"slug": "slug-f2", "status": "in_progress", "build_target": "shell", "blockers": [], "last_error": "gate is running in the background"}}}
JSON
out_f2n="$("$CHAIN_GUARD" check slug-f2 --skip-select-guard --prd-dir "$T" 2>&1)"; rc_f2n=$?
expect "no marker: chain-guard falls through to preconditions-hold" "grep -q 'preconditions-hold' <<<\"$out_f2n\" && [ $rc_f2n -eq 0 ]"

# ---------------------------------------------------------------------------
# AC(g): the launcher never uses a login shell
# ---------------------------------------------------------------------------
echo "== AC(g): launcher never uses bash -l =="
expect "gate-launch.sh's own invocation never uses bash -l (comments aside)" \
  "! grep -vE '^[[:space:]]*#' \"$GATE_LAUNCH\" | grep -qE '\\bbash[[:space:]]+-l'"
expect "gate-launch.sh invokes bash -c (not -lc)" "grep -qE '\\bbash -c ' \"$GATE_LAUNCH\""

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
