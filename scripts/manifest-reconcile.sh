#!/usr/bin/env bash
# manifest-reconcile.sh — make manifest.json agree with the files, every
# tick, before anything is selected. Per PRD-build-manifest-reconcile.
#
# The build contract says frontmatter (and directory placement) is the
# shared state; manifest.json is a LOCAL CACHE. On 2026-09-03 the cache
# disagreed with the files in every way that matters (a PRD `built` in
# its file and `queued` in the cache, a PRD `shipped` in the cache while
# still sitting in build-queue/, an extend PRD with no `output_repo_path`
# because that field is normally set at publish time and extend PRDs
# publish into a repo that already exists). Each mismatch cost a cycle
# or a human. This script makes reconciliation mechanical:
#
#   - frontmatter + directory ALWAYS win over the cached `status`;
#   - `output_repo_path` is backfilled from `build_into` for extend
#     targets (`rust-extend`, `kernel-extend` — same definition
#     archive-finalize.sh already uses) so archive-finalize.sh's
#     "output_repo_path missing" refusal stops firing on cache bugs;
#   - `build_target`/`build_into` are copied from frontmatter when the
#     manifest lacks them;
#   - `blockers` is cleared once the file's `Blocked:` line is gone;
#   - manifest entries with no file anywhere are marked `vanished` (with
#     a timestamp) and dropped after 7 days; files with no entry get one.
#
# Usage:
#   manifest-reconcile.sh [--dry-run] [--format table|json]
#
# --dry-run   Compute and print the disagreement table (or JSON); the
#             manifest file is NOT touched — byte-identical before/after.
# --format    table (default, human-readable) or json (machine-readable,
#             one object: {"reconciled": N, "changes": [...]}).
#
# Exit: 0 ok (even when disagreements were found and fixed) | 2 usage |
#       1 environment error (python3 missing, manifest unreadable and
#       PRD_DIR absent, etc.)
#
# GOTCHA (bit an operator on 2026-09-03): manifest-set.sh takes a PATCH
# FILE PATH as its second argument, never an inline JSON string. Every
# non-dry-run patch this script applies is written to a tempfile first,
# same as every other Phase-4/7 caller.
#
# GOTCHA #2: manifest-set.sh's read-modify-write only ever MERGES keys
# into an entry (`entry.update(patch)`) — it has no delete verb. Dropping
# a `vanished` entry after its 7-day grace period is therefore NOT done
# through manifest-set.sh; this script takes the same mkdir-based
# `state/manifest.lock.d` lock manifest-set.sh uses (see acquire_lock/
# release_lock below — deliberately mirrored, not sourced, since
# manifest-set.sh runs `main "$@"` unconditionally at the bottom and
# can't be sourced for just its helpers) and does the delete itself,
# tempfile + atomic rename, same as every other manifest writer here.
#
# This script never touches tick-local fields (`ticks_invested`,
# `last_action`, `verified_completed`) except to null `verified_completed`
# when a file moves back to build-queue/ from built-prds/ (a human
# un-archive) — see PRD requirement 5.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
MANIFEST_SET="${MANIFEST_SET:-$HERE/manifest-set.sh}"
LOCK_DIR="$STATE_DIR/manifest.lock.d"
LOCK_RETRY_INTERVAL="${MANIFEST_LOCK_RETRY:-0.2}"
LOCK_CEILING_SECS="${MANIFEST_LOCK_CEILING:-60}"
VANISHED_GRACE_DAYS="${VANISHED_GRACE_DAYS:-7}"

log() { printf 'manifest-reconcile: %s\n' "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

dry_run=false
format=table

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)      dry_run=true; shift ;;
    --format)       format="${2:-table}"; shift 2 ;;
    --format=*)     format="${1#--format=}"; shift ;;
    -h|--help)
      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$format" in
  table|json) ;;
  *) die "--format must be table or json (got '$format')" 2 ;;
esac

[ -d "$PRD_DIR" ] || die "PRD_DIR not found: $PRD_DIR"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- mirrors manifest-set.sh's lock, used ONLY for the vanished-drop --
acquire_lock() {
  local waited=0 ceiling_tenths=$(( LOCK_CEILING_SECS * 10 ))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    [ "$waited" -ge "$ceiling_tenths" ] && return 3
    sleep "$LOCK_RETRY_INTERVAL"
    waited=$(( waited + 2 ))
  done
  return 0
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }

# ---- Pass 1 (pure, no writes): discover files + manifest, compute the
# full set of {slug -> patch, changes[]} plus the drop-list. Emitted as
# one JSON object on stdout so bash never re-parses PRD text itself.
plan_json="$(PRD_DIR="$PRD_DIR" MANIFEST="$MANIFEST" \
             VANISHED_GRACE_DAYS="$VANISHED_GRACE_DAYS" python3 <<'PY'
import json, os, re, sys, glob, datetime

prd_dir = os.environ["PRD_DIR"]
manifest_path = os.environ["MANIFEST"]
grace_days = int(os.environ["VANISHED_GRACE_DAYS"])
now = datetime.datetime.now(datetime.timezone.utc)

def now_iso():
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")

RECOGNIZED = {
    "queued": "queued",
    "in_progress": "in_progress",
    "in-progress": "in_progress",
    "built": "built",
    "shipped": "shipped",
    "archived": "archived",
    "blocked": "blocked",
    "vanished": "vanished",
    "parked": "parked",
    "notebook": "notebook",
    "needs_classification": "needs_classification",
    "needs-classification": "needs_classification",
}

FENCE_RE = re.compile(r'^```')
STATUS_KEY_RE = re.compile(
    r'^(?:[-*+]\s+)?(?:\*\*)?Status:?(?:\*\*)?\s*:?\s*(.*)$', re.IGNORECASE)
BLOCKED_KEY_RE = re.compile(
    r'^(?:[-*+]\s+)?(?:\*\*)?Blocked:?(?:\*\*)?\s*:', re.IGNORECASE)
BUILD_TARGET_RE = re.compile(
    r'^(?:[-*+]\s+)?(?:\*\*)?build_target:?(?:\*\*)?\s*:\s*(.*)$', re.IGNORECASE)
BUILD_INTO_RE = re.compile(
    r'^(?:[-*+]\s+)?(?:\*\*)?build_into:?(?:\*\*)?\s*:\s*(.*)$', re.IGNORECASE)

def strip_val(v: str) -> str:
    v = v.strip()
    v = re.sub(r'\s+#.*$', '', v)
    v = re.sub(r'[*#]', '', v).strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    return v.strip()

def parse_file(path: str):
    status_raw = ""
    build_target = None
    build_into = None
    has_blocked = False
    in_fence = False
    try:
        with open(path, errors="replace") as f:
            for i, line in enumerate(f):
                if i >= 200:
                    break
                if FENCE_RE.match(line.strip()):
                    in_fence = not in_fence
                    continue
                if in_fence:
                    continue
                if not status_raw:
                    m = STATUS_KEY_RE.match(line)
                    if m and (line.strip().lower().startswith(('status', '- status', '* status', '**status'))):
                        status_raw = strip_val(m.group(1))
                if BLOCKED_KEY_RE.match(line):
                    has_blocked = True
                if build_target is None:
                    m = BUILD_TARGET_RE.match(line)
                    if m:
                        build_target = strip_val(m.group(1)) or None
                if build_into is None:
                    m = BUILD_INTO_RE.match(line)
                    if m:
                        build_into = strip_val(m.group(1)) or None
    except OSError:
        pass
    return status_raw, build_target, build_into, has_blocked

def normalize_status(raw: str):
    if not raw:
        return None
    tok = raw.strip().lower()
    tok = re.sub(r'[\s]+', '_', tok)
    return RECOGNIZED.get(tok)

def slug_for(path: str) -> str:
    base = os.path.basename(path)
    base = re.sub(r'\.md$', '', base)
    base = re.sub(r'^PRD-', '', base)
    return base

# ---- discover files ------------------------------------------------------
file_map = {}
locations = [
    ("queue", os.path.join(prd_dir, "build-queue", "PRD-*.md")),
    ("built", os.path.join(prd_dir, "built-prds", "PRD-*.md")),
    ("parked", os.path.join(prd_dir, "parked", "PRD-*.md")),
]
for loc, pattern in locations:
    for path in sorted(glob.glob(pattern)):
        if not os.path.isfile(path):
            continue
        slug = slug_for(path)
        status_raw, build_target, build_into, has_blocked = parse_file(path)
        file_map[slug] = {
            "path": path, "dir": loc, "status_raw": status_raw,
            "status_token": normalize_status(status_raw),
            "build_target": build_target, "build_into": build_into,
            "has_blocked": has_blocked,
        }

# ---- read manifest (read-only here; writes happen in bash via
# manifest-set.sh, or under the lock for drops) ----------------------------
try:
    with open(manifest_path) as f:
        m = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    m = {}
prds = m.get("prds", {})
if isinstance(prds, list):
    entries = {p.get("slug"): p for p in prds if isinstance(p, dict) and p.get("slug")}
else:
    entries = dict(prds) if isinstance(prds, dict) else {}

EXTEND_TARGETS = {"rust-extend", "kernel-extend"}

results = []   # [{slug, patch, changes:[{field,file_or_dir_value,manifest_value,resolution}]}]
drops = []     # slugs to hard-delete after grace period

for slug, f in file_map.items():
    entry = entries.get(slug, {})
    exists = slug in entries
    dir_status = "archived" if f["dir"] == "built" else ("parked" if f["dir"] == "parked" else f["status_token"])
    cur_status = entry.get("status")

    patch = {}
    changes = []

    if not exists:
        new_status = dir_status or "queued"
        patch["status"] = new_status
        patch["path"] = f["path"]
        if f["build_target"]:
            patch["build_target"] = f["build_target"]
        if f["build_into"]:
            patch["build_into"] = f["build_into"]
        if f["build_target"] in EXTEND_TARGETS and f["build_into"]:
            patch["output_repo_path"] = f["build_into"]
        changes.append({"field": "status", "file_or_dir_value": new_status,
                         "manifest_value": None, "resolution": "new entry created"})
    else:
        effective_target = dir_status
        if cur_status == "vanished" and effective_target is None:
            effective_target = "queued"
        if effective_target is not None and effective_target != cur_status:
            patch["status"] = effective_target
            changes.append({"field": "status", "file_or_dir_value": effective_target,
                             "manifest_value": cur_status, "resolution": "file/dir wins"})
            if cur_status == "archived" and f["dir"] == "queue" and entry.get("verified_completed") is not None:
                patch["verified_completed"] = None
                changes.append({"field": "verified_completed", "file_or_dir_value": None,
                                 "manifest_value": entry.get("verified_completed"),
                                 "resolution": "un-archived (moved back to build-queue/); cleared"})
            if "vanished_since" in entry:
                patch["vanished_since"] = None
                changes.append({"field": "vanished_since", "file_or_dir_value": None,
                                 "manifest_value": entry.get("vanished_since"),
                                 "resolution": "file reappeared"})

        if not entry.get("build_target") and f["build_target"]:
            patch["build_target"] = f["build_target"]
            changes.append({"field": "build_target", "file_or_dir_value": f["build_target"],
                             "manifest_value": entry.get("build_target"),
                             "resolution": "copied from frontmatter"})
        if not entry.get("build_into") and f["build_into"]:
            patch["build_into"] = f["build_into"]
            changes.append({"field": "build_into", "file_or_dir_value": f["build_into"],
                             "manifest_value": entry.get("build_into"),
                             "resolution": "copied from frontmatter"})

        eff_build_target = patch.get("build_target", entry.get("build_target"))
        eff_build_into = patch.get("build_into", entry.get("build_into"))
        if not entry.get("output_repo_path") and eff_build_target in EXTEND_TARGETS and eff_build_into:
            patch["output_repo_path"] = eff_build_into
            changes.append({"field": "output_repo_path", "file_or_dir_value": eff_build_into,
                             "manifest_value": entry.get("output_repo_path"),
                             "resolution": f"derived from build_into ({eff_build_target})"})

        if entry.get("blockers") and not f["has_blocked"]:
            patch["blockers"] = []
            changes.append({"field": "blockers", "file_or_dir_value": [],
                             "manifest_value": entry.get("blockers"),
                             "resolution": "Blocked: line gone from file"})

    if patch:
        results.append({"slug": slug, "patch": patch, "changes": changes})

# ---- orphans: manifest entries with no file anywhere ---------------------
for slug, entry in entries.items():
    if slug in file_map:
        continue
    cur_status = entry.get("status")
    if cur_status != "vanished":
        patch = {"status": "vanished", "vanished_since": now_iso()}
        results.append({"slug": slug, "patch": patch, "changes": [
            {"field": "status", "file_or_dir_value": "vanished",
             "manifest_value": cur_status, "resolution": "no file found in any directory"},
        ]})
    else:
        vs = entry.get("vanished_since")
        dropped = False
        if vs:
            try:
                vs_dt = datetime.datetime.strptime(vs, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
                if (now - vs_dt).days >= grace_days:
                    dropped = True
            except ValueError:
                pass
        if dropped:
            drops.append(slug)
            results.append({"slug": slug, "patch": None, "changes": [
                {"field": "status", "file_or_dir_value": "(dropped)",
                 "manifest_value": "vanished", "resolution": f"vanished >= {grace_days}d; entry removed"},
            ]})

print(json.dumps({"results": results, "drops": drops}, sort_keys=True))
PY
)" || die "planning pass failed"

# ---- Pass 2: apply (unless --dry-run) ------------------------------------
reconciled=0
tmp_changes="$(mktemp)"
trap 'rm -f "$tmp_changes"' EXIT
printf '%s' "$plan_json" | python3 -c '
import json, sys
plan = json.load(sys.stdin)
for r in plan["results"]:
    for c in r["changes"]:
        print(json.dumps({"slug": r["slug"], **c}))
' > "$tmp_changes"

if [ "$dry_run" = false ]; then
  # Apply per-slug patches through manifest-set.sh (merge patches only).
  while IFS= read -r line; do
    slug="$(printf '%s' "$line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["slug"])')"
    patch="$(printf '%s' "$line" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["patch"]))')"
    [ "$patch" = "null" ] && continue   # drop-only entries have no merge patch
    pf="$(mktemp)"
    printf '%s' "$patch" > "$pf"
    if ! "$MANIFEST_SET" "$slug" "$pf"; then
      log "patch failed for $slug (manifest-set.sh non-zero); intent left for replay"
    fi
    rm -f "$pf"
  done < <(printf '%s' "$plan_json" | python3 -c '
import json, sys
plan = json.load(sys.stdin)
for r in plan["results"]:
    if r["patch"] is not None:
        print(json.dumps({"slug": r["slug"], "patch": r["patch"]}))
')

  # Drops (vanished >= grace period): delete the entry entirely. Not
  # expressible through manifest-set.sh (merge-only) — take the same
  # lock and do the RMW here (see header GOTCHA #2).
  drop_slugs="$(printf '%s' "$plan_json" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin)["drops"]))')"
  if [ -n "$drop_slugs" ]; then
    if acquire_lock; then
      while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        tmp="$(mktemp "$STATE_DIR/.manifest.XXXXXX")"
        if MANIFEST="$MANIFEST" SLUG="$slug" python3 - >"$tmp" <<'PY'
import json, os
manifest_path = os.environ["MANIFEST"]
slug = os.environ["SLUG"]
try:
    with open(manifest_path) as f:
        m = json.load(f)
except FileNotFoundError:
    m = {}
prds = m.get("prds", {})
if isinstance(prds, list):
    prds = [p for p in prds if not (isinstance(p, dict) and p.get("slug") == slug)]
elif isinstance(prds, dict):
    prds.pop(slug, None)
m["prds"] = prds
json.dump(m, __import__("sys").stdout, indent=2, sort_keys=False)
PY
        then
          mv -f "$tmp" "$MANIFEST"
        else
          rm -f "$tmp"
          log "drop failed for $slug"
        fi
      done <<<"$drop_slugs"
      release_lock
    else
      log "lock ceiling exceeded; vanished-drop deferred to next run"
    fi
  fi
fi

reconciled="$(printf '%s' "$plan_json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["results"]))')"

# ---- report ---------------------------------------------------------------
if [ "$format" = json ]; then
  python3 -c '
import json, sys
plan = json.load(open(sys.argv[1]))
print(json.dumps({"reconciled": len(plan["results"]), "changes": plan["results"]}, indent=2))
' <(printf '%s' "$plan_json")
else
  if [ -s "$tmp_changes" ]; then
    printf '%-28s %-18s %-30s %-30s %s\n' "SLUG" "FIELD" "FILE/DIR VALUE" "MANIFEST VALUE" "RESOLUTION"
    while IFS= read -r line; do
      python3 -c '
import json, sys
c = json.loads(sys.argv[1])
def s(v):
    v = "null" if v is None else v
    v = json.dumps(v) if isinstance(v, (list, dict)) else str(v)
    return v[:30]
print("%-28s %-18s %-30s %-30s %s" % (c["slug"][:28], c["field"][:18], s(c["file_or_dir_value"]), s(c["manifest_value"]), c["resolution"]))
' "$line"
    done < "$tmp_changes"
  fi
  echo "reconciled: $reconciled"
fi

exit 0
