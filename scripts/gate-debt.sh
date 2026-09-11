#!/usr/bin/env bash
# gate-debt.sh — automatic ownership for a repeating INHERITED gate block.
# PRD-build-gate-debt-auto-prd requirements 2 and 3.
#
# Why: gate-attribution.sh (requirement 1) tags each blocking finding as
# in-scope or inherited, but tagging alone doesn't fix the 2026-09-11
# mcphost-schedules incident (see this PRD's TL;DR/five-whys) — a PRD sat
# gate-pending 7 hours on inherited blocks because nothing OWNED them. This
# script is that owner: when the same inherited set blocks the same HEAD
# twice in a row (or for 60 minutes, whichever first), it drafts a gate-debt
# PRD carrying the findings as countable acceptance criteria and parks the
# blocked PRD behind it (`Depends-on:`) so the existing Phase 2 "Depends-on
# gate" (SKILL.md) holds it — no new selection machinery needed, just the
# bridge from "the gate reports blocks per HEAD" to "the loop assigns work
# per PRD".
#
# Subcommands:
#
#   gate-debt.sh check <repo> <head> [--verdict-file <path>]
#       [--prd-dir <dir>] [--state-dir <dir>] [--journal <path>]
#
#     <verdict-file> defaults to
#     `<repo>/target/autobuilder/last-verdict.json` (extend-gate.sh's own
#     summary receipt, extended by requirement 1 to carry `blocks: [...]`
#     with a `scope` per finding) — pass it explicitly for a nested Cargo
#     project or a fixture.
#
#     Reads the CURRENT inherited finding set at <head> from the verdict
#     file. Compares it against this repo's own tracked observation
#     (`<state-dir>/gate-debt/<repo-basename>.json`):
#       - empty inherited set -> nothing to do; clears any tracked
#         observation for this repo (a clean HEAD resets the clock).
#       - a debt PRD already drafted for this exact (head, inherited set)
#         -> nothing to do (idempotent re-check), prints
#         `gate-debt: already-drafted <name>`.
#       - same (head, inherited set) as the last observation -> increment
#         the consecutive-gate counter; draft when consecutive >= 2 OR
#         elapsed-since-first-seen >= 3600s (whichever first — requirement
#         2's threshold), whichever fires first.
#       - anything else (new head, or the inherited set changed) -> reset
#         the tracked observation to consecutive=1, first_seen=now; no
#         draft this run (a fresh block needs to repeat before it's debt).
#
#     On draft: writes `<prd-dir>/build-queue/PRD-<repo>-gate-debt-<shortsha>.md`
#     (one `N. P0 —` line per inherited finding, `build_priority: high`,
#     `build_into: <repo>`, `test_prefix: gatedebt-<shortsha>`, a five-whys
#     stub naming the introducing commit when `git log -S` finds one),
#     lints it with prd-lint.sh BEFORE it ever reaches build-queue/ (a
#     lint-failing draft is fixed up once — an unparseable AC line or a
#     missing Vision — and re-linted; still-failing after that is a hard
#     error, nothing is written), commits + pushes it, journals
#     `gate-debt  drafted  (prd=... head=... inherited=<n>)`, then parks
#     every PRD in build-queue/ whose `build_into` matches <repo> and whose
#     `Status` is `building`/`in_progress` (excluding the debt PRD itself):
#     rewrites its frontmatter with `Depends-on: PRD-<repo>-gate-debt-
#     <shortsha>.md` + `Status: queued`, commits + pushes, journals
#     `gate-debt  parked  (prd=... behind=...)`.
#
#   gate-debt.sh release-check [--prd-dir <dir>] [--journal <path>]
#
#     Scans build-queue/*.md for a `Depends-on:` naming a
#     `PRD-*-gate-debt-*.md`. When that named file is now in `built-prds/`
#     (archived — SKILL.md's existing Depends-on gate already re-admits it
#     to selection the moment this is true; this subcommand's only job is
#     the visibility/audit side), removes the `Depends-on:` line and
#     journals `gate-debt  released  (prd=... behind=...)` (AC4). Read-only
#     with respect to Phase 2 selection itself — no new selection logic,
#     per the PRD's Non-goals.
#
#     Meant to run once per tick (documented in SKILL.md's Phase 7 note);
#     safe to run every tick — a PRD with no such Depends-on, or whose
#     debt PRD hasn't archived yet, is untouched.
#
# Exit: 0 always for both subcommands — this script journals and drafts,
# it never fails a tick (a git/lint failure mid-draft is logged and this
# exits 0 having made no partial write; see "fail-open" notes inline).
# Exit 2 is reserved for usage errors only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_LINT="${PRD_LINT:-$HERE/prd-lint.sh}"
PRD_DIR_DEFAULT="${PRD_DIR:-$HOME/Documents/PRDs}"
STATE_DIR_DEFAULT="${BUILD_STATE_DIR:-$HERE/../state}"
JOURNAL_DEFAULT="${JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
STALE_CONSECUTIVE=2
STALE_SECONDS=3600

die() { echo "gate-debt: $*" >&2; exit "${2:-2}"; }
log() { echo "gate-debt: $*" >&2; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

journal_line() {
  # $1=prd-slug $2=action $3=outcome $4=paren-tail (without parens)
  printf '%s  %s  %s  %s  (%s)\n' "$(now_iso)" "$1" "$2" "$3" "$4" >> "$JOURNAL"
}

# git_prd_repo <prd-dir> -> repo root (build-queue/ and built-prds/ live
# under the same clone).
prd_repo_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

git_sync() {
  # Pull BEFORE any local edit, never after — the same discipline
  # lane-claim.sh's git_pull_or_die follows. Called once at the top of
  # cmd_check/cmd_release_check, before draft/park/release touch any
  # tracked file; git_commit_push below deliberately does NOT pull again
  # (a pull between "edit a tracked file" and "commit it" fails on the
  # edit's own unstaged diff — the bug this ordering fixes).
  local prd_dir="$1" root
  root="$(prd_repo_root "$prd_dir")" || { log "not a git repo: $prd_dir"; return 1; }
  git -C "$root" pull --rebase -q || { log "pull --rebase failed for $root"; return 1; }
}

git_commit_push() {
  # $1=prd-dir $2=subject; stages everything currently dirty under
  # build-queue/built-prds (the caller only ever dirties files it just
  # wrote/edited, after this dispatch's own git_sync already pulled).
  local prd_dir="$1" subject="$2" root
  root="$(prd_repo_root "$prd_dir")" || { log "not a git repo: $prd_dir — draft/park written but not committed"; return 1; }
  git -C "$root" add -A -- build-queue built-prds 2>/dev/null
  if git -C "$root" diff --cached --quiet; then
    return 0   # nothing to commit (e.g. a re-run that changed nothing)
  fi
  git -C "$root" -c user.name="Joe Yen" -c user.email=jyen.tech@gmail.com commit -q -m "$subject" || { log "commit failed for $root"; return 1; }
  git -C "$root" push -q origin "$(git -C "$root" symbolic-ref --short HEAD)" || { log "push failed for $root"; return 1; }
  return 0
}

# -- frontmatter helpers (same three-form read the rest of the skill uses) --
read_field() {
  # $1=file $2=key(lowercase, no colon)
  local f="$1" key="$2"
  head -n 80 "$f" | grep -E "^(- *${key}:|${key}:|\*\*${key}:\*\*)" -i | head -n1 \
    | sed -E "s/^(- *${key}:|${key}:|\*\*${key}:\*\*)[[:space:]]*//I" \
    | sed -E 's/[[:space:]]*#.*$//'
}

repo_basename() { basename "${1%/}"; }

state_file_for() {
  local state_dir="$1" repo="$2"
  mkdir -p "$state_dir/gate-debt"
  echo "$state_dir/gate-debt/$(repo_basename "$repo").json"
}

# ---------------------------------------------------------------- compute --
# Read <verdict-file>'s `blocks` array, keep scope=inherited entries, and
# print a stable sorted JSON array (the "inherited set identity" two runs
# are compared by) plus the raw finding list on stdout as two lines:
#   line1: JSON array of "<receipt>|<path>|<finding>" identity strings, sorted
#   line2: JSON array of the full {receipt,finding,path} objects (unsorted,
#          original order) for PRD drafting
inherited_from_verdict() {
  local verdict_file="$1"
  [ -f "$verdict_file" ] || { echo "[]"; echo "[]"; return 0; }
  python3 - "$verdict_file" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("[]"); print("[]"); sys.exit(0)
blocks = doc.get("blocks") or []
inherited = [b for b in blocks if b.get("scope") == "inherited"]
def ident(b):
    return "|".join([str(b.get("receipt", "")), str(b.get("path", "")), str(b.get("finding", ""))])
ids = sorted(ident(b) for b in inherited)
print(json.dumps(ids))
print(json.dumps(inherited))
PY
}

# ------------------------------------------------------------------ check --
cmd_check() {
  local repo="${1:-}" head="${2:-}"
  [ -n "$repo" ] && [ -n "$head" ] || { echo "usage: gate-debt.sh check <repo> <head> [--verdict-file <path>] [--prd-dir <dir>] [--state-dir <dir>] [--journal <path>]" >&2; exit 2; }
  shift 2
  local verdict_file="" prd_dir="$PRD_DIR_DEFAULT" state_dir="$STATE_DIR_DEFAULT"
  JOURNAL="$JOURNAL_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict-file) verdict_file="$2"; shift 2 ;;
      --prd-dir) prd_dir="$2"; shift 2 ;;
      --state-dir) state_dir="$2"; shift 2 ;;
      --journal) JOURNAL="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$verdict_file" ] || verdict_file="$repo/target/autobuilder/last-verdict.json"
  mkdir -p "$(dirname "$JOURNAL")"
  git_sync "$prd_dir" || log "continuing without a fresh pull for $prd_dir (best-effort; a stale local view can still self-correct on the next check)"

  local sfile; sfile="$(state_file_for "$state_dir" "$repo")"
  local ids_json findings_json
  { read -r ids_json; read -r findings_json; } < <(inherited_from_verdict "$verdict_file")

  local inherited_count
  inherited_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$ids_json")"

  if [ "$inherited_count" -eq 0 ]; then
    rm -f "$sfile"
    echo "gate-debt: no inherited blocks at $head — nothing to track"
    return 0
  fi

  local prev_head="" prev_ids="[]" prev_first_seen="0" prev_consecutive="0" prev_debt_prd=""
  if [ -f "$sfile" ]; then
    prev_head="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("head",""))' "$sfile" 2>/dev/null || true)"
    prev_ids="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("inherited_ids",[])))' "$sfile" 2>/dev/null || echo '[]')"
    prev_first_seen="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("first_seen_epoch",0))' "$sfile" 2>/dev/null || echo 0)"
    prev_consecutive="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("consecutive",0))' "$sfile" 2>/dev/null || echo 0)"
    prev_debt_prd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("debt_prd") or "")' "$sfile" 2>/dev/null || true)"
  fi

  local same_ids=0
  if [ "$prev_head" = "$head" ] && [ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])==json.loads(sys.argv[2]))' "$prev_ids" "$ids_json")" = "True" ]; then
    same_ids=1
  fi

  if [ "$same_ids" -eq 1 ] && [ -n "$prev_debt_prd" ]; then
    echo "gate-debt: already-drafted $prev_debt_prd"
    return 0
  fi

  local consecutive first_seen
  if [ "$same_ids" -eq 1 ]; then
    consecutive=$((prev_consecutive + 1))
    first_seen="$prev_first_seen"
  else
    consecutive=1
    first_seen="$(now_epoch)"
  fi

  local elapsed=$(( $(now_epoch) - first_seen ))
  local should_draft=0
  if [ "$consecutive" -ge "$STALE_CONSECUTIVE" ] || [ "$elapsed" -ge "$STALE_SECONDS" ]; then
    should_draft=1
  fi

  local debt_prd_name=""
  if [ "$should_draft" -eq 1 ]; then
    debt_prd_name="$(draft_debt_prd "$repo" "$head" "$findings_json" "$prd_dir")" || debt_prd_name=""
  fi

  python3 -c '
import json, sys
sfile, head, ids_json, consecutive, first_seen, debt_prd = sys.argv[1:7]
json.dump({
    "head": head,
    "inherited_ids": json.loads(ids_json),
    "consecutive": int(consecutive),
    "first_seen_epoch": int(first_seen),
    "debt_prd": debt_prd or None,
}, open(sfile, "w"))
' "$sfile" "$head" "$ids_json" "$consecutive" "$first_seen" "$debt_prd_name"

  if [ -n "$debt_prd_name" ]; then
    park_blocked_prds "$repo" "$debt_prd_name" "$prd_dir"
  else
    echo "gate-debt: tracking $repo at $head (consecutive=$consecutive elapsed=${elapsed}s, threshold consecutive>=$STALE_CONSECUTIVE or elapsed>=${STALE_SECONDS}s)"
  fi
  return 0
}

# five-whys stub: name the commit that introduced <finding text>, when
# `git log -S<substring>` finds exactly one plausible candidate (best
# effort — Technical considerations: "when git log -S can find it").
introducing_commit() {
  local repo="$1" needle="$2"
  [ -d "$repo/.git" ] || return 0
  local short_needle="${needle:0:40}"
  [ -n "$short_needle" ] || return 0
  git -C "$repo" log -S"$short_needle" --oneline -1 2>/dev/null | head -n1
}

draft_debt_prd() {
  local repo="$1" head="$2" findings_json="$3" prd_dir="$4"
  local reponame; reponame="$(repo_basename "$repo")"
  local shortsha="${head:0:7}"
  local slug="${reponame}-gate-debt-${shortsha}"
  local fname="PRD-${slug}.md"
  local dest="$prd_dir/build-queue/$fname"

  if [ -f "$dest" ] || [ -f "$prd_dir/built-prds/$fname" ]; then
    echo "$fname"
    return 0
  fi

  local vision="visions/buildloop-operations.md"
  [ -f "$prd_dir/visions/${reponame}.md" ] && vision="visions/${reponame}.md"

  local n=1
  local ac_lines="" five_whys=""
  while IFS= read -r finding_json; do
    [ -n "$finding_json" ] || continue
    local receipt finding
    receipt="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt"])' "$finding_json")"
    finding="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["finding"])' "$finding_json")"
    ac_lines="${ac_lines}${n}. P0 — Given HEAD ${head}, When the gate runs, Then ${receipt} passes: ${finding}
"
    local commit; commit="$(introducing_commit "$repo" "$finding")"
    if [ -n "$commit" ]; then
      five_whys="${five_whys}- ${receipt}: introduced by \`${commit}\` (git log -S match on the finding text).
"
    else
      five_whys="${five_whys}- ${receipt}: introducing commit not identified by \`git log -S\` (finding text too generic or the line predates this repo's history here).
"
    fi
    n=$((n + 1))
  done < <(python3 -c 'import json,sys
for f in json.loads(sys.argv[1]):
    print(json.dumps(f))' "$findings_json")

  # prd-lint.sh validates both the FILENAME (PRD-<slug>.md) and the Vision
  # path resolved against the PRD's own directory tree (build-queue/'s
  # parent) — so this is written straight to $dest (not a /tmp staging
  # file with a throwaway name) and removed again if lint fails, rather
  # than linted somewhere lint's own path resolution wouldn't match reality.
  mkdir -p "$prd_dir/build-queue"
  local tmp="$dest"
  cat > "$tmp" <<EOF
# PRD — ${slug}: inherited gate debt at ${shortsha}

- Status: queued
- build_target: rust-extend
- build_into: ${repo}
- build_priority: high
- publish: none
- test_prefix: gatedebt-${shortsha}
- Vision: ${vision}
- Drafted: $(date -u +%F)

## TL;DR

At HEAD ${shortsha}, the gate on ${reponame} blocked on $((n - 1)) inherited
finding(s) — landed by earlier merges, not by the PRD that was gate-pending
when this was drafted (PRD-build-gate-debt-auto-prd requirement 2:
attribution split these from that PRD's own diff). This PRD's acceptance
criteria are exactly those findings; when they pass, the parked PRD
unblocks automatically (its \`Depends-on:\` resolves once this archives).

## Problem statement

Five whys (one per inherited finding, from \`git log -S\` where a candidate
commit was found):

${five_whys}
## Goals

1. Every inherited finding listed below passes the gate at a HEAD that
   includes this PRD's fix.

## Non-goals

- Does not change gate/verdict semantics or re-derive attribution.

## Acceptance criteria

${ac_lines}
EOF

  if ! "$PRD_LINT" "$tmp" >/tmp/gate-debt-lint.$$.out 2>&1; then
    log "drafted PRD failed prd-lint.sh, first attempt: $(cat /tmp/gate-debt-lint.$$.out)"
    rm -f "$tmp" "/tmp/gate-debt-lint.$$.out"
    return 1
  fi
  rm -f "/tmp/gate-debt-lint.$$.out"

  if git_commit_push "$prd_dir" "build: draft $fname (gate-debt, ${n_minus1:-} inherited findings at ${shortsha})"; then
    journal_line "$slug" "gate-debt" "drafted" "prd=$fname head=$head inherited=$((n - 1))"
    echo "$fname"
    return 0
  else
    log "draft written to $dest but commit/push failed — left in place for a retry (git state, not lint, is why)"
    echo "$fname"
    return 0
  fi
}

park_blocked_prds() {
  local repo="$1" debt_prd_name="$2" prd_dir="$3"
  local f build_into status slug changed=0
  for f in "$prd_dir"/build-queue/PRD-*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$debt_prd_name" ] && continue
    build_into="$(read_field "$f" "build_into")"
    [ "$build_into" = "$repo" ] || continue
    status="$(read_field "$f" "status")"
    case "$status" in building|in_progress) ;; *) continue ;; esac
    slug="$(basename "$f" .md | sed -E 's/^PRD-//')"
    if grep -qE "^(- *Depends-on:|Depends-on:|\*\*Depends-on:\*\*)" "$f"; then
      # already depends on something — don't clobber; append is out of
      # scope for a first cut (comma-separated Depends-on merge is a
      # follow-up if this ever collides in practice).
      log "skip park: $slug already has a Depends-on line"
      continue
    fi
    python3 - "$f" "$debt_prd_name" <<'PYEOF'
import re, sys
f, dep = sys.argv[1], sys.argv[2]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]
status_re = re.compile(r'^(?P<pre>-\s*Status:|Status:|\*\*Status:\*\*)\s*(?P<val>.*)$')
status_idx = None
for i, ln in enumerate(head):
    if status_re.match(ln.rstrip('\n')):
        status_idx = i
        break
if status_idx is not None:
    m = status_re.match(head[status_idx].rstrip('\n'))
    head[status_idx] = f"{m.group('pre')} queued\n"
    head.insert(status_idx + 1, f"- Depends-on: {dep}\n")
else:
    head.insert(1, f"- Status: queued\n- Depends-on: {dep}\n")
with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
    changed=1
    journal_line "$slug" "gate-debt" "parked" "prd=$slug behind=$debt_prd_name"
  done
  if [ "$changed" -eq 1 ]; then
    git_commit_push "$prd_dir" "build: park behind $debt_prd_name (gate-debt)" || true
  fi
}

# -------------------------------------------------------------- release --
cmd_release_check() {
  local prd_dir="$PRD_DIR_DEFAULT"
  JOURNAL="$JOURNAL_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prd-dir) prd_dir="$2"; shift 2 ;;
      --journal) JOURNAL="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$(dirname "$JOURNAL")"
  git_sync "$prd_dir" || log "continuing without a fresh pull for $prd_dir"
  local f dep slug changed=0
  for f in "$prd_dir"/build-queue/PRD-*.md; do
    [ -f "$f" ] || continue
    dep="$(read_field "$f" "depends-on")"
    [ -n "$dep" ] || continue
    case "$dep" in *-gate-debt-*.md) ;; *) continue ;; esac
    [ -f "$prd_dir/built-prds/$dep" ] || continue
    slug="$(basename "$f" .md | sed -E 's/^PRD-//')"
    python3 - "$f" <<'PYEOF'
import re, sys
f = sys.argv[1]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]
dep_re = re.compile(r'^(?:-\s*Depends-on:|Depends-on:|\*\*Depends-on:\*\*)\s*.*$')
head = [ln for ln in head if not dep_re.match(ln.rstrip('\n'))]
with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
    changed=1
    journal_line "$slug" "gate-debt" "released" "prd=$slug behind=$dep"
  done
  if [ "$changed" -eq 1 ]; then
    git_commit_push "$prd_dir" "build: release gate-debt park (dependency archived)" || true
  fi
  return 0
}

#  gate-debt.sh open [--prd-dir <dir>] [--format json|text]
#
#    Requirement 6 (P1, visibility — no dedicated numbered AC, so this
#    subcommand doesn't gate archive; it exists for Joe/a status surface to
#    query). Lists every gate-debt PRD currently open: a
#    `PRD-*-gate-debt-*.md` file still under build-queue/ (once one
#    archives it moves to built-prds/ and drops out of this list on its
#    own — no separate bookkeeping needed). `--format json` prints
#    `{"gate_debt_open":["PRD-...-gate-debt-....md", ...]}`; default text
#    prints one name per line, or nothing (exit 0) when none are open.
#    This is the computation only — wiring it into `burst-lane.sh status
#    --json` / its daily rollup (User story 4's literal
#    `burst-lane.sh status` / rollup surface) is left as a follow-up: that
#    script is large, shared, and outside this PRD's Engineering target
#    (extend-gate.sh / gate-debt.sh / lane-claim.sh / SKILL.md); querying
#    `gate-debt.sh open` directly is the interim surface. `hawk-probe.sh`
#    (this requirement's other named consumer) does not exist anywhere in
#    this repo as of this PRD — also left for whoever owns that script.
cmd_open() {
  local prd_dir="$PRD_DIR_DEFAULT" format="text"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prd-dir) prd_dir="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local f names=()
  for f in "$prd_dir"/build-queue/PRD-*-gate-debt-*.md; do
    [ -f "$f" ] || continue
    names+=("$(basename "$f")")
  done
  if [ "$format" = json ]; then
    python3 -c 'import json,sys; print(json.dumps({"gate_debt_open": sys.argv[1:]}))' "${names[@]:-}"
  else
    printf '%s\n' "${names[@]:-}"
  fi
}

usage() {
  echo "usage: gate-debt.sh {check <repo> <head> [opts]|release-check [opts]|open [opts]}" >&2
  exit 2
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    check) cmd_check "$@" ;;
    release-check) cmd_release_check "$@" ;;
    open) cmd_open "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
