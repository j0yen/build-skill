#!/usr/bin/env bash
# manifest-invariants.sh — audit every manifest entry against
# docs/manifest-transitions.md each tick; heal mechanical violations, alarm
# the rest (PRD-build-manifest-invariants).
#
# Every forgotten inverse in this state machine became its own incident and
# its own hand-written playbook: `needs_classification` was a one-way trap
# until 2026-09-09 (two lint-passing PRDs parked indefinitely, fixed as a
# one-off instance in 1e9af92), `blocked` + empty `blockers[]` mis-parks a
# PRD that isn't really blocked, stale version-collision blockers accumulate
# (clear-stale-blockers.sh's old beat), and a `shipped` PRD whose git-mv
# never landed lags silently. This script makes the transition table in
# docs/manifest-transitions.md (which see for the full predecessor/successor/
# writer/inverse story) into something a tick actually re-checks, instead of
# trusting every future writer to remember every inverse.
#
# Usage:
#   manifest-invariants.sh [--report] [--format table|json] [--prd-dir DIR]
#
# --report    Read-only: compute and print the full audit (heals that WOULD
#             fire + alarms that WOULD fire) without writing anything. The
#             manifest file's mtime/content is provably unchanged (AC7).
# --format    table (default, human-readable) or json.
# --prd-dir   Root containing build-queue/ / built-prds/ / parked/
#             (default $HOME/Documents/PRDs).
#
# Env overrides (same convention as manifest-set.sh / manifest-reconcile.sh,
# used by the selftests to sandbox state): BUILD_SKILL_DIR, BUILD_STATE_DIR,
# BUILD_MANIFEST, LOCK (tick.lock path), MANIFEST_SET (manifest-set.sh path),
# PRD_LINT (prd-lint.sh path), LANE_CLAIM (lane-claim.sh path),
# SHIPPED_NOT_ARCHIVED_MINUTES (default 20 — see docs/manifest-transitions.md
# "shipped" — the exact N is an open PRD question pending a week of
# measurement), STALE_ACTIVITY_HOURS (default 24), LOCK_WAIT_SECS (default
# 60 — the PRD's "60s" ceiling; selftests shrink this to keep runs fast),
# DOCKET_RUN (docket --run
# value, default a UTC timestamp), JOURNAL (default
# ~/brain/journal/build/<today>.md).
#
# Runs under tick.lock (requirement 4): a concurrent tick already holding it
# is normal, expected contention, not a script error — on a 60s wait ceiling
# this exits 0 having changed nothing (AC5), the same "exit clean, don't
# alarm" posture the rest of Phase 1 takes on lock contention.
#
# Heals are applied one at a time via manifest-set.sh (same locked,
# write-ahead-intent, atomic-rename path every other Phase 4/7 writer uses —
# "Branches MUST NOT hand-roll lock + RMW logic", SKILL.md Phase 7). A
# `parked` entry is never inspected for either heal or alarm eligibility
# (requirement 4 / AC4) — it is skipped before any rule runs. An entry whose
# status is not one of the eleven named in docs/manifest-transitions.md is
# never healed, only alarmed (AC3).
#
# Exit: 0 ok (healed/alarmed/reported, or lock-contended no-op) | 2 usage |
#       1 environment error (python3 missing, manifest unreadable, PRD_DIR
#       absent).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
LOCK="${LOCK:-$STATE_DIR/tick.lock}"
MANIFEST_SET="${MANIFEST_SET:-$HERE/manifest-set.sh}"
PRD_LINT="${PRD_LINT:-$HERE/prd-lint.sh}"
LANE_CLAIM="${LANE_CLAIM:-$HERE/lane-claim.sh}"
SHIPPED_NOT_ARCHIVED_MINUTES="${SHIPPED_NOT_ARCHIVED_MINUTES:-20}"
STALE_ACTIVITY_HOURS="${STALE_ACTIVITY_HOURS:-24}"
LOCK_WAIT_SECS="${LOCK_WAIT_SECS:-60}"
JOURNAL="${JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
DOCKET_RUN="${DOCKET_RUN:-manifest-invariants.$(date -u +%Y%m%dT%H%M%SZ)}"

log() { printf 'manifest-invariants: %s\n' "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

report_mode=false
format=table

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)       report_mode=true; shift ;;
    --format)       format="${2:-table}"; shift 2 ;;
    --format=*)     format="${1#--format=}"; shift ;;
    --prd-dir)      PRD_DIR="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$format" in
  table|json) ;;
  *) die "--format must be table or json (got '$format')" 2 ;;
esac

[ -d "$PRD_DIR" ] || die "PRD_DIR not found: $PRD_DIR"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true

# ---- tick.lock (requirement 4) --------------------------------------------
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
exec 9>"$LOCK"
if ! flock -w "$LOCK_WAIT_SECS" 9; then
  log "tick.lock held >60s — no changes made, exiting cleanly"
  if [ "$format" = json ]; then
    echo '{"status":"lock-contended","healed":0,"alarmed":0}'
  fi
  exit 0
fi
# fd 9 (and the lock) is released automatically when this process exits.

# ---- Pass 1 (pure, no writes): compute the full plan as one JSON object on
# stdout, exactly the manifest-reconcile.sh pattern (bash never re-parses
# manifest/PRD text itself; python does the one read). ----------------------
plan_json="$(MANIFEST="$MANIFEST" PRD_DIR="$PRD_DIR" \
             SHIPPED_NOT_ARCHIVED_MINUTES="$SHIPPED_NOT_ARCHIVED_MINUTES" \
             STALE_ACTIVITY_HOURS="$STALE_ACTIVITY_HOURS" \
             python3 <<'PY'
import json, os, re, sys, datetime

manifest_path = os.environ["MANIFEST"]
prd_dir = os.environ["PRD_DIR"]
shipped_minutes = float(os.environ["SHIPPED_NOT_ARCHIVED_MINUTES"])
stale_hours = float(os.environ["STALE_ACTIVITY_HOURS"])
now = datetime.datetime.now(datetime.timezone.utc)

# The eleven statuses named in docs/manifest-transitions.md. Kept hand-synced
# with that file by design (PRD Technical considerations: generating this
# from the doc is explicitly NOT required at this scale) — the table-coverage
# selftest (AC6) is the guard against silent drift for whatever's actually
# live, not full doc<->code parity.
KNOWN_STATUSES = {
    "queued", "building", "in_progress", "blocked", "shipped", "built",
    "archived", "parked", "needs_classification",
    "vanished", "notebook",  # auxiliary — owned entirely by other scripts
}

def utc_iso():
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return None

with open(manifest_path) as f:
    m = json.load(f)
prds = m.get("prds", {})
if isinstance(prds, list):
    entries = {p.get("slug"): p for p in prds if isinstance(p, dict) and p.get("slug")}
else:
    entries = dict(prds) if isinstance(prds, dict) else {}

# ---- stale-version-collision-blocker: identical condition to the retired
# clear-stale-blockers.sh, absorbed here (docs/manifest-transitions.md
# "Absorbed scripts"). ------------------------------------------------------
collision_re = re.compile(r"^v(\d+\.\d+\.\d+)\s+collision\s+with\s+([\w-]+)\b")

def phasing_claims(text, version):
    pat = re.compile(r"\*\*\s*\d+[a-z]?\s*\(\s*v" + re.escape(version) + r"\s*\)")
    return len(pat.findall(text))

def read_prd_text(slug):
    p = os.path.join(prd_dir, "build-queue", f"PRD-{slug}.md")
    if not os.path.isfile(p):
        p = os.path.join(prd_dir, "built-prds", f"PRD-{slug}.md")
    if not os.path.isfile(p):
        return None
    with open(p, errors="replace") as f:
        return f.read()

def in_build_queue(slug):
    return os.path.isfile(os.path.join(prd_dir, "build-queue", f"PRD-{slug}.md"))

heals = []    # [{slug, rule, patch, note}]
alarms = []   # [{slug, class, message}]

for slug, entry in entries.items():
    status = entry.get("status")

    # requirement 4 / AC4: parked is never inspected, in either direction.
    if status == "parked":
        continue

    if status not in KNOWN_STATUSES:
        alarms.append({
            "slug": slug, "class": "unknown-status",
            "message": f"{slug} stuck in unrecognized status {status!r} "
                       f"(not in docs/manifest-transitions.md) — not modified",
        })
        continue

    blockers = entry.get("blockers") or []
    iter_log = entry.get("iter_log") or []

    # --- heal: blocked + empty blockers + empty iter_log -> queued --------
    if status == "blocked" and not blockers and not iter_log:
        heals.append({
            "slug": slug, "rule": "blocked-empty-blockers-empty-iterlog",
            "patch": {"status": "queued"},
            "note": f"{slug}: blocked with no blockers and no iter_log — queued",
        })
        status = "queued"  # so the loop below doesn't also alarm this pass

    # --- heal: needs_classification + prd-lint now passes -> queued -------
    elif status == "needs_classification":
        # lint verdict is filled in by the bash layer (needs a subprocess);
        # placeholder here, resolved below.
        heals.append({
            "slug": slug, "rule": "needs-classification-lint-pass",
            "patch": None,  # bash fills {"status":"queued","needs_classification_reason":""}
                            # iff prd-lint.sh exits 0 for this slug's path
            "note": f"{slug}: needs_classification, pending prd-lint re-check",
            "needs_lint_check": True,
            "path": entry.get("path"),
        })

    # --- heal: stale version-collision blockers ----------------------------
    if blockers:
        kept = []
        cleared = []
        this_text = read_prd_text(slug)
        for b in blockers:
            mc = collision_re.match(b)
            if not mc:
                kept.append(b)
                continue
            version, other = mc.group(1), mc.group(2)
            other_text = read_prd_text(other)
            if this_text is None or other_text is None:
                kept.append(b)
                continue
            a = phasing_claims(this_text, version)
            c = phasing_claims(other_text, version)
            if a + c <= 1:
                cleared.append(b)
            else:
                kept.append(b)
        if cleared:
            heals.append({
                "slug": slug, "rule": "stale-version-collision-blocker",
                "patch": {"blockers": kept},
                "note": f"{slug}: cleared {len(cleared)} stale version-collision "
                        f"blocker(s): {cleared}",
            })

    # --- alarm: shipped/built not archived after the threshold ------------
    if status in ("shipped", "built") and in_build_queue(slug):
        last_action = parse_ts(entry.get("last_action"))
        age_minutes = None
        if last_action is not None:
            age_minutes = (now - last_action).total_seconds() / 60.0
        if age_minutes is None or age_minutes >= shipped_minutes:
            alarms.append({
                "slug": slug, "class": "shipped-not-archived",
                "message": f"{slug} is status={status} but its file is still "
                           f"under build-queue/ "
                           f"(age={'unknown' if age_minutes is None else f'{age_minutes:.0f}m'}, "
                           f"threshold={shipped_minutes:.0f}m) — git-mv never landed",
            })

    # --- alarm: building/in_progress with no activity for STALE_ACTIVITY_HOURS
    if status in ("building", "in_progress"):
        last_action = parse_ts(entry.get("last_action"))
        recent_iter = False
        for il in iter_log:
            if isinstance(il, dict):
                ts = parse_ts(il.get("ts"))
                if ts is not None and (now - ts).total_seconds() <= stale_hours * 3600:
                    recent_iter = True
                    break
        activity_age_h = None
        if last_action is not None:
            activity_age_h = (now - last_action).total_seconds() / 3600.0
        stale = not recent_iter and (activity_age_h is None or activity_age_h >= stale_hours)
        if stale:
            alarms.append({
                "slug": slug, "class": "stale-activity",
                "message": f"{slug} is status={status} with no iter_log activity "
                           f"and last_action "
                           f"{'unknown' if activity_age_h is None else f'{activity_age_h:.1f}h ago'} "
                           f"(>= {stale_hours:.0f}h threshold)",
            })

print(json.dumps({"heals": heals, "alarms": alarms}, sort_keys=True))
PY
)"

if [ -z "$plan_json" ]; then
  die "plan computation produced no output"
fi

# ---- resolve needs_lint_check heals (needs a subprocess per slug; bash's
# job, not python's, since prd-lint.sh is a separate script) ----------------
resolved_heals_json="$(python3 - "$plan_json" <<'PY'
import json, sys
plan = json.loads(sys.argv[1])
print(json.dumps(plan["heals"]))
PY
)"

# Iterate heals; for needs_lint_check entries, shell out to prd-lint.sh and
# fill in the real patch (or drop the heal if lint still fails).
final_heals="[]"
while IFS= read -r heal_json; do
  [ -n "$heal_json" ] || continue
  needs_check="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("needs_lint_check", False))' "$heal_json")"
  if [ "$needs_check" = "True" ]; then
    path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("path") or "")' "$heal_json")"
    if [ -n "$path" ] && [ -f "$path" ] && "$PRD_LINT" "$path" >/dev/null 2>&1; then
      heal_json="$(python3 -c 'import json,sys
h=json.loads(sys.argv[1])
h["patch"]={"status":"queued","needs_classification_reason":""}
print(json.dumps(h))' "$heal_json")"
    else
      continue  # lint still fails (or file missing) — no heal this pass
    fi
  fi
  final_heals="$(python3 -c 'import json,sys
lst=json.loads(sys.argv[1]); lst.append(json.loads(sys.argv[2])); print(json.dumps(lst))' "$final_heals" "$heal_json")"
done < <(python3 -c 'import json,sys
for h in json.loads(sys.argv[1]):
    print(json.dumps(h))' "$resolved_heals_json")

alarms_json="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["alarms"]))' "$plan_json")"

heals_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$final_heals")"
alarms_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$alarms_json")"

# ---- --report: print and exit, no writes at all ---------------------------
if [ "$report_mode" = true ]; then
  if [ "$format" = json ]; then
    python3 -c 'import json,sys
print(json.dumps({"mode":"report","heals":json.loads(sys.argv[1]),"alarms":json.loads(sys.argv[2])}, indent=2))' \
      "$final_heals" "$alarms_json"
  else
    echo "manifest-invariants --report: $heals_count heal(s) would fire, $alarms_count alarm(s)"
    python3 -c 'import json,sys
for h in json.loads(sys.argv[1]):
    print("  HEAL  " + h["slug"] + ": " + h["note"])
for a in json.loads(sys.argv[2]):
    print("  ALARM " + a["slug"] + " [" + a["class"] + "]: " + a["message"])' \
      "$final_heals" "$alarms_json"
  fi
  exit 0
fi

# ---- apply heals via manifest-set.sh (own lock, atomic rename, write-ahead
# intent — same path every other caller uses) --------------------------------
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/manifest-invariants.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

applied=0
while IFS= read -r heal_json; do
  [ -n "$heal_json" ] || continue
  slug="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["slug"])' "$heal_json")"
  rule="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["rule"])' "$heal_json")"
  note="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["note"])' "$heal_json")"
  patch_file="$tmp_dir/$slug.$rule.patch.json"
  python3 -c 'import json,sys,datetime
h=json.loads(sys.argv[1])
patch=dict(h["patch"])
patch.setdefault("invariants_audit_log_append", {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "rule": h["rule"],
})
print(json.dumps(patch))' "$heal_json" > "$patch_file.raw"
  # manifest-set.sh merges keys; invariants_audit_log is an append-only list,
  # so read the current array (if any), append, and merge the real array in
  # as part of the same patch rather than a magic sentinel key.
  cur_log="$(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
prds=m.get("prds",{})
e = prds.get(sys.argv[2]) if isinstance(prds, dict) else next((p for p in prds if isinstance(p,dict) and p.get("slug")==sys.argv[2]), {})
print(json.dumps((e or {}).get("invariants_audit_log") or []))' "$MANIFEST" "$slug")"
  python3 -c 'import json,sys
raw=json.load(open(sys.argv[1]))
raw.pop("invariants_audit_log_append", None)
log=json.loads(sys.argv[2])
entry=json.loads(sys.argv[3])
log.append(entry)
raw["invariants_audit_log"]=log
json.dump(raw, sys.stdout)' "$patch_file.raw" "$cur_log" \
    "$(python3 -c 'import json,sys; h=json.loads(sys.argv[1]); print(json.dumps({"ts":__import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),"rule":h["rule"],"note":h["note"]}))' "$heal_json")" \
    > "$patch_file"
  rm -f "$patch_file.raw"

  if "$MANIFEST_SET" "$slug" "$patch_file"; then
    applied=$((applied + 1))
    printf '%s  %s  heal  %s  (rule=%s lane=%s)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$note" "$rule" "$(hostname)" >> "$JOURNAL"
  else
    log "manifest-set.sh failed for $slug (rule=$rule) — heal not applied"
  fi
done < <(python3 -c 'import json,sys
for h in json.loads(sys.argv[1]):
    print(json.dumps(h))' "$final_heals")

# ---- claims-stale alarm (needs a subprocess per building/in_progress entry
# with a PRD path — done here in bash since it shells out to lane-claim.sh)
if [ -x "$LANE_CLAIM" ]; then
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    slug="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["slug"])' "$row")"
    path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["path"] or "")' "$row")"
    [ -n "$path" ] && [ -f "$path" ] || continue
    claim_json="$("$LANE_CLAIM" status "$path" --json 2>/dev/null || echo '{"claimed":false}')"
    # NOTE: lane-claim.sh's own --json output emits `"stale":yes|no` as a
    # bare word, not a quoted string or JSON boolean — not valid JSON. Match
    # it with grep rather than json.loads (which would raise and, caught,
    # silently read as "not claimed"/"not stale" — the exact false-negative
    # this script hit in testing before this fix).
    if grep -q '"claimed":true' <<<"$claim_json"; then
      if grep -q '"stale":yes' <<<"$claim_json"; then
        alarms_json="$(python3 -c 'import json,sys
alarms=json.loads(sys.argv[1])
alarms.append({"slug": sys.argv[2], "class": "stale-claim",
               "message": sys.argv[2] + ": claim is stale (" + sys.argv[3] + ")"})
print(json.dumps(alarms))' "$alarms_json" "$slug" "$claim_json")"
        alarms_count=$((alarms_count + 1))
      fi
    fi
  done < <(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
prds=m.get("prds",{})
items = prds.items() if isinstance(prds, dict) else [(p.get("slug"),p) for p in prds if isinstance(p,dict)]
for slug, e in items:
    if e.get("status") in ("building","in_progress"):
        print(json.dumps({"slug": slug, "path": e.get("path")}))' "$MANIFEST")
fi

# ---- emit alarms: journal + docket (fail-open) ----------------------------
have_docket=0
command -v docket >/dev/null 2>&1 && have_docket=1

while IFS= read -r alarm_json; do
  [ -n "$alarm_json" ] || continue
  slug="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["slug"])' "$alarm_json")"
  cls="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["class"])' "$alarm_json")"
  message="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["message"])' "$alarm_json")"
  key="manifest-invariant-$cls"
  printf '%s  %s  alarm  %s  (class=%s lane=%s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$message" "$cls" "$(hostname)" >> "$JOURNAL"
  if [ "$have_docket" = 1 ]; then
    docket report --run "$DOCKET_RUN" --key "$key" --title "$message" --severity warn >/dev/null 2>&1 \
      || log "docket report failed for $key (fail-open, journal line already written)"
  fi
done < <(python3 -c 'import json,sys
for a in json.loads(sys.argv[1]):
    print(json.dumps(a))' "$alarms_json")

if [ "$format" = json ]; then
  python3 -c 'import json,sys
print(json.dumps({"status":"ok","healed":int(sys.argv[1]),"alarmed":int(sys.argv[2])}))' \
    "$applied" "$alarms_count"
else
  echo "manifest-invariants: healed=$applied alarmed=$alarms_count"
fi

exit 0
