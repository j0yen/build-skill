#!/usr/bin/env bash
# gate-red-tick.sh — R2/R3/R4 of PRD-build-gate-red-alarm-invariant.
#
# Called once per tick by select-tick.sh, immediately after its own
# `select-tick  admitted=...` journal line — the one aggregate this PRD
# exists to guarantee is never silently missing again (2026-09-16: 12
# ticks, 7h20m, zero lines saying "0 green, 6 red"). Never fatal to the
# caller: any internal failure is journaled and this exits 0, same
# best-effort contract as alert-deliver.sh itself.
#
# What it does, in order:
#   1. Snapshot the PREVIOUS gate-red.json (before this run overwrites
#      it) — needed for the red>0 -> red==0 "resolve" transition (R3).
#   2. Run gate-red-summary.sh (R1), forwarding any extra args
#      (--window-h/--now), and journal `gate-red green=<n> red=<n>
#      families=<csv>` directly after the caller's own tick-summary line.
#   3. Track the persistent-red escalation streak in
#      state/gate-red.streak (R4): consecutive ticks with red>0 AND an
#      unchanged red-slug set. At streak 3 and every 6 after, journal
#      `ALARM gate-red-persistent ticks=<n> slugs=<csv>`.
#   4. Alarm delivery (R3):
#      - red==0 and the previous run had red>0 -> alert-deliver.sh
#        resolve gate-red build-loop.
#      - red>0 and no alarm delivered yet today -> plain alert-deliver.sh
#        gate-red build-loop <evidence> --value <red> (creates/reuses
#        today's GitHub issue, sets the day marker).
#      - red>0, already delivered today, but the red-slug set or family
#        counts changed since the last delivery, OR this tick just
#        crossed an escalation threshold -> alert-deliver.sh ... --comment
#        (posts a comment on today's issue instead of staying silent
#        until tomorrow; --value is the streak count on an escalation,
#        the current red count otherwise).
#
# Usage: gate-red-tick.sh [--window-h N] [--now ISO_TS]
#   (same flags as gate-red-summary.sh; forwarded as-is)
#
# Env (all optional, for testing/isolation — see gate-red-summary.sh and
# alert-deliver.sh for the ones they already define):
#   GATE_RED_SUMMARY          override path to gate-red-summary.sh
#   GATE_RED_ALERT_DELIVER    override path to alert-deliver.sh
#   GATE_RED_STREAK_FILE      override state/gate-red.streak
#   GATE_RED_DELIVERED_FILE   override state/gate-red.delivered.json
#   GATE_RED_EVIDENCE_FILE    override state/gate-red.evidence
#
# Exit: always 0 (best-effort orchestration; a sub-step's failure is
# journaled, never fatal to the tick) | 2 usage error only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
STATE_DIR="$BUILD_STATE_DIR"
JQ="${JQ:-jq}"

GRS="${GATE_RED_SUMMARY:-$HERE/gate-red-summary.sh}"
ALERT_DELIVER="${GATE_RED_ALERT_DELIVER:-$HERE/alert-deliver.sh}"
JSON_FILE="${GATE_RED_JSON_FILE:-$STATE_DIR/gate-red.json}"
STREAK_FILE="${GATE_RED_STREAK_FILE:-$STATE_DIR/gate-red.streak}"
DELIVERED_FILE="${GATE_RED_DELIVERED_FILE:-$STATE_DIR/gate-red.delivered.json}"
EVIDENCE_FILE="${GATE_RED_EVIDENCE_FILE:-$STATE_DIR/gate-red.evidence}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/alert-marker.sh
source "$HERE/lib/alert-marker.sh"

# GATE_RED_TICK_JOURNAL pins the exact file this script's own journal_line
# calls append to — set by select-tick.sh to its own $JOURNAL so the
# `gate-red ...` line lands in the SAME file, directly after select-tick's
# own tick-summary line, even when that caller's JOURNAL is a test-isolated
# override that doesn't follow the plain journal_root()/<date>.md shape
# (R2's "on the line after select-tick" requirement). Falls back to the
# ordinary journal_root() default when called standalone (e.g. this
# script's own selftest, or a manual run).
GRT_JOURNAL="${GATE_RED_TICK_JOURNAL:-$(journal_root)/$(date -u +%F).md}"

[ -x "$GRS" ] || { echo "gate-red-tick: $GRS not found or not executable" >&2; exit 0; }
[ -x "$ALERT_DELIVER" ] || { echo "gate-red-tick: $ALERT_DELIVER not found or not executable" >&2; exit 0; }
command -v "$JQ" >/dev/null 2>&1 || { echo "gate-red-tick: jq not on \$PATH" >&2; exit 0; }

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- 1. snapshot the previous run's red count, before it's overwritten ----
prev_red=0
if [ -r "$JSON_FILE" ]; then
  prev_red="$("$JQ" -r '.red // 0' "$JSON_FILE" 2>/dev/null || echo 0)"
fi
case "$prev_red" in ''|*[!0-9]*) prev_red=0 ;; esac

# ---- 2. run R1, journal the aggregate ----
summary_line="$("$GRS" "$@")"
grs_rc=$?
if [ "$grs_rc" -ne 0 ]; then
  journal_line --file "$GRT_JOURNAL" "$now_ts  gate-red-tick  summary-failed  rc=$grs_rc"
  exit 0
fi

red="$("$JQ" -r '.red // 0' "$JSON_FILE" 2>/dev/null || echo 0)"
green="$("$JQ" -r '.green // 0' "$JSON_FILE" 2>/dev/null || echo 0)"
slugs_sorted="$("$JQ" -c '(.red_slugs // []) | sort' "$JSON_FILE" 2>/dev/null || echo '[]')"
families_sorted="$("$JQ" -Sc '.families // {}' "$JSON_FILE" 2>/dev/null || echo '{}')"
fams_csv="$("$JQ" -r '(.families // {}) | to_entries | sort_by(-.value, .key) | map("\(.key)=\(.value)") | join(",")' "$JSON_FILE" 2>/dev/null)"
[ -z "$fams_csv" ] && fams_csv="none"

journal_line --file "$GRT_JOURNAL" "$now_ts  gate-red  green=$green red=$red families=$fams_csv"

# ---- 3. escalation streak (R4) ----
streak=0
stored_slugs=""
if [ -r "$STREAK_FILE" ]; then
  streak="$(sed -n '1p' "$STREAK_FILE" 2>/dev/null)"
  stored_slugs="$(sed -n '2p' "$STREAK_FILE" 2>/dev/null)"
fi
case "$streak" in ''|*[!0-9]*) streak=0 ;; esac

escalate_now=false
if [ "$red" -gt 0 ]; then
  if [ "$streak" -gt 0 ] && [ "$stored_slugs" = "$slugs_sorted" ]; then
    streak=$((streak + 1))
  else
    streak=1
  fi
  mkdir -p "$STATE_DIR"
  tmp_streak="$(mktemp "$STATE_DIR/.gate-red.streak.XXXXXX")"
  printf '%s\n%s\n' "$streak" "$slugs_sorted" > "$tmp_streak"
  mv -f "$tmp_streak" "$STREAK_FILE"
  if [ "$streak" -ge 3 ] && [ $(( (streak - 3) % 6 )) -eq 0 ]; then
    escalate_now=true
    slug_names_csv="$("$JQ" -r '. | join(",")' <<<"$slugs_sorted" 2>/dev/null)"
    journal_line --file "$GRT_JOURNAL" "$now_ts  ALARM  gate-red-persistent  ticks=$streak slugs=${slug_names_csv}"
  fi
else
  rm -f "$STREAK_FILE" 2>/dev/null || true
fi

# ---- 4. alarm delivery / resolve (R3) ----
if [ "$red" -eq 0 ]; then
  if [ "$prev_red" -gt 0 ]; then
    "$ALERT_DELIVER" resolve gate-red build-loop >/dev/null 2>&1 || \
      journal_line --file "$GRT_JOURNAL" "$now_ts  gate-red-tick  resolve-failed  rc=$?"
  fi
  exit 0
fi

# red > 0: build the evidence file (summary line + the last 12
# red-pattern lines from the journal — same shape the 2026-09-16 stopgap
# used, so a human reading the GitHub issue sees the same thing either
# way).
mkdir -p "$STATE_DIR"
root="$(journal_root)"
today_file="$root/$(date -u +%F).md"
yday_file="$root/$(date -u -d yesterday +%F).md"
{
  printf '%s\n\n' "$summary_line"
  cat "$yday_file" "$today_file" 2>/dev/null | grep -E 'gate-block|verify-gate-red' | tail -12
} > "$EVIDENCE_FILE"

delivered_slugs="[]"
delivered_families="{}"
if [ -r "$DELIVERED_FILE" ]; then
  delivered_slugs="$("$JQ" -c '.slugs // []' "$DELIVERED_FILE" 2>/dev/null || echo '[]')"
  delivered_families="$("$JQ" -Sc '.families // {}' "$DELIVERED_FILE" 2>/dev/null || echo '{}')"
fi

record_delivered() {
  tmp="$(mktemp "$STATE_DIR/.gate-red.delivered.XXXXXX")"
  "$JQ" -n --argjson slugs "$slugs_sorted" --argjson families "$families_sorted" \
    --arg ts "$now_ts" '{ts:$ts, slugs:$slugs, families:$families}' > "$tmp"
  mv -f "$tmp" "$DELIVERED_FILE"
}

if ! alert_marker_exists gate-red build-loop; then
  "$ALERT_DELIVER" gate-red build-loop "$EVIDENCE_FILE" --value "$red" >/dev/null 2>&1
  ad_rc=$?
  [ "$ad_rc" -ne 0 ] && journal_line --file "$GRT_JOURNAL" "$now_ts  gate-red-tick  deliver-failed  rc=$ad_rc"
  record_delivered
  exit 0
fi

changed=false
[ "$slugs_sorted" != "$delivered_slugs" ] && changed=true
[ "$families_sorted" != "$delivered_families" ] && changed=true

if [ "$escalate_now" = true ]; then
  "$ALERT_DELIVER" gate-red build-loop "$EVIDENCE_FILE" --value "$streak" --comment >/dev/null 2>&1
  ad_rc=$?
  [ "$ad_rc" -ne 0 ] && journal_line --file "$GRT_JOURNAL" "$now_ts  gate-red-tick  escalation-deliver-failed  rc=$ad_rc"
  record_delivered
elif [ "$changed" = true ]; then
  "$ALERT_DELIVER" gate-red build-loop "$EVIDENCE_FILE" --value "$red" --comment >/dev/null 2>&1
  ad_rc=$?
  [ "$ad_rc" -ne 0 ] && journal_line --file "$GRT_JOURNAL" "$now_ts  gate-red-tick  update-deliver-failed  rc=$ad_rc"
  record_delivered
fi

exit 0
