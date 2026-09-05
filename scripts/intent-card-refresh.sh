#!/usr/bin/env bash
# intent-card-refresh.sh — regenerate <repo>/agent/intent-card.json from the
# rust-extend PRD that just landed, so a ship never again leaves the
# reviewer-agent's scope check comparing a diff against a card that still
# describes an earlier PRD's scope (PRD-build-intent-card-refresh:
# `intent-card-diff-scope-mismatch` blocked mcphost twice in one night,
# 2026-09-05, because eight version bumps across six PRDs left the card
# frozen at the original protocol-compat scope).
#
# Usage:
#   intent-card-refresh.sh <repo> <prd-path> [--dry-run]
#   intent-card-refresh.sh --check <repo>
#
# Modes:
#   default    Regenerate <repo>/agent/intent-card.json from <prd-path>.
#              Regenerated fields: schema (kept as the v1 const), prd_source,
#              intent_slug, root_motivation (Problem statement's first
#              paragraph, falling back to TL;DR's first paragraph), and
#              acceptance_criteria (one entry per numbered `N. P0 — Given/
#              When/Then` line: id ACn, level MUST/SHOULD/MAY from P0/P1/P2,
#              description from the line, test from agent/test-map.json's
#              ac_test_map when AC<n> is mapped there, else the scaffold
#              convention tests/acceptance_ac<n>.rs).
#              Every other required schema field (user_persona,
#              unfakeable_metric, scope, non_goals, hard_constraints,
#              five_whys_trace, ambiguities_resolved, created_at) is NOT
#              PRD-sourceable — carried forward byte-for-byte from the
#              existing card when one exists, else filled with an honest
#              structural placeholder (never a fabricated metric). Every
#              such field is named in the top-level `carried_forward`
#              object with a boolean. Write is atomic (temp + rename);
#              agent/ is created if missing.
#              When agent/intent_card_amendment_request.json exists and
#              every one of its scope_additions entries is "covered" —
#              either it names no prd_source (a bare non-PRD note, e.g. a
#              comment-only fix that added no scope) or its prd_source
#              resolves to the same file as <prd-path> — the amendment file
#              is removed in this same pass (P1). If any entry names a
#              *different* prd_source, the amendment file is left in place
#              untouched — this run's card doesn't speak to that entry's
#              scope, so nothing has covered it yet.
#   --dry-run  Print the card that would be written (pretty JSON) to
#              stdout; touch no file, remove no amendment file.
#   --check    Exit 1 when <repo>/agent/intent-card.json's prd_source does
#              not name the newest PRD manifest-recorded `built` (or
#              `archived`, its terminal state) for <repo> — prints both
#              names. Exit 0 when they match, the card is silent about a
#              repo with no recorded built PRD, or the card is missing but
#              so is any built PRD (nothing to check against yet). For
#              scan-prds's --check use, per PRD-build-intent-card-refresh
#              requirement P2.
#
# Assumption (undocumented in the PRD, smallest reasonable reading): the
# PRD's `N. P0 —` / `P1 —` / `P2 —` levels map onto the intent-card schema's
# MUST/SHOULD/MAY enum (autobuilder.intent_card.v1 has no COULD) as
# P0->MUST, P1->SHOULD, P2->MAY.
#
# AC-line parsing mirrors prd-lint.sh's AC_NUM_RE / AC_LEVELED_RE / grouping
# — reused, not re-derived, per this PRD's Technical considerations. Keep
# the two in step if either changes.
#
# Locking: this script takes no lock of its own. It must run inside the
# same per-repo integration flock (<repo>/.git/autobuilder-integrate.lock)
# the rust-extend ship sequence already holds around bump-version/changelog/
# push, so concurrent ships on one repo never race the card write.
#
# Exit: 0 ok | 1 --check mismatch | 2 usage | 3 malformed PRD (no parseable
#       AC lines, or no Problem-statement/TL;DR paragraph to source
#       root_motivation from) | 4 repo or PRD path not found
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
MANIFEST="${MANIFEST:-$SKILL_DIR/state/manifest.json}"

usage() {
  echo "usage: intent-card-refresh.sh <repo> <prd-path> [--dry-run]" >&2
  echo "       intent-card-refresh.sh --check <repo>" >&2
}

command -v python3 >/dev/null 2>&1 || { echo "intent-card-refresh: python3 not found" >&2; exit 2; }

mode=refresh
dry_run=false
repo=""
prd=""

if [ "${1:-}" = "--check" ]; then
  mode=check
  repo="${2:-}"
  [ -n "$repo" ] || { usage; exit 2; }
  [ "$#" -le 2 ] || { echo "intent-card-refresh: too many arguments" >&2; usage; exit 2; }
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift ;;
      -*) echo "intent-card-refresh: unknown flag $1" >&2; usage; exit 2 ;;
      *)
        if [ -z "$repo" ]; then repo="$1"
        elif [ -z "$prd" ]; then prd="$1"
        else echo "intent-card-refresh: too many arguments" >&2; usage; exit 2
        fi
        shift ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$prd" ] || { usage; exit 2; }
fi

[ -d "$repo" ] || { echo "intent-card-refresh: repo not found: $repo" >&2; exit 4; }

if [ "$mode" = check ]; then
  python3 - "$repo" "$MANIFEST" <<'PY'
import json, os, sys

repo, manifest_path = sys.argv[1], sys.argv[2]
repo_abs = os.path.abspath(repo)

try:
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"intent-card-refresh --check: cannot read manifest {manifest_path}: {exc}", file=sys.stderr)
    sys.exit(2)

prds = manifest.get("prds", {})
candidates = []
for slug, v in prds.items():
    orp = v.get("output_repo_path")
    if not orp:
        continue
    if os.path.abspath(orp) != repo_abs:
        continue
    if v.get("status") not in ("built", "archived"):
        continue
    candidates.append((slug, v))

if not candidates:
    print(f"intent-card-refresh --check: no built PRD recorded for {repo}; nothing to check")
    sys.exit(0)

# Newest by last_action timestamp (ISO 8601 strings sort lexically), then
# revision as a tiebreak for entries sharing/missing a timestamp.
newest_slug, newest = max(
    candidates, key=lambda kv: (kv[1].get("last_action") or "", kv[1].get("revision") or 0)
)
newest_prd_path = newest.get("path", "")

card_path = os.path.join(repo, "agent", "intent-card.json")
if not os.path.isfile(card_path):
    print(f"intent-card-refresh --check: no card at {card_path}; newest built PRD is {newest_slug} ({newest_prd_path})")
    sys.exit(1)

try:
    with open(card_path, encoding="utf-8") as fh:
        card = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"intent-card-refresh --check: cannot read {card_path}: {exc}", file=sys.stderr)
    sys.exit(2)

card_prd_source = card.get("prd_source", "")
same = False
if card_prd_source and os.path.isabs(card_prd_source):
    same = os.path.abspath(card_prd_source) == os.path.abspath(newest_prd_path)
else:
    same = card_prd_source == newest_prd_path

if same:
    print(f"intent-card-refresh --check: OK — card prd_source matches newest built PRD ({newest_prd_path})")
    sys.exit(0)

print(f"intent-card-refresh --check: MISMATCH — card names {card_prd_source!r}, newest built PRD is {newest_slug} ({newest_prd_path})")
sys.exit(1)
PY
  exit $?
fi

[ -r "$prd" ] || { echo "intent-card-refresh: PRD not readable: $prd" >&2; exit 4; }

python3 - "$repo" "$prd" "$dry_run" <<'PY'
import json, os, re, sys

repo, prd_path, dry_run_str = sys.argv[1], sys.argv[2], sys.argv[3]
dry_run = dry_run_str == "true"
repo = os.path.abspath(repo)
prd_path = os.path.abspath(prd_path)

# --- regexes mirroring prd-lint.sh (kept in step per that script's header) ---
AC_HEADING_RE = re.compile(r"^##\s+Acceptance(?:\s+(criteria|tests))?\s*$", re.I)
AC_NUM_RE = re.compile(r"^(\d+)\.\s+(.*)$")
AC_LEVELED_RE = re.compile(r"^(\d+)\.\s+(P[0-2])\s*[—–-]\s*(.*)$")
PROBLEM_HEADING_RE = re.compile(r"^##\s+Problem\s+[Ss]tatement\b")
TLDR_HEADING_RE = re.compile(r"^##\s+TL;DR\s*$", re.I)
FILENAME_RE = re.compile(r"^PRD-([a-z0-9]+(?:-[a-z0-9]+)*)\.md$")

LEVEL_MAP = {"P0": "MUST", "P1": "SHOULD", "P2": "MAY"}


def die(code, msg):
    print(f"intent-card-refresh: {msg}", file=sys.stderr)
    sys.exit(code)


def strip_val(v):
    v = re.sub(r"\s+#.*$", "", v)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == '"':
        v = v[1:-1]
    return v


def parse_frontmatter(path):
    fields = {}
    in_fence = False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()[:80]
    except OSError:
        return fields
    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        k = re.sub(r"^[-*+]\s+", "", line)
        k = re.sub(r"^\s*\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
        m = re.match(r"^\s*([A-Za-z][A-Za-z _-]*)\s*:\s*(.*)$", k)
        if not m:
            continue
        key = m.group(1).strip().lower().replace(" ", "_")
        if key in fields:
            continue
        fields[key] = strip_val(m.group(2))
    return fields


def slug_of(path):
    name = os.path.basename(path)
    m = FILENAME_RE.match(name)
    if m:
        return m.group(1)
    # Edge case: filename doesn't match the PRD-<slug>.md convention either
    # — still derive something usable rather than refusing.
    return re.sub(r"^PRD-", "", name[:-3] if name.endswith(".md") else name)


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def first_paragraph_after(all_lines, heading_re):
    in_section = False
    para = []
    for line in all_lines:
        if not in_section:
            if heading_re.match(line.strip()):
                in_section = True
            continue
        s = line.strip()
        if not s:
            if para:
                break
            continue
        if s.startswith("##"):
            break
        para.append(s)
    return " ".join(para).strip()


def extract_root_motivation(all_lines):
    text = first_paragraph_after(all_lines, PROBLEM_HEADING_RE)
    if not text:
        text = first_paragraph_after(all_lines, TLDR_HEADING_RE)
    if not text:
        return None
    if len(text) > 1000:
        text = text[:997].rstrip() + "..."
    return text


def ac_section_lines(all_lines):
    out = []
    in_section = False
    for line in all_lines:
        if AC_HEADING_RE.match(line.strip()):
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if in_section:
            out.append(line)
    return out, in_section


def extract_acceptance_criteria(all_lines, test_map):
    section, found_heading = ac_section_lines(all_lines)
    if not found_heading:
        return None

    items = []
    cur = None
    for l in section:
        if AC_NUM_RE.match(l.strip()):
            if cur is not None:
                items.append(cur)
            cur = [l.strip()]
        elif cur is not None and l.strip():
            cur.append(l.strip())
        elif cur is not None and not l.strip():
            items.append(cur)
            cur = None
    if cur is not None:
        items.append(cur)

    acs = []
    for it in items:
        m = AC_LEVELED_RE.match(it[0])
        if not m:
            continue
        num, level_code, first_desc = m.group(1), m.group(2), m.group(3)
        desc_parts = [first_desc] + it[1:]
        desc = " ".join(p.strip() for p in desc_parts if p.strip()).strip()
        if len(desc) > 500:
            desc = desc[:497].rstrip() + "..."
        ac_id = f"AC{num}"
        test = test_map.get(ac_id) or f"tests/acceptance_ac{num}.rs"
        acs.append({
            "id": ac_id,
            "level": LEVEL_MAP.get(level_code, "SHOULD"),
            "description": desc,
            "test": test,
        })
    return acs


def load_json(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def load_test_map(repo):
    tm = load_json(os.path.join(repo, "agent", "test-map.json"))
    if not isinstance(tm, dict):
        return {}
    m = tm.get("ac_test_map")
    return m if isinstance(m, dict) else {}


def normalize_created_at(fm):
    drafted = fm.get("drafted", "")
    if re.match(r"^\d{4}-\d{2}-\d{2}$", drafted):
        return f"{drafted}T00:00:00Z"
    return "1970-01-01T00:00:00Z"


def default_five_whys(prd_path):
    return [{
        "why": 1,
        "q": "Card auto-generated by intent-card-refresh.sh — was a 5-Whys interview conducted for it?",
        "a": (
            "No. This card was mechanically regenerated from the landed PRD's "
            "frontmatter and body by scripts/intent-card-refresh.sh; no "
            "five-whys interview ran. See prd_source for the human-authored "
            f"PRD ({prd_path}) this ships from."
        ),
    }]


def default_unfakeable_metric():
    return {
        "name": "acceptance_tests_passing_count",
        "lower_is_better": False,
        "harness_command": "scripts/run-metrics.sh",
        "target": None,
    }


def default_hard_constraints():
    return {"rust_edition": "2024", "target_kind": "cli", "deny_unsafe": True}


all_lines = read_lines(prd_path)
fm = parse_frontmatter(prd_path)

slug = slug_of(prd_path)

root_motivation = extract_root_motivation(all_lines)
if not root_motivation:
    die(3, f"no Problem statement (or TL;DR) paragraph found in {prd_path} to source root_motivation from")

test_map = load_test_map(repo)
acceptance_criteria = extract_acceptance_criteria(all_lines, test_map)
if acceptance_criteria is None:
    die(3, f"no `## Acceptance` (criteria/tests) section found in {prd_path}")
if not acceptance_criteria:
    die(3, f"no parseable `N. P[0-2] — Given/When/Then` acceptance-criterion lines found in {prd_path}")

existing = load_json(os.path.join(repo, "agent", "intent-card.json"))

carried_forward = {}


def carry(field, default_factory):
    if existing is not None and field in existing:
        carried_forward[field] = True
        return existing[field]
    carried_forward[field] = False
    return default_factory()


user_persona = carry("user_persona", lambda: (
    "UNSPECIFIED — no existing intent card to carry forward from; set by "
    "hand (intent-card-refresh.sh cannot source this from a PRD)."
))
unfakeable_metric = carry("unfakeable_metric", default_unfakeable_metric)
scope = carry("scope", list)
non_goals = carry("non_goals", list)
hard_constraints = carry("hard_constraints", default_hard_constraints)
five_whys_trace = carry("five_whys_trace", lambda: default_five_whys(prd_path))
created_at = carry("created_at", lambda: normalize_created_at(fm))

new_card = {
    "schema": "autobuilder.intent_card.v1",
    "prd_source": prd_path,
    "intent_slug": slug,
    "root_motivation": root_motivation,
    "user_persona": user_persona,
    "unfakeable_metric": unfakeable_metric,
    "acceptance_criteria": acceptance_criteria,
    "scope": scope,
    "non_goals": non_goals,
    "hard_constraints": hard_constraints,
    "five_whys_trace": five_whys_trace,
    "created_at": created_at,
    "carried_forward": carried_forward,
}
if existing is not None and "ambiguities_resolved" in existing:
    new_card["ambiguities_resolved"] = existing["ambiguities_resolved"]
    carried_forward["ambiguities_resolved"] = True

card_text = json.dumps(new_card, indent=2, sort_keys=False) + "\n"

if dry_run:
    sys.stdout.write(card_text)
    sys.exit(0)

agent_dir = os.path.join(repo, "agent")
os.makedirs(agent_dir, exist_ok=True)
card_path = os.path.join(agent_dir, "intent-card.json")
tmp_path = card_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as fh:
    fh.write(card_text)
os.replace(tmp_path, card_path)

amendment_path = os.path.join(agent_dir, "intent_card_amendment_request.json")
amendment_removed = False
if os.path.isfile(amendment_path):
    amendment = load_json(amendment_path)
    scope_additions = (amendment or {}).get("scope_additions", [])
    covered = True
    for entry in scope_additions:
        entry_prd = entry.get("prd_source")
        if not entry_prd:
            continue  # bare non-PRD note (e.g. comment-only fix) — non-blocking
        if os.path.abspath(entry_prd) != prd_path:
            covered = False
            break
    if covered:
        os.remove(amendment_path)
        amendment_removed = True

print(json.dumps({
    "written": card_path,
    "intent_slug": slug,
    "ac_count": len(acceptance_criteria),
    "amendment_removed": amendment_removed,
}))
PY
exit $?
