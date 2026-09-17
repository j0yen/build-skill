#!/usr/bin/env bash
# tests/prpath_ac12_status_banner.sh — PRD-build-main-push-gate-pr-path
# AC12 (requirement 9): given one landing pending on mcphost#N for 12
# minutes, the status banner (gates-banner.sh, local/RedBaron path)
# contains `landing-pending=1 mcphost#N 12m`. A second scenario proves a
# `blocked` PRD's surviving landing record (kept "as evidence" per AC9)
# is NOT counted or printed here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"
GB="$PRPATH_SCRIPTS/gates-banner.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac12.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

mk_state() {  # $1=state_dir $2=repo_slug $3=slug $4=pr $5=minutes_ago $6=manifest_status_or_empty
  local state="$1" repo="$2" slug="$3" pr="$4" mins="$5" mstatus="${6:-}"
  mkdir -p "$state/landings/$repo"
  local armed
  armed="$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$mins")"
  cat > "$state/landings/$repo/$slug.json" <<EOF
{"pr_url": "https://github.com/j0yen/$repo/pull/$pr", "pr_number": $pr, "head_sha": "deadbeef", "armed_at": "$armed"}
EOF
  echo "$armed"
  echo '{"schema":"autobuilder.gate_red_summary.v1"}' > /dev/null
  if [ -n "$mstatus" ]; then
    printf '{"prds": {"%s": {"status": "%s"}}}\n' "$slug" "$mstatus" > "$state/manifest.json"
  fi
}

# =========================================================================
# Scenario 1 (AC12) — one landing pending 12m -> banner contains
# `landing-pending=1 mcphost#N 12m`.
# =========================================================================
echo "=== Scenario 1: one landing pending 12m ==="
S1="$ROOT/state1"; mkdir -p "$S1"
mk_state "$S1" mcphost fixture-slug 42 12 >/dev/null
printf '%s red=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$S1/gate-red.summary"

out1="$(GATES_BANNER_HOSTNAME=redbaron BUILD_STATE_DIR="$S1" GATE_RED_SUMMARY_FILE="$S1/gate-red.summary" "$GB")"
prpath_expect "AC12: banner contains landing-pending=1" "printf '%s\n' \"\$out1\" | grep -q '^landing-pending=1\$'"
prpath_expect "AC12: banner names mcphost#42 12m" "printf '%s\n' \"\$out1\" | grep -q '^mcphost#42 12m\$'"

# =========================================================================
# Scenario 2 — a blocked PRD's surviving landing record is not counted.
# =========================================================================
echo "=== Scenario 2: blocked landing record is excluded ==="
S2="$ROOT/state2"; mkdir -p "$S2"
mk_state "$S2" mcphost fixture-slug-2 43 90 blocked >/dev/null
printf '%s red=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$S2/gate-red.summary"

out2="$(GATES_BANNER_HOSTNAME=redbaron BUILD_STATE_DIR="$S2" GATE_RED_SUMMARY_FILE="$S2/gate-red.summary" "$GB")"
prpath_expect "AC12: a blocked landing is not counted" "! printf '%s\n' \"\$out2\" | grep -q '^landing-pending=[1-9]'"
prpath_expect "AC12: a blocked landing's PR is not printed" "! printf '%s\n' \"\$out2\" | grep -q 'mcphost#43'"

# =========================================================================
# Scenario 3 — no landings at all -> no landing-pending line (banner
# unchanged from before this PRD).
# =========================================================================
echo "=== Scenario 3: no landings -> no line ==="
S3="$ROOT/state3"; mkdir -p "$S3"
printf '%s red=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$S3/gate-red.summary"
out3="$(GATES_BANNER_HOSTNAME=redbaron BUILD_STATE_DIR="$S3" GATE_RED_SUMMARY_FILE="$S3/gate-red.summary" "$GB")"
prpath_expect "AC12: no landings -> no landing-pending line at all" "! printf '%s\n' \"\$out3\" | grep -q landing-pending"

exit "$prpath_fail"
