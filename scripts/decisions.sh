#!/usr/bin/env bash
# decisions.sh — operator decision escalation ledger
# (PRD-build-open-decision-escalation).
#
# Every decision only Joe can make (accept a baseline block list, raise or
# keep an SLA, allow a deviation) used to be written as "(Joe)" prose in
# handoff memories and vision footnotes: no date, no owner field a script
# can read, no reminder. This is the row a coordinator writes instead, and
# the ledger a nudge and a SessionStart banner both read.
#
# state/decisions.jsonl is APPEND-ONLY: `open` appends a `status:"open"`
# row; `close` appends a NEW row with the SAME id and `status:"closed"`
# rather than rewriting the file — safe under this skill's flock
# conventions (many writers, no in-place edit races). decisions-rows.py
# collapses the log to "latest row per id" for every read path below.
#
# Subcommands:
#   decisions.sh open "<question>" --owner <name> [--repo <repo>]
#                [--blocks <slug>,<slug>,...] [--due <ISO>]
#       Appends {id, question, owner, repo, blocks, opened_ts, due,
#       status:"open"}. id = first 8 hex of sha1(question) — so the SAME
#       question always resolves to the SAME id, and a duplicate `open`
#       call (any row, any status, already carrying that id) is a no-op:
#       prints the existing id, exit 0, no new row. due defaults to
#       opened_ts + 2 days.
#
#   decisions.sh list [--json] [--repo <repo>]
#       Prints open rows sorted by opened_ts, oldest first, each showing
#       age_h and OVERDUE when past due. --json is the machine form (the
#       decisions-rows.py output, unfiltered by status besides "open").
#       --repo filters to one repo's open rows (P2 requirement 8). In text
#       mode only, --repo also appends an `Evidence:` block naming any
#       superseded chain (PRD-build-prd-superseded-by requirement 8) whose
#       `build_into` is this repo -- `<pred-slug> -> <succ-file>
#       (transferred=<n>)` per chain, derived fresh from scan-prds.sh, so
#       a fix PRD seeded by repo-health-seed-prd.sh (which inlines this
#       command's own text output verbatim under its own `## Evidence`
#       heading) shows a superseded predecessor right next to the open
#       decisions blocking it, no second lookup. Omitted when no chain
#       matches the repo; --json is unchanged (decisions rows only) since
#       existing JSON consumers already treat it as decisions-only.
#
#   decisions.sh close <id> "<answer>"
#       Appends a closed row (status/closed_ts/answer), then for every
#       slug in that decision's `blocks`, appends
#       `decision <id> closed: <answer>` to the slug's manifest `iter_log`
#       array via manifest-set.sh, and journals
#       `<ts>  <slug>  decision  closed  (id=<id> owner=<owner>)` once per
#       slug. Idempotent: closing an already-closed id is a silent no-op
#       (exit 0, nothing appended twice).
#
#   decisions.sh nudge
#       For each open row not yet nudged today (state UTC day), delivers
#       one alert via alert-deliver.sh and journals it. Idempotency
#       marker: state/alerts/<day>/decision.<id> — see the implementation
#       note in cmd_nudge for why the rule/repo arguments passed to
#       alert-deliver.sh are `<id> decision`, not `decision-open
#       <repo|fleet>` as the PRD's prose literally shows: alert-deliver's
#       own idempotency key is (rule,repo), so passing a shared repo value
#       across two DIFFERENT decisions on the same day would let the
#       second decision's alert be silently swallowed by the first's
#       marker. Keying on `<id> decision` makes alert-deliver.sh's own
#       marker path exactly `state/alerts/<day>/decision.<id>` — the path
#       the PRD names explicitly and requirement 4's AC (two open rows,
#       three nudge calls in a day -> exactly two delivered lines)
#       actually tests — and makes it inherently per-id, so two decisions
#       sharing a repo never collide. The `<repo|fleet>` / "decision-open"
#       framing the PRD prose describes lives in the evidence text instead
#       (see cmd_nudge below), which is what ends up in the banner line
#       and in NOTIFY_CMD's stdin either way.
#
#   decisions.sh import-vision <visions/file.md>
#       One-time (idempotent) backfill: extracts Joe-owned rows from the
#       file's Open-questions tables (see decisions-vision-extract.py for
#       the exact shape parsed) and opens each via the same dedup path as
#       `open` — a second run opens zero new rows.
#
# Exit: 0 ok | 2 usage/argument error | 4 io/manifest error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
DECISIONS_FILE="${DECISIONS_FILE:-$STATE_DIR/decisions.jsonl}"
ROWS_PY="${DECISIONS_ROWS_PY:-$HERE/decisions-rows.py}"
MANIFEST_SET="${MANIFEST_SET:-$HERE/manifest-set.sh}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
ALERT_DELIVER="${ALERT_DELIVER:-$HERE/alert-deliver.sh}"
VISION_EXTRACT="${VISION_EXTRACT:-$HERE/decisions-vision-extract.py}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/alert-marker.sh
source "$HERE/lib/alert-marker.sh"

die() { echo "decisions: $*" >&2; exit "${2:-2}"; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

id_of() { printf '%s' "$1" | sha1sum | cut -c1-8; }

# row_exists <id> -> exit 0 iff any row (any status) with this id is
# already in the ledger.
row_exists() {
  [ -f "$DECISIONS_FILE" ] || return 1
  python3 -c '
import json, sys
target = sys.argv[2]
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == target:
                sys.exit(0)
except FileNotFoundError:
    pass
sys.exit(1)
' "$DECISIONS_FILE" "$1"
}

append_row() {  # $1 = one JSON object, already serialized
  mkdir -p "$(dirname "$DECISIONS_FILE")"
  printf '%s\n' "$1" >> "$DECISIONS_FILE"
}

rows_json() {  # forwards to decisions-rows.py; args are passed through
  python3 "$ROWS_PY" "$DECISIONS_FILE" "$@"
}

default_due() {
  date -u -d "@$(( $(date -u +%s) + 172800 ))" +%Y-%m-%dT%H:%M:%SZ
}

# open_one <question> <owner> <repo> <blocks-csv> <due> — does the actual
# work of `open`, without exiting the process: prints the id on stdout and
# returns 0/4, so import-vision (below) can call it in a loop. cmd_open is
# the CLI-facing wrapper that parses flags and exits.
open_one() {
  local question="$1" owner="$2" repo="$3" blocks="$4" due="$5"
  local id; id="$(id_of "$question")"
  if row_exists "$id"; then
    printf '%s\n' "$id"
    return 0
  fi

  local opened; opened="$(ts)"
  [ -n "$due" ] || due="$(default_due)"

  local json
  json="$(python3 -c '
import json, sys
question, owner, repo, blocks_csv, opened, due, rid = sys.argv[1:8]
blocks = [b for b in blocks_csv.split(",") if b] if blocks_csv else []
row = {
    "id": rid,
    "question": question,
    "owner": owner,
    "repo": repo or None,
    "blocks": blocks,
    "opened_ts": opened,
    "due": due,
    "status": "open",
}
json.dump(row, sys.stdout, sort_keys=True)
' "$question" "$owner" "$repo" "$blocks" "$opened" "$due" "$id")" || return 4

  append_row "$json"
  printf '%s\n' "$id"
  return 0
}

cmd_open() {
  local question="${1:-}"
  [ -n "$question" ] || die "usage: decisions.sh open \"<question>\" --owner <name> [--repo <repo>] [--blocks <slug>,...] [--due <ISO>]" 2
  shift
  local owner="" repo="" blocks="" due=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:?--owner needs a value}"; shift 2 ;;
      --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
      --blocks) blocks="${2:?--blocks needs a value}"; shift 2 ;;
      --due) due="${2:?--due needs a value}"; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$owner" ] || die "open requires --owner <name>" 2

  open_one "$question" "$owner" "$repo" "$blocks" "$due" || die "failed to build row json" 4
  exit 0
}

cmd_list() {
  local as_json=0 repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done

  local -a extra=(--status open)
  [ -n "$repo" ] && extra+=(--repo "$repo")
  local rows; rows="$(rows_json "${extra[@]}")" || die "failed to read decisions ledger" 4

  if [ "$as_json" = "1" ]; then
    printf '%s\n' "$rows"
    return 0
  fi

  python3 -c '
import json, sys
rows = json.loads(sys.argv[1])
for r in rows:
    flag = " OVERDUE" if r.get("overdue") else ""
    blocks = r.get("blocks") or []
    repo = r.get("repo") or "-"
    rid = r.get("id")
    age_h = r.get("age_h")
    owner = r.get("owner")
    question = r.get("question")
    print(f"{rid}  age_h={age_h}{flag}  owner={owner} repo={repo} blocks={len(blocks)}  {question}")
' "$rows"

  # PRD-build-prd-superseded-by requirement 8: fold this repo's superseded
  # chains into the same text output repo-health-seed-prd.sh inlines
  # verbatim under a fix PRD's `## Evidence` heading (see cmd_list's own
  # header comment above). Text mode + --repo only; no chain found is a
  # silent no-op (no empty `Evidence:` header on an unrelated repo).
  #
  # Deliberately NOT scan-prds.sh: that pipeline runs prd-lint.sh over
  # every build-queue/ PRD first (measured ~74s against this host's real
  # corpus) and this call sits on repo-health-seed-prd.sh's hot path --
  # every fix-PRD seed already shells out to `list --repo` once. A direct
  # first-80-lines grep of build_into/Superseded-by/transferred_acs stays
  # well under the PRD's own "under 1s" non-functional budget.
  if [ -n "$repo" ]; then
    local chains
    chains="$(python3 - "$PRD_DIR" "$repo" <<'PY'
import glob, os, re, sys
prd_dir, repo = sys.argv[1], sys.argv[2]
build_into_re = re.compile(r'^-\s*build_into:\s*(\S+)')
superseded_re = re.compile(r'^-\s*Superseded-by:\s*(\S+)')
transferred_re = re.compile(r'^-\s*transferred_acs:\s*\[([^\]]*)\]')
for d in ("build-queue", "built-prds"):
    for path in sorted(glob.glob(os.path.join(prd_dir, d, "PRD-*.md"))):
        build_into = succ = None
        n = 0
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                head = [next(fh, "") for _ in range(80)]
        except OSError:
            continue
        for ln in head:
            m = build_into_re.match(ln)
            if m:
                build_into = m.group(1)
            m = superseded_re.match(ln)
            if m:
                succ = m.group(1)
            m = transferred_re.match(ln)
            if m:
                n = len([x for x in m.group(1).split(",") if x.strip()])
        if not build_into or not succ:
            continue
        if build_into.rstrip("/").rsplit("/", 1)[-1] != repo:
            continue
        slug = os.path.basename(path)[len("PRD-"):-len(".md")]
        print(f"{slug} -> {succ} (transferred={n})")
PY
)"
    if [ -n "$chains" ]; then
      printf '\nEvidence:\n'
      printf '%s\n' "$chains" | sed 's/^/  /'
    fi
  fi
}

cmd_close() {
  local id="${1:-}" answer="${2:-}"
  [ -n "$id" ] && [ -n "$answer" ] || die "usage: decisions.sh close <id> \"<answer>\"" 2

  local latest
  latest="$(rows_json | python3 -c '
import json, sys
rid = sys.argv[1]
rows = json.loads(sys.stdin.read())
for r in rows:
    if r.get("id") == rid:
        json.dump(r, sys.stdout)
        sys.exit(0)
sys.exit(1)
' "$id")" || die "no such decision: $id" 2

  local status; status="$(printf '%s' "$latest" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  if [ "$status" = "closed" ]; then
    echo "decisions: $id already closed" >&2
    exit 0
  fi

  local now; now="$(ts)"
  local closed_row
  closed_row="$(python3 -c '
import json, sys
row = json.loads(sys.argv[1])
row["status"] = "closed"
row["closed_ts"] = sys.argv[2]
row["answer"] = sys.argv[3]
json.dump(row, sys.stdout, sort_keys=True)
' "$latest" "$now" "$answer")" || die "failed to build closed row json" 4

  append_row "$closed_row"

  local owner blocks_csv
  owner="$(printf '%s' "$latest" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("owner",""))')"
  blocks_csv="$(printf '%s' "$latest" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("blocks") or []))')"

  local slug
  IFS=',' read -ra _blocks <<< "$blocks_csv"
  for slug in "${_blocks[@]}"; do
    [ -n "$slug" ] || continue
    close_one_slug "$slug" "$id" "$answer" "$owner" "$now"
  done

  exit 0
}

# close_one_slug <slug> <id> <answer> <owner> <ts> — appends the decision
# line to <slug>'s manifest iter_log array (read-current, append,
# manifest-set.sh writes it back under its own lock) and journals it.
close_one_slug() {
  local slug="$1" id="$2" answer="$3" owner="$4" now="$5"
  local patch_file; patch_file="$(mktemp "${TMPDIR:-/tmp}/decisions-close-XXXXXX.json")"
  python3 -c '
import json, sys
manifest_path, slug, id_, answer = sys.argv[1:5]
try:
    with open(manifest_path) as f:
        m = json.load(f)
except FileNotFoundError:
    m = {}
prds = m.get("prds", {})
entry = {}
if isinstance(prds, list):
    entry = next((p for p in prds if isinstance(p, dict) and p.get("slug") == slug), {}) or {}
elif isinstance(prds, dict):
    entry = prds.get(slug) or {}
iter_log = list(entry.get("iter_log") or [])
iter_log.append(f"decision {id_} closed: {answer}")
json.dump({"iter_log": iter_log}, sys.stdout)
' "$MANIFEST" "$slug" "$id" "$answer" > "$patch_file"

  if [ -x "$MANIFEST_SET" ]; then
    "$MANIFEST_SET" "$slug" "$patch_file" >&2 || echo "decisions: manifest-set.sh failed for $slug" >&2
  fi
  rm -f "$patch_file"

  journal_line "$now  $slug  decision  closed  (id=$id owner=$owner)"
}

# cmd_nudge — one alert per open, not-yet-nudged-today row. See the header
# note above for why the alert-deliver.sh call shape here is
# `<id> decision <evidence>` rather than the PRD prose's literal
# `decision-open <repo|fleet> <evidence>`.
cmd_nudge() {
  local rows; rows="$(rows_json --status open)" || die "failed to read decisions ledger" 4
  local count; count="$(printf '%s' "$rows" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  [ "$count" -gt 0 ] || exit 0

  local i
  for i in $(seq 0 $((count - 1))); do
    local row id age_h owner repo question blocks_n
    row="$(printf '%s' "$rows" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())[int(sys.argv[1])]))' "$i")"
    id="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

    if alert_marker_exists "$id" "decision"; then
      continue
    fi

    age_h="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("age_h"))')"
    owner="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("owner"))')"
    repo="$(printf '%s' "$row" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("repo"); print(r or "fleet")')"
    question="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["question"])')"
    blocks_n="$(printf '%s' "$row" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("blocks") or []))')"

    local overdue_word=""
    if [ "$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("overdue"))')" = "True" ]; then
      overdue_word=" OVERDUE"
    fi

    local evidence_file; evidence_file="$(mktemp "${TMPDIR:-/tmp}/decisions-nudge-XXXXXX.txt")"
    printf '%sh OPEN decision %s: %s (owner=%s blocks=%s)%s\n' "$age_h" "$id" "$question" "$owner" "$blocks_n" "$overdue_word" > "$evidence_file"
    printf 'repo=%s\n' "$repo" >> "$evidence_file"

    [ -x "$ALERT_DELIVER" ] && "$ALERT_DELIVER" "$id" decision "$evidence_file" >&2
    rm -f "$evidence_file"
  done
  exit 0
}

# cmd_import_vision <visions/file.md> — one-time (idempotent) backfill of
# the Joe-owned open questions a vision file already carries (requirement
# 7). Delegates the actual extraction to decisions-vision-extract.py (see
# that script's header for the table-vs-prose scope decision) and calls
# open_one in-process for each candidate — dedup is inherited for free
# from open_one's own row_exists check, so a second run of this same
# command opens zero new rows (AC6).
cmd_import_vision() {
  local file="${1:-}"
  [ -n "$file" ] && [ -r "$file" ] || die "usage: decisions.sh import-vision <visions/file.md>" 2

  local opened=0 seen=0
  while IFS=$'\t' read -r question due; do
    [ -n "$question" ] || continue
    seen=$((seen + 1))
    local before after
    before="$(row_exists "$(id_of "$question")" && echo 1 || echo 0)"
    open_one "$question" joe "" "" "" >/dev/null || die "failed to open row for: $question" 4
    after="$(row_exists "$(id_of "$question")" && echo 1 || echo 0)"
    [ "$before" = "0" ] && [ "$after" = "1" ] && opened=$((opened + 1))
  done < <(python3 "$VISION_EXTRACT" "$file")

  echo "decisions: import-vision: $seen candidate(s) seen, $opened new row(s) opened from $file" >&2
  exit 0
}

usage() {
  echo "usage: decisions.sh {open|list|close|nudge|import-vision} ..." >&2
  exit 2
}

main() {
  local sub="${1:-}"
  [ -n "$sub" ] || usage
  shift
  case "$sub" in
    open)  cmd_open "$@" ;;
    list)  cmd_list "$@" ;;
    close) cmd_close "$@" ;;
    nudge) cmd_nudge "$@" ;;
    import-vision) cmd_import_vision "$@" ;;
    *) usage ;;
  esac
}

main "$@"
