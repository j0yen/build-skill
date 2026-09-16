#!/usr/bin/env bash
# gatepat_ac5_holder_identity_explain_lock.sh —
# PRD-build-gate-patience-from-queue-depth AC5: given a holder file
# written by a running gate, when `extend-gate.sh --explain-lock <crate>`
# runs, then it prints pid, slug, scope, and age in seconds; after the
# holder exits, the file is gone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac5.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/mcphost"
HEAD_SHA="$(make_dirty_repo "$REPO")"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

# --- part 1: no holder yet -> "no holder (lock free)", exit 1 ------------
out_free="$("$EXTEND_GATE" --explain-lock "$REPO" 2>&1)"; rc_free=$?
expect "AC5: --explain-lock reports free when nothing holds it" "echo \"$out_free\" | grep -qx 'no holder (lock free)'"
expect "AC5: --explain-lock exits 1 when free" "[ $rc_free -eq 1 ]"

# --- part 2: a real gate run holds the lock long enough to inspect -------
# EXTEND_GATE_PATIENCE_OVERRIDE keeps this deterministic/fast: the run
# below is the ONLY thing touching the lock, so it acquires immediately,
# writes the holder sidecar, then we race a background sleep to keep the
# process (and its held lock+holder file) alive long enough for
# --explain-lock to observe it before the dirty-tree refusal tears it down.
# A python wrapper pauses the run for a moment right after lock
# acquisition would require instrumenting extend-gate.sh itself (out of
# scope) -- instead this uses the SAME externally-held-lock technique as
# AC3, but this time writes the `.holder` sidecar by hand (exactly the
# format extend-gate.sh itself writes: "pid slug scope started_epoch"),
# proving --explain-lock's OWN parsing/printing of that sidecar, which is
# the part of requirement 3 unique to this script.
LOCKFILE="$REPO/.git/autobuilder-integrate.lock"
HOLDER_FILE="$LOCKFILE.holder"
( exec 9>"$LOCKFILE"; flock -x 9; sleep 5 ) &
holder_job=$!
sleep 0.3
started_epoch=$(( $(date +%s) - 42 ))
printf '%s %s %s %s\n' "$holder_job" "some-slug" "branch" "$started_epoch" > "$HOLDER_FILE"

explain_out="$("$EXTEND_GATE" --explain-lock "$REPO" --scope main 2>&1)"; explain_rc=$?
expect "AC5: --explain-lock exits 0 when a holder sidecar exists" "[ $explain_rc -eq 0 ]"
expect "AC5: --explain-lock prints the holder's pid" "echo \"$explain_out\" | grep -q 'pid='$holder_job''"
expect "AC5: --explain-lock prints the holder's slug" "echo \"$explain_out\" | grep -q 'slug=some-slug'"
expect "AC5: --explain-lock prints the holder's scope" "echo \"$explain_out\" | grep -q 'scope=branch'"
expect "AC5: --explain-lock prints an age_s near 42s" \
  "age=\$(echo \"$explain_out\" | grep -oE 'age_s=[0-9]+' | cut -d= -f2); [ \"\$age\" -ge 40 ] && [ \"\$age\" -le 50 ]"

wait "$holder_job" 2>/dev/null || true
rm -f "$HOLDER_FILE"

out_after="$("$EXTEND_GATE" --explain-lock "$REPO" 2>&1)"
expect "AC5: after the holder exits, the sidecar is gone (no holder)" "echo \"$out_after\" | grep -qx 'no holder (lock free)'"

# --- part 3: extend-gate.sh's OWN lock/release lifecycle leaves no sidecar
# behind on a real (uncontended) run -- proves requirement 3's "removed on
# every exit path" for the code path this PRD actually added, not just the
# hand-written fixture above.
env EXTEND_GATE_JOURNAL="$JOURNAL" RUSTBUILD_SCRIPTS="$GATEPAT_RUSTBUILD_SCRIPTS" \
  "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" >"$T/out.log" 2>&1
rc_real=$?
expect "AC5: a real (uncontended) run reaches the dirty-tree refusal" "[ $rc_real -eq 3 ]"
expect "AC5: that run's own holder sidecar is removed on exit (trap fired)" "[ ! -f \"$HOLDER_FILE\" ]"

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac5: ALL PASS"
  exit 0
else
  echo "gatepat_ac5: assertion(s) FAILED"
  exit 1
fi
