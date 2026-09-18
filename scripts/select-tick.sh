#!/usr/bin/env bash
# select-tick.sh — one script owns the whole pool-to-admitted transformation
# for a /build tick (PRD-build-select-tick-deterministic).
#
# Grounding: 2026-09-15 07:11Z tick dispatched 2 PRDs, then evaluated 7 more
# via select-guard.sh at 07:34-07:35Z and dispatched nothing (a second
# selection pass is forbidden) -- selection was prose the Sonnet coordinator
# executed step by step, so "dispatch" was one step among many instead of
# the last one. This script composes the existing, unchanged guards
# (scan-prds.sh -> hard pre-filter -> Depends-on -> continuations-first ->
# priority sort -> select-guard.sh, threading branch-count/admitted-targets
# exactly as select-guard-selftest.sh already demonstrates by hand) into
# ONE call that emits the whole admitted set plus a machine-readable reason
# for every non-admission. The coordinator's only remaining job is to
# dispatch admitted[] verbatim, in one message.
#
# Usage:
#   select-tick.sh [--prd-dir <dir>] [--lane <host>] [--format json|text]
#                   [--explain <slug>] [--dry-run] [--pin <slug>[,<slug>...]]
#
# --format json (default): one JSON object on stdout (jq -S, stable order):
#   {"admitted":[{slug,path,build_target,build_into,build_priority,
#                 continuation,shared_target,model,pinned,
#                 operator_authorization}],
#    "skipped":[{slug,reason,detail,pinned}],
#    "pinned":[<slug>...],
#    "counts":{pool,admitted,skipped,cap,distinct_targets,burst_session,sub_cap}}
#
# --pin <slug>[,<slug>...] (repeatable; PRD-build-select-tick-run-pin):
# `BUILD_TICK_ARGS="run <slugs>"` is a pin, not a coordinator improvisation
# -- tick-run.sh derives this flag's value from that argv and threads it
# through as the SELECT_TICK_PIN env var (read below when --pin is absent
# on the command line, since the coordinator's own /build invocation never
# sees the slug list once tick-run.sh strips it). A pinned slug that
# survives the hard pre-filter and Depends-on gate is admitted first, in
# pin order, ahead of continuations and the priority sort -- it still goes
# through select-guard.sh (cap/same-target/lane-predicate) like any other
# candidate; a pin skips the queue, never the safety checks. Every pin's
# fate is journaled (`pin-over-cap`, `pin-refused cause=...`,
# `pin-unknown`) and each admitted/skipped entry above carries its own
# `pinned` boolean so `--explain` and a status sweep never have to
# recompute it from the pin list themselves.
#
# --format text: same JSON, followed by one `skip <slug> <reason> <detail>`
# line per skipped entry (requirement 2 — skips are listed one per line
# only under --format text or --explain, never inline in the json format's
# single journal line).
#
# --explain <slug>: prints the ordered checks <slug> passed and the first
# one it failed, with the guard's own output verbatim (requirement 6).
# Read-only: runs the same pipeline but never journals and never affects
# exit code beyond 0 (slug reached a verdict) / 2 (slug not in this tick's
# build-queue pool at all).
#
# --dry-run: identical JSON, no journal line written (requirement 7 —
# build-has-work.sh may call this so its own buildable=[...] list can
# never diverge from what a real tick would admit).
#
# Process visibility is NEVER an input (requirement 3): this script never
# calls pgrep, reads systemd unit state, or asks about any other
# coordinator. The only concurrency inputs are the claims and locks the
# composed guards already read (lane-claim.sh's Lane:/Status: frontmatter,
# select-guard.sh's caller-threaded branch-count/admitted-targets).
#
# Known scope gaps (iter-1 scaffold, PRD requirement 1's hard pre-filter):
#   - "verified-within-24h" is keyed on `action`/`last_action` (decision
#     bced982e; SKILL.md's own contract) -- a `verified_at` field was tried
#     first, but nothing in this repo ever writes it, so that leg was a
#     permanent no-op.
#   - `status: in_progress` is treated identically to `status: queued`
#     (SKILL.md's "in_progress AND last_action >= 1h ago" staleness
#     refinement is not mechanized this iteration).
# Model escalation (requirement 5) mechanizes only the two purely-
# mechanical legs of SKILL.md's Dispatch escalation list (`build_target:
# kernel-extend`, and prior-stall via `last_error` set / `ticks_invested
# >= 3`). The "build_priority: high AND architectural/ambiguous shape" leg
# needs judgment a script cannot supply — left to the coordinator to
# override per-entry if it disagrees, same as SKILL.md's own "when unsure,
# default to Sonnet" instruction.
#
# Exit 0  a verdict was reached and printed (json/text), or --explain found
#         the slug and printed its trace.
# Exit 2  --explain named a slug not in this tick's build-queue pool.
# Exit 4  usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

SCAN_PRDS="$HERE/scan-prds.sh"
SELECT_GUARD="$HERE/select-guard.sh"
BURST_LANE_SH="${BURST_LANE_SH:-$HERE/burst-lane.sh}"

die() { echo "select-tick: $*" >&2; exit "${2:-4}"; }
usage() {
  echo "usage: select-tick.sh [--prd-dir <dir>] [--lane <host>] [--format json|text] [--explain <slug>] [--dry-run] [--pin <slug>[,<slug>...]]" >&2
  exit 4
}

JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
[ -x "$JQ" ] || die "jq not found" 4
[ -x "$SCAN_PRDS" ] || die "scan-prds.sh not found or not executable: $SCAN_PRDS" 4
[ -x "$SELECT_GUARD" ] || die "select-guard.sh not found or not executable: $SELECT_GUARD" 4

PRD_DIR_ARG="$HOME/Documents/PRDs"
LANE_ARG="$(hostname)"
FORMAT="json"
EXPLAIN_SLUG=""
DRY_RUN=false
PIN_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --prd-dir) [ $# -ge 2 ] || usage; PRD_DIR_ARG="$2"; shift 2 ;;
    --lane) [ $# -ge 2 ] || usage; LANE_ARG="$2"; shift 2 ;;
    --format) [ $# -ge 2 ] || usage; FORMAT="$2"; shift 2 ;;
    --explain) [ $# -ge 2 ] || usage; EXPLAIN_SLUG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --pin) [ $# -ge 2 ] || usage; PIN_ARGS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$FORMAT" in json|text) ;; *) usage ;; esac

# --pin resolution (PRD-build-select-tick-run-pin requirement 2): an
# explicit --pin (repeatable, and/or comma-separated within one occurrence)
# always wins; SELECT_TICK_PIN is only a fallback default for the case the
# coordinator never passes --pin at all (tick-run.sh's own env handoff).
# Both "run a b" and "run a,b" resolve identically (AC5) -- split on comma
# OR whitespace, drop empties, dedupe preserving first-seen order.
declare -a PIN_SLUGS=()
_pin_source=""
if [ "${#PIN_ARGS[@]}" -gt 0 ]; then
  _pin_source="${PIN_ARGS[*]}"
elif [ -n "${SELECT_TICK_PIN:-}" ]; then
  _pin_source="$SELECT_TICK_PIN"
fi
if [ -n "$_pin_source" ]; then
  declare -a _pin_raw=()
  IFS=', ' read -r -a _pin_raw <<<"$_pin_source"
  for _p in "${_pin_raw[@]}"; do
    [ -n "$_p" ] || continue
    _dup=false
    for _q in "${PIN_SLUGS[@]}"; do [ "$_q" = "$_p" ] && _dup=true && break; done
    $_dup || PIN_SLUGS+=("$_p")
  done
fi

if [ "${#PIN_SLUGS[@]}" -gt 0 ]; then
  pin_slugs_json="$(printf '%s\n' "${PIN_SLUGS[@]}" | "$JQ" -R . | "$JQ" -s -c .)"
else
  pin_slugs_json='[]'
fi

explain_is_pinned=false
if [ -n "$EXPLAIN_SLUG" ]; then
  for _p in "${PIN_SLUGS[@]}"; do
    [ "$_p" = "$EXPLAIN_SLUG" ] && explain_is_pinned=true && break
  done
fi

STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"

# Same journal convention every other build script in this directory uses
# (select-guard.sh's SELECT_GUARD_JOURNAL, scan-prds.sh's JOURNAL) --
# overridable so a selftest never touches the real shared journal.
JOURNAL="${SELECT_TICK_JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
# journal_line is now the shared scripts/lib/journal.sh one (sourced
# above); this script's own $JOURNAL is an absolute --file target on the
# call site below (PRD-build-test-isolation-by-default).

# --- Step 1: scan (post-reconcile, post-lint -- scan-prds.sh's own lint
# pass already ran and parked anything mechanically defective before this
# script ever sees the pool). ------------------------------------------------
pool_json="$(PRD_DIR="$PRD_DIR_ARG" "$SCAN_PRDS" 2>/dev/null)" \
  || die "scan-prds.sh failed" 4
queue_json="$(printf '%s' "$pool_json" | "$JQ" -c '[.[] | select(.path | test("/build-queue/"))]')"

# --- Step 2: hard pre-filter + Depends-on + own-claim-continuations-first,
# all in one python pass (needs the PRD file's own Status:/Lane:/Depends-on:
# frontmatter lines, which scan-prds.sh's JSON does not carry verbatim).
# Written to a temp file rather than `python3 - <<PYEOF` because `-` reads
# the SCRIPT from stdin -- a heredoc there would consume the fd the piped
# queue_json needs, leaving nothing for sys.stdin.read() below.
STAGE_PY="$(mktemp "${TMPDIR:-/tmp}/select-tick-stage.XXXXXX.py")"
trap 'rm -f "$STAGE_PY"' EXIT
cat > "$STAGE_PY" <<'PYEOF'
import datetime, json, os, re, sys

manifest_path, lane = sys.argv[1], sys.argv[2]
pool = json.loads(sys.stdin.read())

try:
    with open(manifest_path) as f:
        m = json.load(f)
    prds = m.get("prds", {})
except Exception:
    prds = {}
if isinstance(prds, list):
    prds = {p.get("slug"): p for p in prds if isinstance(p, dict) and p.get("slug")}

pool_slugs = {c["slug"] for c in pool}

KEY_RE = {
    "status": re.compile(r'^(?:-\s*|\*\*)?Status:(?:\*\*)?\s*(.*)$'),
    "lane": re.compile(r'^(?:-\s*|\*\*)?Lane:(?:\*\*)?\s*(.*)$'),
    "depends_on": re.compile(r'^(?:-\s*|\*\*)?Depends-on:(?:\*\*)?\s*(.*)$'),
}

def read_frontmatter(path):
    out = {"status": "", "lane": "", "depends_on": ""}
    seen = set()
    try:
        with open(path, errors="replace") as f:
            lines = [next(f, "") for _ in range(80)]
    except Exception:
        return out
    for line in lines:
        line = line.rstrip("\n")
        for key, rx in KEY_RE.items():
            if key in seen:
                continue
            mo = rx.match(line.strip())
            if mo:
                val = mo.group(1)
                val = re.sub(r'\s+#.*$', '', val).strip()
                out[key] = val
                seen.add(key)
    return out

def slug_of(name):
    name = name.strip()
    name = re.sub(r'^PRD-', '', name)
    name = re.sub(r'\.md$', '', name)
    return name

def parse_depends_on(raw):
    if not raw:
        return []
    if raw.strip().lower() in ("none", "-", "n/a", "na", "[]"):
        return []
    return [t.strip() for t in raw.split(",") if t.strip()]

# Terminal/parked manifest statuses this tick must never admit.
HARD_BLOCK_STATUSES = {"archived", "vanished", "needs_classification", "parked"}

survivors = []
prefiltered = []
depwait = []

for c in pool:
    slug = c["slug"]
    entry = prds.get(slug, {}) if isinstance(prds, dict) else {}
    status = (entry.get("status") or "").strip()

    if status in HARD_BLOCK_STATUSES:
        prefiltered.append({"slug": slug, "reason": status, "detail": f"manifest status={status}"})
        continue
    # requirement 1's "verified-within-24h" leg, keyed on the contract
    # SKILL.md actually documents (`status: queued` but `last_action` is
    # within 24h with `action: verified-*`) -- NOT the `verified_at` field
    # nothing in this repo ever writes (build-burst-gate-canary-invariant
    # burned 10 dispatches re-admitting a verified-blocked PRD every tick
    # with no cooldown, decision bced982e).
    action = (entry.get("action") or "").strip()
    last_action = entry.get("last_action")
    if status == "queued" and action.startswith("verified-") and last_action:
        try:
            la = datetime.datetime.strptime(last_action, "%Y-%m-%dT%H:%M:%SZ")
            age_h = (datetime.datetime.utcnow() - la).total_seconds() / 3600.0
            if age_h < 24:
                prefiltered.append({"slug": slug, "reason": "verified-within-24h", "detail": f"action={action} last_action={last_action}"})
                continue
        except Exception:
            pass

    fm = read_frontmatter(c["path"])
    dep_names = parse_depends_on(fm["depends_on"])
    waiting_on = None
    for dep in dep_names:
        dep_slug = slug_of(dep)
        if dep_slug in pool_slugs:
            waiting_on = dep_slug
            break
    if waiting_on:
        depwait.append({"slug": slug, "reason": "waiting-on", "detail": waiting_on})
        continue

    continuation = False
    lane_field = fm["lane"].strip()
    status_field = fm["status"].strip().lower()
    if lane_field and status_field.startswith("building"):
        lane_host = lane_field.split()[0] if lane_field.split() else ""
        if lane_host.lower() == lane.lower():
            continuation = True

    survivors.append({
        "slug": slug,
        "path": c["path"],
        "build_target": c.get("build_target"),
        "build_priority": c.get("build_priority"),
        "build_into": c.get("build_into"),
        "continuation": continuation,
        "last_error": entry.get("last_error"),
        "ticks_invested": entry.get("ticks_invested") or 0,
    })

# Continuations first, preserving scan-prds.sh's own priority-sorted order
# within each bucket (PRD-build-claims-resume-not-count).
continuations = [s for s in survivors if s["continuation"]]
rest = [s for s in survivors if not s["continuation"]]

print(json.dumps({
    "survivors": continuations + rest,
    "prefiltered": prefiltered,
    "depwait": depwait,
}))
PYEOF
staged_json="$(printf '%s' "$queue_json" | python3 "$STAGE_PY" "$MANIFEST" "$LANE_ARG")" \
  || die "selection preprocessing failed" 4

survivors_json="$(printf '%s' "$staged_json" | "$JQ" -c '.survivors')"
prefiltered_json="$(printf '%s' "$staged_json" | "$JQ" -c '.prefiltered')"
depwait_json="$(printf '%s' "$staged_json" | "$JQ" -c '.depwait')"

# Pin ordering (requirement 1): pinned survivors move to the front, in pin
# order, ahead of continuations and the priority sort. A pin naming a slug
# that never reached survivors (hard-prefiltered, depends-on-waiting, or
# unknown to this tick's pool entirely) simply matches nothing here --
# resolved into a journal line further below, once admitted/skipped are final.
if [ "${#PIN_SLUGS[@]}" -gt 0 ]; then
  survivors_json="$(printf '%s' "$survivors_json" | "$JQ" -c --argjson pins "$pin_slugs_json" '
    . as $all
    | ( [ $pins[] as $p | ($all[] | select(.slug == $p)) ] ) as $pinned
    | ($pinned | map(.slug)) as $pinned_slugs
    | ($all | map(select(.slug as $s | ($pinned_slugs | index($s)) == null))) as $rest
    | $pinned + $rest
  ')"
fi

pool_count="$(printf '%s' "$queue_json" | "$JQ" 'length')"

# Effective caps, computed identically to select-guard.sh's own resolution
# (mirrored here purely for the counts.cap/counts.sub_cap summary -- the
# actual enforcement still happens inside select-guard.sh, never duplicated).
#
# Cap clamp (PRD-build-tick-under-dispatch-ledger requirement 5): the
# harness itself caps a tick at BUILD_SUBAGENT_LIMIT concurrent subagents
# (observed 20 on 2026-09-15T12:19:32Z) -- BUILD_MAX_BRANCHES raised above
# that (e.g. 30) admits PRDs that can never actually be dispatched, every
# tick, silently. `limit` below is the EFFECTIVE cap used everywhere after
# this point (counts.cap, the summary journal line, and the BUILD_MAX_BRANCHES
# override threaded into every select-guard.sh call below) -- the raw
# requested value only survives in `requested_limit` for the cap-clamped
# journal line's own `requested=` field.
requested_limit="${BUILD_MAX_BRANCHES:-30}"
case "$requested_limit" in ''|*[!0-9]*|0) requested_limit=30 ;; esac
subagent_limit="${BUILD_SUBAGENT_LIMIT:-20}"
case "$subagent_limit" in ''|*[!0-9]*|0) subagent_limit=20 ;; esac
limit="$requested_limit"
cap_clamped=false
if [ "$requested_limit" -gt "$subagent_limit" ]; then
  limit="$subagent_limit"
  cap_clamped=true
fi
same_target_cap="${BUILD_SAME_TARGET_CAP:-1}"
case "$same_target_cap" in ''|*[!0-9]*|0) same_target_cap=1 ;; esac
distinct_targets=0
case "${BUILD_DISTINCT_TARGETS:-}" in
  1) distinct_targets=1; same_target_cap=1 ;;
  0) same_target_cap=999999 ;;
esac

# Requirement 5: journaled once per tick, before the guard loop even
# starts -- never gated on there being anything admitted at all, only on
# --dry-run (build-has-work.sh's own dry-run probes must not journal).
if [ "$cap_clamped" = true ] && [ "$DRY_RUN" = false ]; then
  journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  cap-clamped  (requested=$requested_limit effective=$limit cause=subagent-limit)"
fi

burst_session=0
if [ -x "$BURST_LANE_SH" ]; then
  bstatus="$("$BURST_LANE_SH" status --json 2>/dev/null || true)"
  gr="$(printf '%s' "$bstatus" | "$JQ" -r '.gate_ready // empty' 2>/dev/null || true)"
  [ "$gr" = "true" ] && burst_session=1
fi

# PRD-build-burst-gate-canary-invariant R17: BUILD_BURST_ENABLED may only be
# 1 because burst-lane.sh's own `enable` wrote it, paired with a passing
# canary recorded in enable.json (R6, same PRD — enable now writes both
# knob files, see write_burst_knob_env() in burst-lane.sh). Every tick
# checks the live knob against that record: a knob read as 1 with no
# record at all, or a record whose canary is stale (>=24h) or not `pass`,
# means the knob was set by hand — exactly the 2026-09-15 23:38 EDT
# incident (both knob files hand-edited, no canary verdict, every mcphost
# gate red at 02:20 EDT). ALARM through the SAME gate-red channel
# PRD-build-gate-red-alarm-invariant already wires (never a second,
# competing notifier) and force routing off for THIS tick only: both
# burst_session and BUILD_BURST_ENABLED are reset to 0 here, before
# select-guard.sh's own per-candidate loop below runs, so every admitted
# gate this tick inherits BUILD_BURST_ENABLED=0 (AC21).
BURST_LANE_SYSTEMD_DROPIN="${BURST_LANE_SYSTEMD_DROPIN:-$HOME/.config/systemd/user/claude-build.service.d/burst.conf}"
BURST_LANE_ENV_FILE="${BURST_LANE_ENV_FILE:-$HOME/.config/wm-burst/.env}"
ALERT_DELIVER="${ALERT_DELIVER:-$HERE/alert-deliver.sh}"

knob_source=""
for knob_file in "$BURST_LANE_SYSTEMD_DROPIN" "$BURST_LANE_ENV_FILE"; do
  [ -r "$knob_file" ] || continue
  knob_val="$(grep -oE 'BUILD_BURST_ENABLED=[01]' "$knob_file" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
  if [ "$knob_val" = "1" ]; then
    knob_source="$(basename "$knob_file")"
    break
  fi
done

if [ -n "$knob_source" ]; then
  knob_enable_json="${BURST_LANE_STATE_DIR:-$SKILL_DIR/state/burst-lane}/enable.json"
  knob_cause=""
  knob_alarm=false
  if [ ! -f "$knob_enable_json" ]; then
    knob_alarm=true   # AC21: no record at all -- cause left blank
  else
    knob_canary_verdict="$("$JQ" -r '.canary_verdict // empty' "$knob_enable_json" 2>/dev/null || true)"
    knob_canary_ts="$("$JQ" -r '.canary_ts // empty' "$knob_enable_json" 2>/dev/null || true)"
    if [ "$knob_canary_verdict" != "pass" ]; then
      knob_cause="canary-not-pass"; knob_alarm=true
    else
      knob_ts_epoch="$(date -u -d "$knob_canary_ts" +%s 2>/dev/null || echo 0)"
      knob_now_epoch="$(date -u +%s)"
      if [ "$knob_ts_epoch" -le 0 ]; then
        knob_cause="canary-not-pass"; knob_alarm=true
      elif [ $(( (knob_now_epoch - knob_ts_epoch) / 3600 )) -ge 24 ]; then
        knob_cause="canary-stale"; knob_alarm=true   # AC23
      fi
    fi
  fi

  if [ "$knob_alarm" = true ]; then
    knob_alarm_text="ALARM burst-knob-unsanctioned (source=$knob_source${knob_cause:+ cause=$knob_cause})"
    if [ "$DRY_RUN" = false ]; then
      journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  $knob_alarm_text  lane=$LANE_ARG"
      knob_evidence="$(mktemp "${TMPDIR:-/tmp}/select-tick-knob-alarm.XXXXXX")"
      printf 'value=1 -- %s\n' "$knob_alarm_text" > "$knob_evidence"
      if [ -x "$ALERT_DELIVER" ]; then
        "$ALERT_DELIVER" gate-red build-loop "$knob_evidence" >/dev/null 2>&1 || true
      fi
      rm -f "$knob_evidence"
    fi
    burst_session=0
    export BUILD_BURST_ENABLED=0
  fi
fi

# --- Step 3: select-guard.sh per surviving candidate, threading
# branch-count/admitted-targets exactly as select-guard-selftest.sh already
# demonstrates by hand. Continuations are exempted from the running
# admitted-targets tally (their own build_into is never appended to it) so
# they never count against the same-target sub-cap for a NEW candidate
# (requirement AC7) -- they still count toward BUILD_MAX_BRANCHES overall,
# same as any other admission. -----------------------------------------------
admitted_entries=()
skipped_entries=()
explain_lines=()
branch_count=0
admitted_targets=""

n="$(printf '%s' "$survivors_json" | "$JQ" 'length')"
i=0
while [ "$i" -lt "$n" ]; do
  cand="$(printf '%s' "$survivors_json" | "$JQ" -c ".[$i]")"
  slug="$(printf '%s' "$cand" | "$JQ" -r '.slug')"
  path="$(printf '%s' "$cand" | "$JQ" -r '.path')"
  # -c (not -r): these feed --argjson below, which needs valid JSON text
  # (a bare unquoted string like `high` is not valid JSON; `-c` keeps the
  # quotes on a string and prints the bare `null` keyword for a null).
  build_target="$(printf '%s' "$cand" | "$JQ" -c '.build_target // null')"
  build_priority="$(printf '%s' "$cand" | "$JQ" -c '.build_priority // null')"
  build_into="$(printf '%s' "$cand" | "$JQ" -c '.build_into // null')"
  continuation="$(printf '%s' "$cand" | "$JQ" -r '.continuation')"
  last_error="$(printf '%s' "$cand" | "$JQ" -r '.last_error // ""')"
  ticks_invested="$(printf '%s' "$cand" | "$JQ" -r '.ticks_invested // 0')"
  # PRD-build-programmatic-dispatch: forwarded into admitted[] so
  # dispatch.sh's renderer (branch-contract.md directive 4) can inject the
  # authorization directive verbatim without re-reading the PRD file
  # itself -- scan-prds.sh already parses this per-PRD (-c, not -r: same
  # reason as build_target/build_priority/build_into above, this feeds
  # --argjson below).
  operator_authorization="$(printf '%s' "$cand" | "$JQ" -c '.operator_authorization // null')"

  # BUILD_MAX_BRANCHES overridden to the CLAMPED $limit for this one call
  # only (requirement 5) -- select-guard.sh reads BUILD_MAX_BRANCHES
  # straight from its own environment (default 30), so without this
  # override it would enforce the raw requested cap, not the effective one.
  out="$(BUILD_MAX_BRANCHES="$limit" "$SELECT_GUARD" "$slug" "$LANE_ARG" "$PRD_DIR_ARG" "$branch_count" "$admitted_targets" 2>/dev/null)"
  rc=$?

  # Computed here (once, before the explain block below needs it too --
  # requirement 6's "pinned-cause" line needs the same mapping the skipped
  # entry below uses) rather than re-derived twice from $out.
  reason=""
  if [ "$rc" -ne 0 ]; then
    reason="blocked"
    case "$out" in
      *"cap: "*) reason="cap" ;;
      *"same-target: "*) reason="same-target" ;;
      *"busy: "*) reason="busy" ;;
      *"cargo-bound"*) reason="cargo-bound" ;;
    esac
  fi

  if [ -n "$EXPLAIN_SLUG" ] && [ "$slug" = "$EXPLAIN_SLUG" ]; then
    explain_lines+=("passed: scan")
    explain_lines+=("passed: hard-prefilter")
    explain_lines+=("passed: depends-on")
    if [ "$explain_is_pinned" = true ]; then explain_lines+=("pinned: yes"); else explain_lines+=("pinned: no"); fi
    if [ "$rc" -eq 0 ]; then
      explain_lines+=("guard: $out")
      explain_lines+=("result: admitted")
    else
      explain_lines+=("guard (first failure): $out")
      explain_lines+=("result: skipped")
      if [ "$explain_is_pinned" = true ]; then
        if [ "$reason" = "cap" ]; then
          explain_lines+=("pinned-cause: over-cap")
        else
          explain_lines+=("pinned-cause: $reason")
        fi
      fi
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    model="sonnet"
    if [ "$build_target" = '"kernel-extend"' ] || [ "$build_target" = "kernel-extend" ]; then
      model="opus"
    elif [ -n "$last_error" ] && [ "$last_error" != "null" ]; then
      model="opus"
    else
      case "$ticks_invested" in
        ''|*[!0-9]*) ;;
        *) [ "$ticks_invested" -ge 3 ] && model="opus" ;;
      esac
    fi
    entry="$("$JQ" -n \
      --arg slug "$slug" --arg path "$path" \
      --argjson build_target "$build_target" \
      --argjson build_priority "$build_priority" \
      --argjson build_into "$build_into" \
      --argjson continuation "$continuation" \
      --arg model "$model" \
      --argjson operator_authorization "$operator_authorization" \
      '{slug:$slug, path:$path, build_target:$build_target, build_priority:$build_priority, build_into:$build_into, continuation:$continuation, model:$model, operator_authorization:$operator_authorization}')"
    admitted_entries+=("$entry")
    branch_count=$((branch_count + 1))
    if [ "$continuation" != "true" ] && [ "$build_into" != "null" ]; then
      bi_bare="$(printf '%s' "$build_into" | "$JQ" -r '.')"
      admitted_targets="${admitted_targets:+$admitted_targets,}$bi_bare"
    fi
  else
    detail="${out#*: *: }"
    [ -n "$detail" ] || detail="$out"
    skipped_entries+=("$("$JQ" -n --arg slug "$slug" --arg reason "$reason" --arg detail "$detail" '{slug:$slug, reason:$reason, detail:$detail}')")
  fi
  i=$((i + 1))
done

# --- Requirement --explain for a slug that never reached the guard loop
# (prefiltered / depends-on-blocked / not in this tick's pool at all). -----
if [ -n "$EXPLAIN_SLUG" ] && [ "${#explain_lines[@]}" -eq 0 ]; then
  pf="$(printf '%s' "$prefiltered_json" | "$JQ" -c --arg s "$EXPLAIN_SLUG" '.[] | select(.slug == $s)')"
  dw="$(printf '%s' "$depwait_json" | "$JQ" -c --arg s "$EXPLAIN_SLUG" '.[] | select(.slug == $s)')"
  if [ -n "$pf" ]; then
    reason="$(printf '%s' "$pf" | "$JQ" -r '.reason')"
    detail="$(printf '%s' "$pf" | "$JQ" -r '.detail')"
    explain_lines+=("passed: scan")
    if [ "$explain_is_pinned" = true ]; then explain_lines+=("pinned: yes"); else explain_lines+=("pinned: no"); fi
    explain_lines+=("failed: hard-prefilter -- $detail")
    explain_lines+=("result: skipped ($reason)")
    if [ "$explain_is_pinned" = true ]; then explain_lines+=("pinned-cause: $reason"); fi
  elif [ -n "$dw" ]; then
    detail="$(printf '%s' "$dw" | "$JQ" -r '.detail')"
    explain_lines+=("passed: scan")
    explain_lines+=("passed: hard-prefilter")
    if [ "$explain_is_pinned" = true ]; then explain_lines+=("pinned: yes"); else explain_lines+=("pinned: no"); fi
    explain_lines+=("failed: depends-on -- waiting on $detail")
    explain_lines+=("result: skipped (waiting-on)")
    if [ "$explain_is_pinned" = true ]; then explain_lines+=("pinned-cause: depends-on-unmet"); fi
  fi
fi

if [ -n "$EXPLAIN_SLUG" ]; then
  if [ "${#explain_lines[@]}" -eq 0 ]; then
    echo "select-tick: --explain: $EXPLAIN_SLUG not found in this tick's build-queue pool" >&2
    exit 2
  fi
  echo "explain: $EXPLAIN_SLUG"
  for l in "${explain_lines[@]}"; do echo "$l"; done
  exit 0
fi

# --- Assemble skipped[] = prefiltered + depwait + guard skips. -------------
all_skipped=()
n="$(printf '%s' "$prefiltered_json" | "$JQ" 'length')"
i=0
while [ "$i" -lt "$n" ]; do
  all_skipped+=("$(printf '%s' "$prefiltered_json" | "$JQ" -c ".[$i]")")
  i=$((i + 1))
done
n="$(printf '%s' "$depwait_json" | "$JQ" 'length')"
i=0
while [ "$i" -lt "$n" ]; do
  all_skipped+=("$(printf '%s' "$depwait_json" | "$JQ" -c ".[$i]")")
  i=$((i + 1))
done
all_skipped+=("${skipped_entries[@]}")

join_array() {
  # $@ = JSON object strings; prints a JSON array.
  local out="[" first=true
  for x in "$@"; do
    $first || out+=","
    first=false
    out+="$x"
  done
  out+="]"
  printf '%s' "$out"
}

admitted_json="$(join_array "${admitted_entries[@]}")"
skipped_json="$(join_array "${all_skipped[@]}")"

# shared_target: per-entry flag, true when >1 admitted entry shares a
# non-null build_into (Technical considerations / admitted[] shape).
admitted_json="$(printf '%s' "$admitted_json" | "$JQ" -c '
  ( [ .[] | select(.build_into != null) | .build_into ]
    | group_by(.) | map(select(length > 1) | .[0]) ) as $shared
  | map(. + {shared_target: (.build_into != null and (.build_into as $b | $shared | index($b)) != null)})
')"

admitted_count="$(printf '%s' "$admitted_json" | "$JQ" 'length')"
skipped_count="$(printf '%s' "$skipped_json" | "$JQ" 'length')"

# --- Pin stamping + outcome journaling (PRD-build-select-tick-run-pin
# requirements 1, 3, 4, 5). Runs unconditionally (pin_slugs_json is "[]"
# when no --pin/SELECT_TICK_PIN was given) so every admitted/skipped entry
# carries a "pinned" boolean regardless -- only the per-slug journal lines
# below are gated on there being any pins at all, and on --dry-run
# (requirement 7 of PRD-build-select-tick-deterministic: --dry-run never
# journals). -----------------------------------------------------------------
admitted_json="$(printf '%s' "$admitted_json" | "$JQ" -c --argjson pins "$pin_slugs_json" \
  'map(. + {pinned: ((.slug as $s | $pins | index($s)) != null)})')"
skipped_json="$(printf '%s' "$skipped_json" | "$JQ" -c --argjson pins "$pin_slugs_json" \
  'map(. + {pinned: ((.slug as $s | $pins | index($s)) != null)})')"
pinned_json="$("$JQ" -n --argjson pins "$pin_slugs_json" --argjson adm "$admitted_json" \
  '[$pins[] as $p | select($adm | any(.slug == $p)) | $p]')"
pinned_count="$(printf '%s' "$pinned_json" | "$JQ" 'length')"

if [ "$DRY_RUN" = false ]; then
  for _p in "${PIN_SLUGS[@]}"; do
    if printf '%s' "$admitted_json" | "$JQ" -e --arg s "$_p" 'any(.[]; .slug == $s)' >/dev/null 2>&1; then
      continue
    fi
    skip_entry="$(printf '%s' "$skipped_json" | "$JQ" -c --arg s "$_p" '[.[] | select(.slug == $s)][0] // empty')"
    if [ -z "$skip_entry" ]; then
      journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  pin-unknown  (slug=$_p)"
      continue
    fi
    pin_reason="$(printf '%s' "$skip_entry" | "$JQ" -r '.reason')"
    case "$pin_reason" in
      cap)
        journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  pin-over-cap  (slug=$_p cap=$limit)"
        ;;
      waiting-on)
        journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  pin-refused  (slug=$_p cause=depends-on-unmet)"
        ;;
      *)
        journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  pin-refused  (slug=$_p cause=$pin_reason)"
        ;;
    esac
  done
fi

result_json="$("$JQ" -n \
  --argjson admitted "$admitted_json" \
  --argjson skipped "$skipped_json" \
  --argjson pinned "$pinned_json" \
  --argjson pool "$pool_count" \
  --argjson admitted_n "$admitted_count" \
  --argjson skipped_n "$skipped_count" \
  --argjson cap "$limit" \
  --argjson distinct_targets "$distinct_targets" \
  --argjson burst_session "$burst_session" \
  --argjson sub_cap "$same_target_cap" \
  '{admitted:$admitted, skipped:$skipped, pinned:$pinned,
    counts:{pool:$pool, admitted:$admitted_n, skipped:$skipped_n, cap:$cap,
            distinct_targets:$distinct_targets, burst_session:$burst_session, sub_cap:$sub_cap}}')"

# --- Persistence (PRD-build-tick-under-dispatch-ledger requirement 1):
# "what did the tick admit" becomes a file read, not a journal grep. tick-id
# = the enclosing tick-run.sh holder's start epoch + its pid -- read from
# the SAME holder file tick-run.sh itself writes (state/tick.lock.holder,
# "pid boot_id started_epoch cmdline"), or SELECT_TICK_TICK_ID/
# SELECT_TICK_TICK_STARTED if tick-run.sh already exported them (it does,
# from 2026-09-16 on -- reading the holder file independently is the
# fallback for a standalone/manual select-tick.sh call with no enclosing
# tick-run.sh at all, which still must not crash here). ------------------
TICK_HOLDER_FILE="${SELECT_TICK_TICK_HOLDER_FILE:-$STATE_DIR/tick.lock.holder}"
_tick_id="${SELECT_TICK_TICK_ID:-}"
_tick_started="${SELECT_TICK_TICK_STARTED:-}"
if [ -z "$_tick_id" ] && [ -r "$TICK_HOLDER_FILE" ]; then
  _h_pid="" _h_bid="" _h_started="" _h_cmd=""
  IFS=' ' read -r _h_pid _h_bid _h_started _h_cmd < "$TICK_HOLDER_FILE" 2>/dev/null || true
  if [ -n "$_h_pid" ] && [ -n "$_h_started" ]; then
    _tick_id="${_h_started}-${_h_pid}"
    _tick_started="$_h_started"
  fi
fi
if [ -z "$_tick_id" ]; then
  _tick_started="$(date -u +%s)"
  _tick_id="${_tick_started}-$$"
fi
[ -n "$_tick_started" ] || _tick_started="$(date -u +%s)"
started_at_iso="$(date -u -d "@$_tick_started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# persist_json carries cap+started_at for the FILE only -- result_json
# itself (stdout) stays byte-identical between a real run and --dry-run
# (select-tick-selftest.sh AC10), which a wall-clock started_at field
# embedded in stdout would break the instant two calls landed in
# different seconds.
persist_json="$(printf '%s' "$result_json" | "$JQ" -c --argjson cap "$limit" --arg started_at "$started_at_iso" \
  '. + {cap:$cap, started_at:$started_at}')"

SELECT_TICK_STATE_DIR="${SELECT_TICK_STATE_DIR:-$STATE_DIR/select-tick}"
mkdir -p "$SELECT_TICK_STATE_DIR" 2>/dev/null || true
if [ -d "$SELECT_TICK_STATE_DIR" ]; then
  _outfile="$SELECT_TICK_STATE_DIR/${_tick_id}.json"
  _tmpfile="$(mktemp "$SELECT_TICK_STATE_DIR/.tmp.XXXXXX" 2>/dev/null || true)"
  if [ -n "$_tmpfile" ]; then
    printf '%s\n' "$persist_json" | "$JQ" -S . > "$_tmpfile" 2>/dev/null && mv -f "$_tmpfile" "$_outfile" \
      || rm -f "$_tmpfile" 2>/dev/null
    if [ -f "$_outfile" ]; then
      _tmplink="$SELECT_TICK_STATE_DIR/.last.json.tmp.$$"
      ln -sfn "$(basename "$_outfile")" "$_tmplink" 2>/dev/null \
        && mv -Tf "$_tmplink" "$SELECT_TICK_STATE_DIR/last.json" 2>/dev/null
    fi
  fi
fi

result_json="$(printf '%s' "$result_json" | "$JQ" -S .)"

echo "$result_json"
if [ "$FORMAT" = "text" ]; then
  printf '%s' "$skipped_json" | "$JQ" -r '.[] | "skip \(.slug) \(.reason) \(.detail)"'
fi

if [ "$DRY_RUN" = false ]; then
  journal_line --file "$JOURNAL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  admitted=$admitted_count skipped=$skipped_count pool=$pool_count cap=$limit distinct_targets=$distinct_targets burst_session=$burst_session sub_cap=$same_target_cap pinned=$pinned_count lane=$LANE_ARG"

  # PRD-build-gate-red-alarm-invariant R2: every tick computes and journals
  # the gate-red aggregate directly after its own tick-summary line above —
  # a red gate must never again go unreported the way six mcphost branches
  # did for 7h20m on 2026-09-16 with nothing anywhere saying "0 green, 6
  # red" (see that PRD's TL;DR / j0yen/prds#9). GATE_RED_TICK_JOURNAL pins
  # the write to this SAME $JOURNAL (see gate-red-tick.sh's own header for
  # why that matters under an isolated/overridden JOURNAL). Best-effort:
  # gate-red-tick.sh always exits 0 and journals its own failures rather
  # than ever failing a tick over an alarm-plumbing problem.
  GATE_RED_TICK="${GATE_RED_TICK:-$HERE/gate-red-tick.sh}"
  if [ -x "$GATE_RED_TICK" ]; then
    GATE_RED_TICK_JOURNAL="$JOURNAL" "$GATE_RED_TICK" >/dev/null 2>&1
  fi
fi

exit 0
