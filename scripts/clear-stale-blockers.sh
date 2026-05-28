#!/bin/bash
# clear-stale-blockers.sh — detect and clear /build manifest blockers
# whose stated condition no longer holds in the PRD source of truth.
#
# Conservative: only auto-clears version-collision blockers of the form
#   "vX.Y.Z collision with <other-slug>"
# when at most ONE of the two PRDs still declares vX.Y.Z as a phasing
# target. Other blocker shapes are reported but not touched — a human
# resolves them.
#
# Acquires the same tick.lock /build's headless wrapper uses (with a
# 60-second wait), so this never races against an in-flight tick.
#
# Output (stdout): JSON summary of what was inspected and what was
# cleared. Exit 0 if anything cleared (or nothing to clear), 2 if no
# candidate blockers exist, 1 on error.

set -uo pipefail

MANIFEST="${MANIFEST:-$HOME/.claude/skills/build/state/manifest.json}"
LOCK="${LOCK:-$HOME/.claude/skills/build/state/tick.lock}"
PRD_DIR="${PRD_DIR:-$HOME/wintermute/autobuilder}"

if [ ! -f "$MANIFEST" ]; then
  echo '{"error":"manifest not found","path":"'"$MANIFEST"'"}'
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo '{"error":"python3 not on PATH"}'
  exit 1
fi

exec 9>"$LOCK"
if ! flock -w 60 9; then
  echo '{"error":"tick.lock held >60s — abort"}'
  exit 1
fi

MANIFEST="$MANIFEST" PRD_DIR="$PRD_DIR" python3 <<'PY'
import json, os, re, sys, tempfile, datetime

manifest_path = os.environ["MANIFEST"]
prd_dir = os.environ["PRD_DIR"]

with open(manifest_path) as f:
    m = json.load(f)

# Match a version-collision blocker:
#   "v0.5.0 collision with recall-outcome-feedback — see version_conflict_note_..."
collision_re = re.compile(r"^v(\d+\.\d+\.\d+)\s+collision\s+with\s+([\w-]+)\b")

# Phasing-header pattern in the PRD: e.g. "**6a (v0.5.0):**"
def phasing_claims(prd_text: str, version: str) -> int:
    pat = re.compile(r"\*\*\s*\d+[a-z]?\s*\(\s*v" + re.escape(version) + r"\s*\)")
    return len(pat.findall(prd_text))

def read_prd(slug: str) -> str | None:
    p = os.path.join(prd_dir, f"PRD-{slug}.md")
    if not os.path.isfile(p):
        return None
    with open(p) as f:
        return f.read()

inspected: list[dict] = []
cleared: list[dict] = []
surfaced: list[dict] = []

for slug, entry in m.get("prds", {}).items():
    blockers = entry.get("blockers") or []
    if not blockers:
        continue
    kept = []
    for b in blockers:
        rec = {"slug": slug, "blocker": b}
        mc = collision_re.match(b)
        if not mc:
            rec["verdict"] = "surfaced-non-version-collision"
            surfaced.append(rec)
            kept.append(b)
            inspected.append(rec)
            continue
        version, other = mc.group(1), mc.group(2)
        this_text = read_prd(slug)
        other_text = read_prd(other)
        rec.update({"version": version, "other": other,
                    "this_prd_present": this_text is not None,
                    "other_prd_present": other_text is not None})
        if this_text is None or other_text is None:
            rec["verdict"] = "surfaced-prd-missing"
            surfaced.append(rec)
            kept.append(b)
            inspected.append(rec)
            continue
        a = phasing_claims(this_text, version)
        c = phasing_claims(other_text, version)
        rec["this_claims"] = a
        rec["other_claims"] = c
        if a + c <= 1:
            rec["verdict"] = "cleared"
            cleared.append(rec)
            # drop this blocker from kept
        else:
            rec["verdict"] = "surfaced-still-colliding"
            surfaced.append(rec)
            kept.append(b)
        inspected.append(rec)
    if kept != blockers:
        entry["blockers"] = kept
        entry.setdefault("blockers_audit_log", []).append({
            "ts": datetime.datetime.now(datetime.timezone.utc)
                    .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "actor": "self-review.build_stale_blockers",
            "removed": [r["blocker"] for r in cleared if r["slug"] == slug],
        })

summary = {
    "manifest": manifest_path,
    "inspected_count": len(inspected),
    "cleared_count": len(cleared),
    "surfaced_count": len(surfaced),
    "cleared": cleared,
    "surfaced": surfaced,
}

if not inspected:
    print(json.dumps({"status": "no-blockers", **summary}))
    sys.exit(2)

if cleared:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(manifest_path),
                               prefix=".manifest.", suffix=".json.tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(m, f, indent=2)
    os.rename(tmp, manifest_path)

print(json.dumps({"status": "ok", **summary}))
sys.exit(0)
PY
