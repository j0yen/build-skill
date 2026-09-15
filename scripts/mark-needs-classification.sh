#!/usr/bin/env bash
# mark-needs-classification.sh <prd-path> <reason-text> — the durable
# needs_classification transition, mirroring lane-claim.sh's `claim` /
# archive-commit.sh for their own transitions.
# Per PRD-build-needs-classification-commit-durability.
#
# Before this script, a branch agent that reached a classification stop
# (e.g. build_target mismatches build_into) hand-edited `Status:` to
# `needs_classification` and appended an `iter_log:` line in the working
# tree, updated the LOCAL manifest cache via manifest-set.sh, and returned
# — with nothing in the Phase 3 contract requiring the edit to actually be
# committed+pushed. manifest-set.sh's write-ahead durability only covers
# the per-host manifest cache; the PRD file in the shared `j0yen/PRDs`
# clone is what every lane's Phase 1 reconcile ("file/dir wins") trusts
# over it. When the commit was skipped, the file on `origin/main` kept
# showing its stale `Status: queued`/`building`, so the next tick's
# reconcile stomped the manifest cache back to buildable and re-dispatched
# the SAME already-diagnosed PRD — observed 3x in one day on
# PRD-homeward-ingest-backfill.md before this script existed. This script
# makes the whole transition (edit + commit + push) one atomic, mandatory
# call, the same way lane-claim.sh's `claim` already does for
# `Status: building` and archive-commit.sh already does for `Status: built`.
#
# What it does:
#   1. Resolves <prd-path> (a full path, or a bare slug looked up under
#      $PRD_DIR/build-queue/) and confirms it lives under a build-queue/
#      directory in a git repo.
#   2. Idempotent no-op (no write, no commit) if `Status:` is already
#      `needs_classification` AND the PRD's most recent `iter_log:` line
#      already carries this exact <reason-text> — re-checking a
#      still-blocked PRD and finding nothing changed must never pile up
#      duplicate commits.
#   3. Otherwise: sets `Status: needs_classification`, removes any
#      `Lane:` line (releases the claim so a stale lock never lingers past
#      a classification stop), and appends one
#      `- iter_log: <ISO-ts> needs_classification: <reason-text>` line —
#      the same hand-edit fallback shape `vellum amend --append-iter-log`
#      produces when vellum isn't on $PATH.
#   4. Commits with the Joe Yen identity, subject
#      `"<slug>: needs_classification — <first 60 chars of reason-text>"`.
#   5. `git pull --rebase --autostash` before the edit (tolerates a
#      sibling's transient uncommitted dirt elsewhere in the shared clone,
#      same as lane-claim.sh's hardened pull); after the commit, a plain
#      `git push`, and on rejection a `git fetch` + `git rebase` +
#      exactly one retried push. A push that still fails after that retry
#      is surfaced as a failure (exit 3) — the commit is left local rather
#      than silently reporting success with the transition undelivered.
#   6. On success, prints `needs-classification-committed: <slug> <sha>`.
#
# Claim-reproduction gate (PRD-build-classification-durable-heal req 1):
# before writing, this script runs prd-lint.sh against the PRD. If
# <reason-text> names one of prd-lint.sh's own FAIL ids as an exact token
# (e.g. "depends-on-missing", "build-target-unknown", "vision-missing",
# "build-into-substrate-mismatch") and prd-lint.sh does NOT fail with that
# id on this file right now, the claim is unreproduced: the script refuses
# (exit 3), journals the refusal, and writes nothing. A reason-text that
# names no lint id at all (an agent's own judgment call, not tied to a
# lint check) is committed exactly as before, except the iter_log line
# gains a trailing ` lint_rc=<rc>` so a later audit can see whether
# prd-lint.sh was clean or failing at the time. `--force` (meant for an
# operator, not a branch agent) bypasses a refusal, journaling the bypass
# instead of silently overriding it. This closes the trap the 2026-09-13
# mcphost-agent-consent incident (see the file header above) exposed: a
# wrong claim used to become just as durable as a right one.
#
# Usage:
#   mark-needs-classification.sh <prd-path-or-slug> <reason-text> [--dry-run] [--force]
#
# Env:
#   PRD_DIR   Shared PRDs checkout root, used only to resolve a bare slug
#             argument (default: ~/Documents/PRDs). Ignored when
#             <prd-path> is already an existing file path.
#   PRD_LINT  Path to prd-lint.sh (default: alongside this script).
#   JOURNAL   Journal file appended to for refusals/bypasses (default:
#             ~/brain/journal/build/<UTC-date>.md).
#
# Options:
#   --dry-run   Print the Status/iter_log line that would be written (or
#               report the idempotent no-op) and exit 0; mutates nothing,
#               takes no lock, does not pull. Does not run the lint gate.
#   --force     Operator override: bypass a claim-not-reproduced refusal
#               and commit anyway. Always journaled.
#
# Exit codes:
#   0   committed+pushed, or idempotent no-op (already needs_classification
#       with this exact reason-text)
#   2   usage error
#   3   not-found (<prd-path> doesn't resolve to a file under a
#       build-queue/ directory in a git repo), refused (reason names a
#       lint id prd-lint.sh does not currently FAIL on, and --force was
#       not given), or push-failed (commit landed locally;
#       rebase+retry-once still couldn't push)
#   4   local git error: pull hit a real rebase conflict, or the header
#       write/`git add`/`git commit` step failed — working tree state is
#       whatever git left it in for that failure (see stderr)
#
# Stdout on success:
#   needs-classification-committed: <slug> <sha>
# Stdout on idempotent no-op:
#   needs-classification-noop: <slug> (unchanged)
# Stdout on refusal:
#   needs-classification-refused: <slug> (cause=claim-not-reproduced lint_id=<id> lint_rc=<rc>)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
PRD_LINT="${PRD_LINT:-$HERE/prd-lint.sh}"
JOURNAL="${JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"

die() { printf '%s\n' "mark-needs-classification: $*" >&2; exit "${2:-4}"; }

journal_line() {
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true
  printf '%s\n' "$1" >> "$JOURNAL"
}

# ---- args ---------------------------------------------------------------
dry_run=false
force=false
prd_arg=""
reason=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --force) force=true; shift ;;
    -h|--help) sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    --) shift; break ;;
    -*) die "unknown flag $1" 2 ;;
    *)
      if [ -z "$prd_arg" ]; then prd_arg="$1"
      elif [ -z "$reason" ]; then reason="$1"
      else die "unexpected arg $1" 2
      fi
      shift ;;
  esac
done

[ -n "$prd_arg" ] && [ -n "$reason" ] \
  || die "usage: mark-needs-classification.sh <prd-path-or-slug> <reason-text> [--dry-run]" 2

# Frontmatter values are one line each — collapse any embedded newlines so
# a multi-line reason string can't split into a stray second field.
reason="${reason//$'\n'/ }"

# ---- resolve the PRD path -------------------------------------------------
resolve_prd_path() {
  local input="$1"
  if [ -f "$input" ]; then
    printf '%s\n' "$(cd "$(dirname "$input")" && pwd -P)/$(basename "$input")"
    return 0
  fi
  local slug="$input"
  slug="${slug#PRD-}"
  slug="${slug%.md}"
  local candidate="$PRD_DIR/build-queue/PRD-$slug.md"
  [ -f "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# PRD-build-prd-slug-uniqueness AC8: when a bare slug (or a queue path that
# no longer exists, e.g. after an archive) doesn't resolve under
# build-queue/, look in built-prds/ and parked/ too -- not to operate on it
# there (this script only ever writes to a build-queue/ PRD, by contract),
# but so the failure names where the PRD actually lives instead of a bare
# "not found", which used to send a human hunting by hand for a PRD that
# had simply shipped or been parked since this slug was last looked up.
locate_prd_elsewhere() {
  local slug="$1" d
  for d in built-prds parked; do
    if [ -f "$PRD_DIR/$d/PRD-$slug.md" ]; then
      printf '%s\n' "$PRD_DIR/$d/PRD-$slug.md"
      return 0
    fi
  done
  return 1
}

prd_path="$(resolve_prd_path "$prd_arg")"
resolve_rc=$?
if [ "$resolve_rc" -ne 0 ] || [ -z "$prd_path" ]; then
  slug_guess="$(basename "$prd_arg")"
  slug_guess="${slug_guess#PRD-}"
  slug_guess="${slug_guess%.md}"
  elsewhere="$(locate_prd_elsewhere "$slug_guess" || true)"
  if [ -n "$elsewhere" ]; then
    die "not-found: '$prd_arg' resolves to a PRD that has already moved out of build-queue/ -- it now lives at $elsewhere; this script only ever writes to a build-queue/ PRD, refusing rather than creating a stray file at the old queue path" 3
  fi
  die "not-found: no PRD file resolvable from '$prd_arg' (checked directly, and as a slug under $PRD_DIR/build-queue/, built-prds/, and parked/)" 3
fi
case "$(basename "$(dirname "$prd_path")")" in
  build-queue) ;;
  *) die "not-found: $prd_path is not under a build-queue/ directory" 3 ;;
esac

root="$(git -C "$(dirname "$prd_path")" rev-parse --show-toplevel 2>/dev/null)" \
  || die "not-found: $prd_path is not inside a git repo" 3
prd_rel="${prd_path#"$root"/}"
slug="$(basename "$prd_path" .md)"
slug="${slug#PRD-}"

# ---- read helpers (first-80-lines, bullet/bare/bold forms) ---------------
read_status_line() {
  head -n 80 "$1" | grep -E '^(- *Status:|Status:|\*\*Status:\*\*)' | head -n1 \
    | sed -E 's/^(- *Status:|Status:|\*\*Status:\*\*)[[:space:]]*//'
}

read_last_iter_log() {
  head -n 80 "$1" | grep -E '^(- *iter_log:|iter_log:|\*\*iter_log:\*\*)' | tail -n1 \
    | sed -E 's/^(- *iter_log:|iter_log:|\*\*iter_log:\*\*)[[:space:]]*//'
}

# Extract the reason-text this script itself would have written into the
# most recent iter_log line, if that line matches our own fixed format
# (`<ts> needs_classification: <reason>`); empty otherwise (foreign-shaped
# or absent iter_log line never counts as a match for the no-op check).
existing_reason_of() {
  local last_iter="$1" r
  if [[ "$last_iter" =~ ^[^[:space:]]+[[:space:]]+needs_classification:[[:space:]](.*)$ ]]; then
    r="${BASH_REMATCH[1]}"
    # Requirement 1 appends " lint_rc=<rc>" to committed lines; strip it
    # back off before comparing, so a fresh call with the bare reason-text
    # still recognizes an unchanged claim as idempotent.
    r="$(printf '%s' "$r" | sed -E 's/ lint_rc=[0-9]+$//')"
    printf '%s\n' "$r"
  fi
}

# ---- write helper ---------------------------------------------------------
# Sets Status, drops any Lane: line, appends one iter_log line — same
# first-80-lines / preserve-existing-form convention as lane-claim.sh's
# write_claim()/remove_lane_line() and archive-commit.sh's
# write_archive_header().
write_needs_classification() {
  local f="$1" status_val="$2" iso_ts="$3" reason_text="$4"
  python3 - "$f" "$status_val" "$iso_ts" "$reason_text" <<'PYEOF'
import re, sys
f, status_val, iso_ts, reason_text = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]

status_re = re.compile(r'^(?P<pre>-\s*Status:|Status:|\*\*Status:\*\*)\s*(?P<val>.*)$')
lane_re = re.compile(r'^(?:-\s*Lane:|Lane:|\*\*Lane:\*\*)\s*.*$')
iter_re = re.compile(r'^(?:-\s*iter_log:|iter_log:|\*\*iter_log:\*\*)\s*.*$')

status_idx = None
for i, ln in enumerate(head):
    if status_idx is None and status_re.match(ln.rstrip('\n')):
        status_idx = i

if status_idx is not None:
    m = status_re.match(head[status_idx].rstrip('\n'))
    head[status_idx] = f"{m.group('pre')} {status_val}\n"
else:
    head.insert(1, f"- Status: {status_val}\n")
    status_idx = 1

head = [ln for i, ln in enumerate(head)
        if i == status_idx or not lane_re.match(ln.rstrip('\n'))]
status_idx = next(i for i, ln in enumerate(head) if status_re.match(ln.rstrip('\n')))

last_iter_idx = None
for i, ln in enumerate(head):
    if iter_re.match(ln.rstrip('\n')):
        last_iter_idx = i

new_line = f"- iter_log: {iso_ts} needs_classification: {reason_text}\n"
insert_at = (last_iter_idx + 1) if last_iter_idx is not None else (status_idx + 1)
head.insert(insert_at, new_line)

with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
}

# ---- dry-run: read-only, no pull, no lock --------------------------------
if $dry_run; then
  current_status="$(read_status_line "$prd_path")"
  existing_reason="$(existing_reason_of "$(read_last_iter_log "$prd_path")")"
  if [ "$current_status" = "needs_classification" ] && [ "$existing_reason" = "$reason" ]; then
    echo "mark-needs-classification: DRY RUN for $slug — noop (already needs_classification with this reason)"
    exit 0
  fi
  echo "mark-needs-classification: DRY RUN for $slug"
  echo "  would set Status: needs_classification (was: ${current_status:-<none>})"
  [ -n "$(git -C "$root" show HEAD:"$prd_rel" 2>/dev/null | grep -E '^(- *Lane:|Lane:|\*\*Lane:\*\*)')" ] \
    && echo "  would remove the Lane: line"
  echo "  would append: - iter_log: <ISO-ts> needs_classification: $reason"
  echo "  would commit '$slug: needs_classification — ${reason:0:60}' and push in $root"
  exit 0
fi

# ---- pull (tolerant of a sibling's transient dirt elsewhere in the clone) --
git_pull_or_die() {
  local r="$1"
  local pre_head; pre_head="$(git -C "$r" rev-parse HEAD 2>/dev/null)"
  if git -C "$r" pull --rebase --autostash -q 2>/tmp/mark-needs-classification.pull.err; then
    if [ -z "$(git -C "$r" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      return 0
    fi
  fi
  if [ -d "$r/.git/rebase-apply" ] || [ -d "$r/.git/rebase-merge" ]; then
    git -C "$r" rebase --abort 2>/dev/null
  else
    git -C "$r" reset --hard -q "$pre_head" 2>/dev/null
    git -C "$r" stash pop -q 2>/dev/null
  fi
  cat /tmp/mark-needs-classification.pull.err >&2
  die "checkout-conflict: rebase conflict pulling $r; aborted and restored" 4
}

git_pull_or_die "$root"

# ---- idempotency check (post-pull content) -------------------------------
current_status="$(read_status_line "$prd_path")"
existing_reason="$(existing_reason_of "$(read_last_iter_log "$prd_path")")"
if [ "$current_status" = "needs_classification" ] && [ "$existing_reason" = "$reason" ]; then
  echo "needs-classification-noop: $slug (unchanged)"
  exit 0
fi

# ---- claim-reproduction gate (requirement 1) -------------------------------
# Known FAIL ids are read straight off prd-lint.sh's own fail(...) call
# sites rather than hardcoded here, so a new lint id is covered without
# touching this script.
known_lint_ids="$(grep -oE 'fail\("[a-z0-9-]+"' "$PRD_LINT" 2>/dev/null \
  | sed -E 's/^fail\("//; s/"$//' | sort -u)"

lint_json="$("$PRD_LINT" "$prd_path" --format json 2>/dev/null)"
lint_rc=$?
[ -n "$lint_json" ] || lint_json='[]'

lint_decision="$(python3 -c '
import json, re, sys
known_ids = set(sys.argv[1].split())
reason = sys.argv[2]
try:
    results = json.loads(sys.argv[3])
except Exception:
    results = []
fail_ids = set()
for r in results:
    for f in r.get("failures", []):
        fail_ids.add(f.get("id", ""))
tokens = re.split(r"[^a-z0-9-]+", reason.lower())
matched = ""
for tok in tokens:
    if tok in known_ids:
        matched = tok
        break
reproduced = (matched in fail_ids) if matched else True
print(json.dumps({"matched_id": matched, "reproduced": reproduced}))
' "$known_lint_ids" "$reason" "$lint_json")"

matched_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["matched_id"])' "$lint_decision")"
reproduced="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reproduced"])' "$lint_decision")"

if [ -n "$matched_id" ] && [ "$reproduced" != "True" ]; then
  if $force; then
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  needs_classification  forced  (cause=claim-not-reproduced lint_id=$matched_id lint_rc=$lint_rc lane=$(hostname))"
  else
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  needs_classification  refused  (cause=claim-not-reproduced lint_id=$matched_id lint_rc=$lint_rc)"
    echo "needs-classification-refused: $slug (cause=claim-not-reproduced lint_id=$matched_id lint_rc=$lint_rc)"
    exit 3
  fi
fi

# ---- write + commit --------------------------------------------------------
iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_reason="$reason lint_rc=$lint_rc"
write_needs_classification "$prd_path" "needs_classification" "$iso_ts" "$write_reason" \
  || die "write: failed writing Status/iter_log into $prd_rel" 4

git -C "$root" add -- "$prd_rel" || die "add: git add failed for $prd_rel" 4
if git -C "$root" diff --cached --quiet -- "$prd_rel"; then
  die "commit: nothing staged after header write — aborting" 4
fi

subject="$slug: needs_classification — ${reason:0:60}"
git -C "$root" "${GIT_ID[@]}" commit -q -m "$subject" -- "$prd_rel" \
  || die "commit: git commit failed" 4
commit_sha="$(git -C "$root" rev-parse HEAD)"

# ---- push, with one rebase+retry on rejection ------------------------------
push_or_die() {
  local r="$1" branch
  branch=$(git -C "$r" symbolic-ref --short HEAD)
  if git -C "$r" push origin "$branch" -q 2>/tmp/mark-needs-classification.push.err; then
    return 0
  fi
  if ! git -C "$r" fetch origin -q 2>/tmp/mark-needs-classification.fetch.err; then
    cat /tmp/mark-needs-classification.fetch.err >&2
    die "push-failed: origin unreachable during push for $r; commit $commit_sha left local" 3
  fi
  if ! git -C "$r" rebase "origin/$branch" -q 2>/tmp/mark-needs-classification.rebase.err; then
    git -C "$r" rebase --abort >/dev/null 2>&1 || true
    cat /tmp/mark-needs-classification.rebase.err >&2
    die "push-failed: rebase conflict against origin/$branch for $r; commit $commit_sha left local" 3
  fi
  if git -C "$r" push origin "$branch" -q 2>/tmp/mark-needs-classification.push2.err; then
    return 0
  fi
  cat /tmp/mark-needs-classification.push2.err >&2
  die "push-failed: push still rejected after rebase retry for $r; commit $commit_sha left local" 3
}

push_or_die "$root"

echo "needs-classification-committed: $slug $commit_sha"
