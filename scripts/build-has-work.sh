#!/usr/bin/env bash
# build-has-work.sh — ExecCondition pre-check for claude-build.service:
# launch a (paid, LLM) tick only when at least one queued PRD is actually
# buildable. Pure bash + git/python3, NO model call — a lane facing an
# all-claimed/all-gate-red queue must cost nothing to discover that
# (2026-09-12: 10 of 24 RedBaron ticks in one day spent a full Sonnet
# session just to learn nothing was buildable, ~4M tokens, right after the
# daily tick cap was removed). Modeled on lane-has-work.sh's PRD-parsing
# and pacing/logging convention, but host-agnostic: this is "is there any
# work at all", not lane-restriction/exclusivity (that's lane-predicate.sh's
# job and is unaffected by this script).
#
# Exit 0 => at least one buildable PRD queued — fire the tick.
# Exit 1 => none — but first `sleep ${BUILD_HASWORK_PACE:-300}`. This runs
#           as ExecCondition under a level-triggered path unit (see
#           systemd/carbon/claude-build.service.d/defer.conf's comment): an
#           unpaced condition-skip re-fires roughly once a second, hammering
#           this script (and any git/ssh it touches) in a tight loop. The
#           sleep holds the unit in "activating (condition)" for the pace
#           window instead. It must stay under the sibling pacing.conf's
#           TimeoutStartSec (400s) or systemd kills the unit as timed-out
#           mid-sleep and the launcher retries in a tight loop — 300 default
#           leaves 100s headroom, matching LANE_SKIP_PACE's existing budget.
#
# Predicate ("buildable") — CONSERVATIVE: bias toward "buildable" whenever
# anything is uncertain, missing, or fails to parse. A queued PRD is NOT
# buildable only if:
#   (a) it has a LIVE claim (age < the 3h staleness threshold lane-claim.sh
#       uses, STALE_SECS=3*3600) by ANY lane — checked via
#       `lane-claim.sh status <prd>` (the one place that owns claim
#       read/parse); or
#   (b) its most recent recorded gate verdict was a block (manifest.json's
#       prds.<slug>.next == "gate-red", the field SKILL.md's "gate" action
#       writes on `extend-gate.sh` exit 1) AND its build_into repo's
#       CURRENT HEAD equals the HEAD that verdict was cached at
#       (<build_into>/target/autobuilder/last-verdict.json's `head_sha` —
#       extend-gate.sh's own verdict cache). If the repo's HEAD has moved
#       since, re-gating is worthwhile: buildable.
# Everything else — brand-new/never-claimed, stale claim, never gated,
# gate-red-but-at-an-old-HEAD, delta-pass, or any PRD whose claim/manifest/
# verdict data is missing or fails to parse — counts as buildable.
#
# Statuses that can never be selected regardless (blocked, built, parked,
# needs_classification, archived) are skipped before the predicate runs,
# matching lane-has-work.sh.
#
# Logging: exactly one journal line per decision (never silent), appended
# to the same log lane-has-work.sh uses:
#   build-has-work  <work|no-work>  (buildable=[..] claimed=[..] gate-red-unchanged=[..] pace=<n>)
#
# Env:
#   BUILD_HASWORK_PACE     seconds to sleep before exit 1 (default 300).
#   BUILD_HASWORK_DISABLE=1  always exit 0 immediately, no sleep — still
#                            logs a disabled-passthrough line so a bypass
#                            is never silent either.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
STATE_DIR="${BUILD_STATE_DIR:-$HERE/../state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
LOG="${CLAUDE_BUILD_LOG:-$HOME/brain/journal/build-auto.log}"
PACE="${BUILD_HASWORK_PACE:-300}"
LANE_CLAIM="$HERE/lane-claim.sh"

# Resolve external tools via `command -v` rather than hardcoded paths — a
# past incident here (hardcoded /usr/sbin/jq) silently killed hooks.
GIT="$(command -v git || true)"
PYTHON3="$(command -v python3 || true)"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  echo "$(ts) build-has-work: $*" >> "$LOG"
}

# Comma-join an array into "[a,b,c]" ("[]" when empty).
fmt_list() {
  local IFS=,
  echo "[$*]"
}

if [ "${BUILD_HASWORK_DISABLE:-0}" = "1" ]; then
  logline "build-has-work  work  (disabled-passthrough pace=$PACE)"
  exit 0
fi

status_of() {
  head -n 80 "$1" | grep -E '^(- *Status:|Status:|\*\*Status:\*\*)' | head -n1 \
    | sed -E 's/^(- *Status:|Status:|\*\*Status:\*\*)[[:space:]]*//' | awk '{print $1}'
}

read_field() {
  # $1 = file, $2 = key (e.g. build_into)
  local f="$1" key="$2"
  head -n 80 "$f" | grep -E "^(- *${key}:|${key}:|\*\*${key}:\*\*)" -i | head -n1 \
    | sed -E "s/^(- *${key}:|${key}:|\*\*${key}:\*\*)[[:space:]]*//I" \
    | sed -E 's/[[:space:]]*#.*$//'
}

slug_of() { basename "$1" .md | sed -E 's/^PRD-//'; }

# (a) LIVE claim by any lane. Returns 0 = live claim exists (blocks
# buildability), 1 = no live claim (or could-not-check — bias buildable).
# Deliberately uses the PLAIN status output, not `--json`: lane-claim.sh's
# --json emits an unquoted `"stale":yes` / `"stale":no` literal (not valid
# JSON true/false) — a pre-existing bug in that script, out of scope here
# to fix, so this script parses the plain `status` line instead.
is_live_claim() {
  local prd="$1" out
  [ -x "$LANE_CLAIM" ] || return 1
  out="$("$LANE_CLAIM" status "$prd" 2>/dev/null)" || return 1
  case "$out" in
    free) return 1 ;;
    *" stale=no") return 0 ;;
    *" stale=yes") return 1 ;;
    *) return 1 ;;  # unparseable — bias buildable
  esac
}

# (b) most recent gate verdict was block/gate-red at the repo's CURRENT
# HEAD. Returns 0 = gate-red-unchanged (blocks buildability), 1 =
# buildable (never gated, delta-pass, gate-red-but-moved-HEAD, or any
# missing/unparseable data).
is_gate_red_unchanged() {
  local prd="$1" slug bi manifest_next verdict_file head_now head_cached
  [ -n "$PYTHON3" ] || return 1
  [ -f "$MANIFEST" ] || return 1
  slug="$(slug_of "$prd")"
  bi="$(read_field "$prd" build_into)"
  [ -n "$bi" ] || return 1

  manifest_next="$("$PYTHON3" -c '
import json, sys
manifest_path, slug = sys.argv[1], sys.argv[2]
try:
    m = json.load(open(manifest_path))
except Exception:
    print("")
    sys.exit(0)
prds = m.get("prds", {})
if isinstance(prds, list):
    entry = next((p for p in prds if isinstance(p, dict) and p.get("slug") == slug), {})
elif isinstance(prds, dict):
    entry = prds.get(slug, {})
else:
    entry = {}
print(entry.get("next") or "" if isinstance(entry, dict) else "")
' "$MANIFEST" "$slug" 2>/dev/null)"
  [ "$manifest_next" = "gate-red" ] || return 1

  verdict_file="$bi/target/autobuilder/last-verdict.json"
  [ -f "$verdict_file" ] || return 1
  [ -n "$GIT" ] || return 1
  [ -d "$bi/.git" ] || return 1
  head_now="$("$GIT" -C "$bi" rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$head_now" ] || return 1

  head_cached="$("$PYTHON3" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("")
    sys.exit(0)
print(d.get("head_sha") or "")
' "$verdict_file" 2>/dev/null)"
  [ -n "$head_cached" ] || return 1

  [ "$head_cached" = "$head_now" ]
}

buildable=() claimed=() gate_red=()

if [ -d "$PRD_DIR/build-queue" ]; then
  for prd in "$PRD_DIR"/build-queue/*.md; do
    [ -f "$prd" ] || continue
    case "$(status_of "$prd")" in
      blocked|built|parked|needs_classification|archived) continue ;;
    esac
    slug="$(slug_of "$prd")"
    if is_live_claim "$prd"; then
      claimed+=("$slug")
      continue
    fi
    if is_gate_red_unchanged "$prd"; then
      gate_red+=("$slug")
      continue
    fi
    buildable+=("$slug")
  done
fi

decision="no-work"
[ "${#buildable[@]}" -gt 0 ] && decision="work"

logline "build-has-work  $decision  (buildable=$(fmt_list "${buildable[@]}") claimed=$(fmt_list "${claimed[@]}") gate-red-unchanged=$(fmt_list "${gate_red[@]}") pace=$PACE)"

if [ "$decision" = "work" ]; then
  exit 0
fi
sleep "$PACE"
exit 1
