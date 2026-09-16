#!/usr/bin/env bash
# gatepat_ac1_three_claims_wall_median.sh —
# PRD-build-gate-patience-from-queue-depth AC1: given three fake claims on
# one crate and three prior `gate` journal lines with wall=600/700/800,
# when extend-gate.sh attempts the lock, then the journal has
# `gate patience (... depth=3 wall_est=700 patience=2100)` and the flock
# wait it configures is at least 2100s (the "fixture clock" note in the
# PRD's own AC text: proven by intercepting the `flock -w N` call itself
# rather than literally sleeping 2100 real seconds — see the `flock` PATH
# shim below).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatepat-common.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/gatepat_ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/mcphost"
HEAD_SHA="$(make_dirty_repo "$REPO")"

PRD_DIR="$T/prds"
write_prd_fixture "$PRD_DIR" a "$REPO"
write_prd_fixture "$PRD_DIR" b "$REPO"
write_prd_fixture "$PRD_DIR" c "$REPO"

FAKE_CLAIM="$T/fake-lane-claim.sh"
make_fake_lane_claim "$FAKE_CLAIM" '[
  {"prd":"'"$PRD_DIR"'/build-queue/PRD-a.md","lane":"redbaron","host":"redbaron","ts":"x","age_s":10,"state":"live","cause":"","probes":""},
  {"prd":"'"$PRD_DIR"'/build-queue/PRD-b.md","lane":"redbaron","host":"redbaron","ts":"x","age_s":10,"state":"live","cause":"","probes":""},
  {"prd":"'"$PRD_DIR"'/build-queue/PRD-c.md","lane":"redbaron","host":"redbaron","ts":"x","age_s":10,"state":"live","cause":"","probes":""}
]'

JOURNAL="$T/journal.md"
cat > "$JOURNAL" <<EOF
2026-09-15T09:00:00Z  gate  mcphost  pass  (head=a base=b wall=600s lock_wait=0s)
2026-09-15T09:10:00Z  gate  mcphost  pass  (head=c base=d wall=700s lock_wait=0s)
2026-09-15T09:20:00Z  gate  mcphost  pass  (head=e base=f wall=800s lock_wait=0s)
EOF

# flock shim: records the -w value it was called with, then always fails
# to acquire (rc=1) so this run reaches extend-gate.sh's exit-4 path
# immediately instead of actually waiting out 2100s of real time — the
# "fixture clock" the AC's own text calls for.
FAKESHIM="$T/shim"
mkdir -p "$FAKESHIM"
cat > "$FAKESHIM/flock" <<'EOF'
#!/usr/bin/env bash
w=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-w" ]; then w="${args[$((i+1))]}"; fi
done
echo "$w" >> "${GATEPAT_FLOCK_LOG:?}"
exit 1
EOF
chmod +x "$FAKESHIM/flock"

GATEPAT_FLOCK_LOG="$T/flock-w.log"
env PATH="$FAKESHIM:$PATH" \
  GATEPAT_FLOCK_LOG="$GATEPAT_FLOCK_LOG" \
  GATE_PATIENCE_LANE_CLAIM="$FAKE_CLAIM" \
  GATE_PATIENCE_PRD_DIR="$PRD_DIR" \
  GATE_PATIENCE_EXCLUDE_PRD="$PRD_DIR/build-queue/PRD-does-not-exist.md" \
  EXTEND_GATE_JOURNAL="$JOURNAL" \
  EXTEND_GATE_PRODUCER_LOCK_WAIT=90 \
  RUSTBUILD_SCRIPTS="$GATEPAT_RUSTBUILD_SCRIPTS" \
  "$EXTEND_GATE" "$REPO" --head "$HEAD_SHA" --slug does-not-exist >"$T/out.log" 2>&1
rc=$?

expect "AC1: run exits 4 (contended — the shimmed flock always fails)" "[ $rc -eq 4 ]"
expect "AC1: journal has the derived-patience line with depth=3 wall_est=700 patience=2100" \
  "grep -qE 'gate  patience  \(crate=mcphost depth=3 wall_est=700 patience=2100\)' \"$JOURNAL\""
expect "AC1: the flock call was configured to wait at least 2100s (fixture clock)" \
  "[ \"\$(cat \"$GATEPAT_FLOCK_LOG\")\" -ge 2100 ]"

echo "-----"
if [ "$gatepat_fail" -eq 0 ]; then
  echo "gatepat_ac1: ALL PASS"
  exit 0
else
  echo "gatepat_ac1: assertion(s) FAILED"
  exit 1
fi
