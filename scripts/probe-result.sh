#!/usr/bin/env bash
# probe-result.sh — shared three-state probe-result library
# (PRD-build-three-state-probes).
#
# Four incidents this week (journal 2026-09-09) were the same defect: a
# probe that could not check its target reported the same "nothing found"
# shape as a probe that checked and found nothing — `wchg since` empty
# after watchman lost its roots, the measure loop reading 28h of
# hub-unreachable as silence, `adopt scan` exiting 0 over 23 stale
# artifacts, capability-probe skip-guards reading a missing sandbox as a
# green test. This library gives every probe in the loop one shared
# three-state contract instead of each reinventing (or skipping) the
# distinction:
#
#   clean            checked, nothing wrong.
#   dirty            checked, found something (unchanged meaning per-probe
#                     — this library does not redefine what "a finding" is
#                     for any given probe, only adds the third state).
#   could-not-check  the check itself could not run to a real answer
#                     (missing input, unparseable output, unreachable
#                     dependency, corrupted state file, ...) — never
#                     silently folded into clean.
#
# Usage (source this file, then call the functions):
#   source .../probe-result.sh
#   probe_emit <name> <clean|dirty|could-not-check> <reason>
#       Appends one NDJSON line to the shared ledger (state/probes/ledger.jsonl,
#       flock-protected so parallel branch agents never interleave writes),
#       computes this probe's live could-not-check streak, fires the streak
#       alarm at most once per streak (PROBE_STREAK_ALARM, default 3;
#       re-arms on the next clean/dirty emit), and echoes the canonical
#       one-line form to stdout. Always returns 0 on a valid call (fail-open
#       — a probe library must never be the reason a probe crashes its
#       caller); returns 2 on a usage error (bad state name).
#   probe_streak <name>
#       Prints (stdout only, no side effects) the current consecutive
#       could-not-check count for <name>, derived from the ledger tail —
#       no separate counter file to desync from the ledger (Technical
#       considerations: "streaks are computed from the ledger tail at
#       emit time").
#
# Also runnable directly (not just sourced) as a thin CLI, for callers that
# prefer a subprocess over sourcing (e.g. a script that lives outside this
# repo and doesn't want to hardcode this file's internal function names):
#   probe-result.sh emit <name> <state> <reason>
#   probe-result.sh streak <name>
#
# Env overrides (tests sandbox via these; production never sets them):
#   BUILD_STATE_DIR       — parent of the probes/ dir (default: <skill>/state)
#   PROBE_DIR             — overrides state dir/probes directly
#   PROBE_LEDGER          — overrides the ledger file path
#   PROBE_STREAK_ALARM    — streak threshold (default 3)
#   PROBE_JOURNAL_DIR     — dir holding the daily tick journal the alarm
#                           appends to (default ~/brain/journal/build)
#   PROBE_DOCKET_RUN      — docket --run id (default: today's date + ".probe")
#
# Docket integration is fail-open (self-review's docket-ack-emit.sh
# convention): absence of `docket` on PATH never blocks a probe, never
# fails probe_emit, and the alarm's journal line still lands either way.
set -uo pipefail

_probe_here() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
PROBE_LIB_DIR="$(_probe_here)"
PROBE_SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$PROBE_LIB_DIR/.." && pwd)}"
PROBE_STATE_DIR="${BUILD_STATE_DIR:-$PROBE_SKILL_DIR/state}"
PROBE_DIR="${PROBE_DIR:-$PROBE_STATE_DIR/probes}"
PROBE_LEDGER="${PROBE_LEDGER:-$PROBE_DIR/ledger.jsonl}"
PROBE_LOCKFILE="${PROBE_LOCKFILE:-$PROBE_DIR/ledger.lock}"
PROBE_STREAK_ALARM="${PROBE_STREAK_ALARM:-3}"
PROBE_JOURNAL_DIR="${PROBE_JOURNAL_DIR:-$HOME/brain/journal/build}"

mkdir -p "$PROBE_DIR" 2>/dev/null || true

# Strip newlines and swap embedded double-quotes for single-quotes so a
# reason string can never break the canonical line or the journal line.
_probe_clean_reason() {
  printf '%s' "${1:-}" | tr '\n\r' '  ' | sed "s/\"/'/g"
}

# The state-machine step: given the ledger, a probe name, a new state, a
# reason, and the alarm threshold — appends the new NDJSON row and prints
# PROBE_TS=/PROBE_STREAK=/PROBE_FIRE= for the bash caller to read. Run
# under the caller's flock, so this never races a sibling probe_emit.
_probe_py() {
  python3 - "$@" <<'PY'
import json, sys, datetime

ledger_path, name, state, reason, threshold = sys.argv[1:6]
threshold = int(threshold)
VALID = {"clean", "dirty", "could-not-check"}
if state not in VALID:
    print("error: invalid state %r (want clean|dirty|could-not-check)" % state, file=sys.stderr)
    sys.exit(2)

rows = []
try:
    with open(ledger_path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
except FileNotFoundError:
    rows = []

# Walk backward from the tail: count the still-open could-not-check run for
# this probe, and note whether an alarm already fired within that run.
prior_streak = 0
prior_alarmed = False
for row in reversed(rows):
    if row.get("probe") != name:
        continue
    if row.get("state") == "could-not-check":
        prior_streak += 1
        if row.get("alarmed"):
            prior_alarmed = True
    else:
        break

if state == "could-not-check":
    new_streak = prior_streak + 1
else:
    new_streak = 0

should_fire = (state == "could-not-check") and (new_streak >= threshold) and (not prior_alarmed)
line_alarmed = (state == "could-not-check") and (prior_alarmed or should_fire)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "ts": ts,
    "probe": name,
    "state": state,
    "reason": reason,
    "streak": new_streak,
    "alarmed": line_alarmed,
}
with open(ledger_path, "a") as fh:
    fh.write(json.dumps(entry, sort_keys=True) + "\n")

print("PROBE_TS=%s" % ts)
print("PROBE_STREAK=%d" % new_streak)
print("PROBE_FIRE=%s" % ("1" if should_fire else "0"))
PY
}

# Alarm side-effects: tick journal line (always) + docket report (best
# effort, fail-open — see self-review's docket-ack-emit.sh for the same
# pattern this mirrors).
_probe_alarm() {
  local name="$1" streak="$2" reason="$3"
  local jf="$PROBE_JOURNAL_DIR/$(date -u +%F).md"
  mkdir -p "$PROBE_JOURNAL_DIR" 2>/dev/null || true
  printf 'probe-dead: %s streak=%s reason="%s"\n' "$name" "$streak" "$reason" >> "$jf" 2>/dev/null || true
  if command -v docket >/dev/null 2>&1; then
    docket report --run "${PROBE_DOCKET_RUN:-$(date -u +%F).probe}" \
      --key "probe-dead-$name" \
      --title "probe $name could-not-check streak=$streak" \
      --evidence "$reason" >/dev/null 2>&1 || true
  fi
  return 0
}

probe_emit() {
  local name="${1:?probe_emit: missing <name>}" state="${2:?probe_emit: missing <state>}" reason="${3:-}"
  case "$state" in
    clean|dirty|could-not-check) ;;
    *) echo "probe_emit: invalid state '$state' (want clean|dirty|could-not-check)" >&2; return 2 ;;
  esac
  reason="$(_probe_clean_reason "$reason")"
  mkdir -p "$PROBE_DIR" 2>/dev/null || true

  local out rc _probe_lock_fd
  exec {_probe_lock_fd}>>"$PROBE_LOCKFILE"
  flock "$_probe_lock_fd"
  out="$(_probe_py "$PROBE_LEDGER" "$name" "$state" "$reason" "$PROBE_STREAK_ALARM")"
  rc=$?
  flock -u "$_probe_lock_fd"
  exec {_probe_lock_fd}>&-

  if [ "$rc" -ne 0 ]; then
    echo "probe_emit: internal error emitting probe '$name' (rc=$rc)" >&2
    return "$rc"
  fi

  local ts streak fire
  ts="$(printf '%s\n' "$out" | sed -n 's/^PROBE_TS=//p')"
  streak="$(printf '%s\n' "$out" | sed -n 's/^PROBE_STREAK=//p')"
  fire="$(printf '%s\n' "$out" | sed -n 's/^PROBE_FIRE=//p')"

  [ "$fire" = "1" ] && _probe_alarm "$name" "$streak" "$reason"

  printf 'probe=%s state=%s reason="%s" streak=%s ts=%s\n' "$name" "$state" "$reason" "$streak" "$ts"
  return 0
}

probe_streak() {
  local name="${1:?probe_streak: missing <name>}"
  python3 - "$PROBE_LEDGER" "$name" <<'PY'
import json, sys
ledger_path, name = sys.argv[1:3]
rows = []
try:
    with open(ledger_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
except FileNotFoundError:
    pass

streak = 0
for row in reversed(rows):
    if row.get("probe") != name:
        continue
    if row.get("state") == "could-not-check":
        streak += 1
    else:
        break
print(streak)
PY
}

# ---- direct-execution CLI (only when run, not sourced) --------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    emit)   shift; probe_emit "$@" ;;
    streak) shift; probe_streak "$@" ;;
    *) echo "usage: probe-result.sh {emit <name> <state> <reason>|streak <name>}" >&2; exit 2 ;;
  esac
fi
