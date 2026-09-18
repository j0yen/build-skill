#!/usr/bin/env bash
# tickout_ac12_loop_tick_stale_alarm.sh —
# PRD-buildloop-tick-outcome-liveness AC12.
#
# Given claude-build.timer active and a record older than 3 x 300s, When
# manifest-invariants.sh --report runs, Then it prints
# `ALARM build-loop [loop-tick-stale]`; with the timer inactive it prints
# nothing for this class. Modeled on manifest-inv_ac8_red_archived_
# alarmed.sh's fixture shape.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac12: $MI not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

run_case() { # <timer-state> <tick-outcome-age-s|none> <expect_alarm: yes|no>
  local timer_state="$1" age_s="$2" expect_alarm="$3"
  local T
  T="$(mktemp -d "${TMPDIR:-/tmp}/tickout-ac12.XXXXXX")"
  mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked" "$T/bin"

  python3 -c "
import json
json.dump({'prds': {}}, open('$T/state/manifest.json', 'w'))
"

  if [ "$age_s" != none ]; then
    local ts
    ts="$(date -u -d "@$(( $(date -u +%s) - age_s ))" +%Y-%m-%dT%H:%M:%SZ)"
    python3 -c "
import json
json.dump({'ts': '$ts', 'n': 1, 'rc': 1, 'outcome': 'failed', 'cause': 'other',
           'evidence': 'x', 'streak_failed': 1, 'last_ok_ts': None, 'lane': 'redbaron'},
          open('$T/state/tick-outcome.json', 'w'))
"
  fi

  cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--user" ] && [ "\$2" = "is-active" ]; then
  echo "$timer_state"
  [ "$timer_state" = active ] && exit 0 || exit 3
fi
if [ "\$1" = "--user" ] && [ "\$2" = "show" ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$T/bin/systemctl"

  out="$(BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" \
         LOCK="$T/state/tick.lock" JOURNAL="$T/journal.md" \
         PATH="$T/bin:/usr/bin:/bin" "$MI" --prd-dir "$T" --report)"

  if [ "$expect_alarm" = yes ]; then
    expect "[timer=$timer_state age=$age_s] --report prints ALARM build-loop [loop-tick-stale]" \
      "grep -q 'ALARM build-loop \[loop-tick-stale\]' <<<\"\$out\""
  else
    expect "[timer=$timer_state age=$age_s] --report has no loop-tick-stale alarm" \
      "! grep -q '\[loop-tick-stale\]' <<<\"\$out\""
  fi

  rm -rf "$T"
}

# Timer active, record ~1000s old (> 3*300=900) -> alarm.
run_case active 1000 yes
# Timer active, record fresh (60s old) -> no alarm.
run_case active 60 no
# Timer active, NO record at all -> alarm (armed but never ticked).
run_case active none yes
# Timer inactive, record stale -> no alarm regardless (AC12's 2nd half).
run_case inactive 1000 no

exit "$fail"
