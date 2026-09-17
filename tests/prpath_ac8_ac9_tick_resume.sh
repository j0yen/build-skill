#!/usr/bin/env bash
# tests/prpath_ac8_ac9_tick_resume.sh — PRD-build-main-push-gate-pr-path
# AC8/AC9 (requirements 6/7): landing-resume.sh is what the tick calls
# instead of a PRD's normal build phases once its manifest sidecar carries
# last_step=landing-pending. Exercises all four `landing-check` verdicts
# plus the bounded-pending timeout, against a FAKE branch-protection.sh
# (this script's own orchestration, not branch-protection.sh's landing-
# check/sync mechanics — those have their own prpath_ac3/ac4/ac5 fixtures)
# and the REAL manifest-sidecar.sh (so sidecar writes are asserted the
# same way prpath_ac1_ac2 already does).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"
LR="$PRPATH_SCRIPTS/landing-resume.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac8ac9.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# fake-branch-protection.sh — answers `landing-check` and `sync` from env
# vars the test sets before each call; logs one line per call so a test
# can assert call counts.
cat > "$ROOT/fake-bp.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  landing-check)
    echo "call" >> "$(dirname "$0")/landing-check-calls.log"
    printf '%s\n' "${FAKE_BP_LANDING_CHECK_OUT:-pending}"
    exit "${FAKE_BP_LANDING_CHECK_RC:-3}"
    ;;
  sync)
    echo "call" >> "$(dirname "$0")/sync-calls.log"
    printf '%s\n' "${FAKE_BP_SYNC_OUT:-branch-protection: synced}"
    exit "${FAKE_BP_SYNC_RC:-0}"
    ;;
  *) echo "fake-bp: unexpected invocation: $cmd $*" >&2; exit 9 ;;
esac
FAKE
chmod +x "$ROOT/fake-bp.sh"

cat > "$ROOT/fake-alert-deliver.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/alert-calls.log"
exit 0
FAKE
chmod +x "$ROOT/fake-alert-deliver.sh"

cat > "$ROOT/fake-decisions.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/decisions-calls.log"
exit 0
FAKE
chmod +x "$ROOT/fake-decisions.sh"

mk_landing_record() {  # $1=state_dir $2=repo_slug $3=slug $4=armed_at_iso
  mkdir -p "$1/landings/$2"
  cat > "$1/landings/$2/$3.json" <<EOF
{"pr_url": "https://github.com/j0yen/$2/pull/9", "pr_number": 9, "head_sha": "deadbeef00000000000000000000000000000000", "armed_at": "$4"}
EOF
}

run_lr() {  # everything via env already exported by caller
  "$LR" "$REPO" "$SLUG" 2>"$ROOT/lr.err"
}

REPO="$(prpath_mk_repo "$ROOT/repo")"
REPO_SLUG="$(basename "$REPO")"
SLUG="fixture-slug"

export LANDING_RESUME_BRANCH_PROTECTION="$ROOT/fake-bp.sh"
export LANDING_RESUME_ALERT_DELIVER="$ROOT/fake-alert-deliver.sh"
export LANDING_RESUME_DECISIONS="$ROOT/fake-decisions.sh"
export LANDING_RESUME_JOURNAL="$ROOT/journal.md"

# =========================================================================
# Scenario 1 (AC8) — merged + sync ok -> last_step cleared, record
# removed, journal has landing-resolved, exit 0 with the merged sha.
# =========================================================================
echo "=== Scenario 1: merged + sync ok ==="
export BUILD_STATE_DIR="$ROOT/state1"; mkdir -p "$BUILD_STATE_DIR"
mk_landing_record "$BUILD_STATE_DIR" "$REPO_SLUG" "$SLUG" "2026-09-16T22:00:00Z"
"$PRPATH_SCRIPTS/manifest-sidecar.sh" write "$SLUG" "status=in_progress" "last_step=landing-pending" >/dev/null

# NOTE: `out1="$(run_lr)"` alone has no command WORD (out1=... is itself
# just an assignment), so bash treats a would-be prefix here as a plain,
# non-exported shell variable rather than the function's temporary
# environment (unlike every other scenario below, which calls `run_lr`
# as a bare command word and so DOES get the prefix-env-for-this-call
# behavior) -- caught live writing this fixture. Export explicitly here.
export FAKE_BP_LANDING_CHECK_OUT="merged cafef00dcafef00dcafef00dcafef00dcafef00d" FAKE_BP_LANDING_CHECK_RC=0 \
  FAKE_BP_SYNC_OUT="branch-protection: synced" FAKE_BP_SYNC_RC=0
out1="$(run_lr)"
rc1=$?
prpath_expect "AC8: merged+sync exits 0" "[ $rc1 -eq 0 ]"
prpath_expect "AC8: stdout is the merged sha" "[ \"$out1\" = cafef00dcafef00dcafef00dcafef00dcafef00d ]"
prpath_expect "AC8: landing record was removed" "[ ! -f \"$BUILD_STATE_DIR/landings/$REPO_SLUG/$SLUG.json\" ]"
sidecar1="$BUILD_STATE_DIR/status/$SLUG.json"
prpath_expect "AC8: sidecar last_step cleared" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"last_step\") is None else 1)' \"$sidecar1\""
prpath_expect "AC8: journal has landing-resolved" "grep -q landing-resolved \"$LANDING_RESUME_JOURNAL\""

# =========================================================================
# Scenario 2 (AC8) — merged, but sync refused -> exit 2, no sidecar
# mutation beyond what already existed (last_step untouched).
# =========================================================================
echo "=== Scenario 2: merged, sync refused ==="
export BUILD_STATE_DIR="$ROOT/state2"; mkdir -p "$BUILD_STATE_DIR"
mk_landing_record "$BUILD_STATE_DIR" "$REPO_SLUG" "$SLUG" "2026-09-16T22:00:00Z"
"$PRPATH_SCRIPTS/manifest-sidecar.sh" write "$SLUG" "status=in_progress" "last_step=landing-pending" >/dev/null

FAKE_BP_LANDING_CHECK_OUT="merged cafef00dcafef00dcafef00dcafef00dcafef00d" FAKE_BP_LANDING_CHECK_RC=0 \
  FAKE_BP_SYNC_OUT="branch-protection: refused" FAKE_BP_SYNC_RC=6 \
  run_lr >/dev/null
rc2=$?
prpath_expect "AC8: merged+sync-refused exits 2" "[ $rc2 -eq 2 ]"
prpath_expect "AC8: landing record survives a sync refusal" "[ -f \"$BUILD_STATE_DIR/landings/$REPO_SLUG/$SLUG.json\" ]"
prpath_expect "AC8: journal has landing-sync-deferred" "grep -q landing-sync-deferred \"$LANDING_RESUME_JOURNAL\""

# =========================================================================
# Scenario 3 (AC8) — pending, under the bound -> exit 3, one journal
# line, no state mutation.
# =========================================================================
echo "=== Scenario 3: pending, under bound ==="
export BUILD_STATE_DIR="$ROOT/state3"; mkdir -p "$BUILD_STATE_DIR"
mk_landing_record "$BUILD_STATE_DIR" "$REPO_SLUG" "$SLUG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

FAKE_BP_LANDING_CHECK_OUT="pending" FAKE_BP_LANDING_CHECK_RC=3 \
  run_lr >/dev/null
rc3=$?
prpath_expect "AC8: pending-under-bound exits 3" "[ $rc3 -eq 3 ]"
prpath_expect "AC8: pending journal line carries elapsed=" "grep -q 'landing-pending .*elapsed=' \"$LANDING_RESUME_JOURNAL\""
prpath_expect "AC8: no sidecar written for a plain pending" "[ ! -f \"$BUILD_STATE_DIR/status/$SLUG.json\" ]"

# =========================================================================
# Scenario 4 (AC9) — pending, AT the bound -> exit 4, PRD blocked with
# pr-checks-timeout, a decision opened, landing record kept as evidence.
# =========================================================================
echo "=== Scenario 4: pending, at bound (timeout) ==="
export BUILD_STATE_DIR="$ROOT/state4"; mkdir -p "$BUILD_STATE_DIR"
old_armed="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=61)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
mk_landing_record "$BUILD_STATE_DIR" "$REPO_SLUG" "$SLUG" "$old_armed"

FAKE_BP_LANDING_CHECK_OUT="pending" FAKE_BP_LANDING_CHECK_RC=3 \
  "$LR" "$REPO" "$SLUG" --pending-max 60 2>"$ROOT/lr4.err"
rc4=$?
prpath_expect "AC9: pending-at-bound exits 4" "[ $rc4 -eq 4 ]"
sidecar4="$BUILD_STATE_DIR/status/$SLUG.json"
prpath_expect "AC9: sidecar status=blocked" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"status\")==\"blocked\" else 1)' \"$sidecar4\""
prpath_expect "AC9: sidecar last_error=pr-checks-timeout" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"last_error\")==\"pr-checks-timeout\" else 1)' \"$sidecar4\""
prpath_expect "AC9: a decision was opened" "[ -s \"$ROOT/decisions-calls.log\" ]"
prpath_expect "AC9: landing record kept as evidence" "[ -f \"$BUILD_STATE_DIR/landings/$REPO_SLUG/$SLUG.json\" ]"
prpath_expect "AC9: journal has pr-checks-timeout" "grep -q pr-checks-timeout \"$LANDING_RESUME_JOURNAL\""

# =========================================================================
# Scenario 5 (AC8) — red <check> -> blocked, last_error=pr-checks-red:X,
# red-gate alarm fired.
# =========================================================================
echo "=== Scenario 5: red check ==="
export BUILD_STATE_DIR="$ROOT/state5"; mkdir -p "$BUILD_STATE_DIR"
mk_landing_record "$BUILD_STATE_DIR" "$REPO_SLUG" "$SLUG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

FAKE_BP_LANDING_CHECK_OUT="red sandbox suites (all shards)" FAKE_BP_LANDING_CHECK_RC=4 \
  run_lr >/dev/null
rc5=$?
prpath_expect "AC8: red exits 5" "[ $rc5 -eq 5 ]"
sidecar5="$BUILD_STATE_DIR/status/$SLUG.json"
prpath_expect "AC8: sidecar last_error names the failing check" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"last_error\",\"\").startswith(\"pr-checks-red:\") else 1)' \"$sidecar5\""
prpath_expect "AC8: red-gate alarm fired" "[ -s \"$ROOT/alert-calls.log\" ]"
prpath_expect "AC8: journal has an ALARM line" "grep -q 'ALARM pr-checks-red' \"$LANDING_RESUME_JOURNAL\""

# =========================================================================
# Scenario 6 (AC8) — closed -> blocked, last_error=pr-closed.
# =========================================================================
echo "=== Scenario 6: closed ==="
export BUILD_STATE_DIR="$ROOT/state6"; mkdir -p "$BUILD_STATE_DIR"
mk_landing_record "$BUILD_STATE_DIR" "$REPO_SLUG" "$SLUG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

FAKE_BP_LANDING_CHECK_OUT="closed" FAKE_BP_LANDING_CHECK_RC=5 \
  run_lr >/dev/null
rc6=$?
prpath_expect "AC8: closed exits 6" "[ $rc6 -eq 6 ]"
sidecar6="$BUILD_STATE_DIR/status/$SLUG.json"
prpath_expect "AC8: sidecar last_error=pr-closed" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"last_error\")==\"pr-closed\" else 1)' \"$sidecar6\""

exit "$prpath_fail"
