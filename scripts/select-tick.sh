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
#                   [--explain <slug>] [--dry-run]
#
# --format json (default): one JSON object on stdout (jq -S, stable order):
#   {"admitted":[{slug,path,build_target,build_into,build_priority,
#                 continuation,shared_target,model}],
#    "skipped":[{slug,reason,detail}],
#    "counts":{pool,admitted,skipped,cap,distinct_targets,burst_session,sub_cap}}
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
#   - "verified-within-24h": state/manifest.json has no `verified_at`
#     timestamp field anywhere in this repo today, so there is nothing to
#     key that leg on yet. Wired below to a `verified_at` manifest field if
#     one ever appears; a no-op until then.
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
SCAN_PRDS="$HERE/scan-prds.sh"
SELECT_GUARD="$HERE/select-guard.sh"
BURST_LANE_SH="${BURST_LANE_SH:-$HERE/burst-lane.sh}"

die() { echo "select-tick: $*" >&2; exit "${2:-4}"; }
usage() {
  echo "usage: select-tick.sh [--prd-dir <dir>] [--lane <host>] [--format json|text] [--explain <slug>] [--dry-run]" >&2
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

while [ $# -gt 0 ]; do
  case "$1" in
    --prd-dir) [ $# -ge 2 ] || usage; PRD_DIR_ARG="$2"; shift 2 ;;
    --lane) [ $# -ge 2 ] || usage; LANE_ARG="$2"; shift 2 ;;
    --format) [ $# -ge 2 ] || usage; FORMAT="$2"; shift 2 ;;
    --explain) [ $# -ge 2 ] || usage; EXPLAIN_SLUG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$FORMAT" in json|text) ;; *) usage ;; esac

STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"

# Same journal convention every other build script in this directory uses
# (select-guard.sh's SELECT_GUARD_JOURNAL, scan-prds.sh's JOURNAL) --
# overridable so a selftest never touches the real shared journal.
JOURNAL="${SELECT_TICK_JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
journal_line() {
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$JOURNAL" 2>/dev/null || true
}

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
import json, os, re, sys

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
    # requirement 1's "verified-within-24h" leg: no verified_at field exists
    # in state/manifest.json anywhere in this repo yet (iter-1 scope gap,
    # documented in select-tick.sh's own header) -- wired here so it starts
    # working the moment one is added, a no-op until then.
    verified_at = entry.get("verified_at")
    if verified_at:
        try:
            import datetime
            vt = datetime.datetime.strptime(verified_at, "%Y-%m-%dT%H:%M:%SZ")
            age_h = (datetime.datetime.utcnow() - vt).total_seconds() / 3600.0
            if age_h < 24 and status == "queued":
                prefiltered.append({"slug": slug, "reason": "verified-within-24h", "detail": f"verified_at={verified_at}"})
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

pool_count="$(printf '%s' "$queue_json" | "$JQ" 'length')"

# Effective caps, computed identically to select-guard.sh's own resolution
# (mirrored here purely for the counts.cap/counts.sub_cap summary -- the
# actual enforcement still happens inside select-guard.sh, never duplicated).
limit="${BUILD_MAX_BRANCHES:-30}"
case "$limit" in ''|*[!0-9]*|0) limit=30 ;; esac
same_target_cap="${BUILD_SAME_TARGET_CAP:-1}"
case "$same_target_cap" in ''|*[!0-9]*|0) same_target_cap=1 ;; esac
distinct_targets=0
case "${BUILD_DISTINCT_TARGETS:-}" in
  1) distinct_targets=1; same_target_cap=1 ;;
  0) same_target_cap=999999 ;;
esac

burst_session=0
if [ -x "$BURST_LANE_SH" ]; then
  bstatus="$("$BURST_LANE_SH" status --json 2>/dev/null || true)"
  gr="$(printf '%s' "$bstatus" | "$JQ" -r '.gate_ready // empty' 2>/dev/null || true)"
  [ "$gr" = "true" ] && burst_session=1
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

  out="$("$SELECT_GUARD" "$slug" "$LANE_ARG" "$PRD_DIR_ARG" "$branch_count" "$admitted_targets" 2>/dev/null)"
  rc=$?

  if [ -n "$EXPLAIN_SLUG" ] && [ "$slug" = "$EXPLAIN_SLUG" ]; then
    explain_lines+=("passed: scan")
    explain_lines+=("passed: hard-prefilter")
    explain_lines+=("passed: depends-on")
    if [ "$rc" -eq 0 ]; then
      explain_lines+=("guard: $out")
      explain_lines+=("result: admitted")
    else
      explain_lines+=("guard (first failure): $out")
      explain_lines+=("result: skipped")
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
      '{slug:$slug, path:$path, build_target:$build_target, build_priority:$build_priority, build_into:$build_into, continuation:$continuation, model:$model}')"
    admitted_entries+=("$entry")
    branch_count=$((branch_count + 1))
    if [ "$continuation" != "true" ] && [ "$build_into" != "null" ]; then
      bi_bare="$(printf '%s' "$build_into" | "$JQ" -r '.')"
      admitted_targets="${admitted_targets:+$admitted_targets,}$bi_bare"
    fi
  else
    reason="blocked"
    case "$out" in
      *"cap: "*) reason="cap" ;;
      *"same-target: "*) reason="same-target" ;;
      *"busy: "*) reason="busy" ;;
      *"cargo-bound"*) reason="cargo-bound" ;;
    esac
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
    explain_lines+=("failed: hard-prefilter -- $detail")
    explain_lines+=("result: skipped ($reason)")
  elif [ -n "$dw" ]; then
    detail="$(printf '%s' "$dw" | "$JQ" -r '.detail')"
    explain_lines+=("passed: scan")
    explain_lines+=("passed: hard-prefilter")
    explain_lines+=("failed: depends-on -- waiting on $detail")
    explain_lines+=("result: skipped (waiting-on)")
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

result_json="$("$JQ" -n \
  --argjson admitted "$admitted_json" \
  --argjson skipped "$skipped_json" \
  --argjson pool "$pool_count" \
  --argjson admitted_n "$admitted_count" \
  --argjson skipped_n "$skipped_count" \
  --argjson cap "$limit" \
  --argjson distinct_targets "$distinct_targets" \
  --argjson burst_session "$burst_session" \
  --argjson sub_cap "$same_target_cap" \
  '{admitted:$admitted, skipped:$skipped,
    counts:{pool:$pool, admitted:$admitted_n, skipped:$skipped_n, cap:$cap,
            distinct_targets:$distinct_targets, burst_session:$burst_session, sub_cap:$sub_cap}}')"

result_json="$(printf '%s' "$result_json" | "$JQ" -S .)"

echo "$result_json"
if [ "$FORMAT" = "text" ]; then
  printf '%s' "$skipped_json" | "$JQ" -r '.[] | "skip \(.slug) \(.reason) \(.detail)"'
fi

if [ "$DRY_RUN" = false ]; then
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  select-tick  admitted=$admitted_count skipped=$skipped_count pool=$pool_count cap=$limit distinct_targets=$distinct_targets burst_session=$burst_session sub_cap=$same_target_cap lane=$LANE_ARG"
fi

exit 0
