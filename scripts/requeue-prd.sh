#!/usr/bin/env bash
# requeue-prd.sh <prd-path-or-slug> <reason-text> — the durable inverse of
# mark-needs-classification.sh's park transition.
# Per PRD-build-classification-durable-heal, requirement 2.
#
# Background: mark-needs-classification.sh makes `Status: needs_classification`
# a real, committed+pushed transition instead of a manifest-cache-only edit.
# Until this script existed, the INVERSE — a parked PRD whose diagnosis
# turns out to be stale (prd-lint.sh now passes) — only ever got un-parked
# in the LOCAL manifest cache (see manifest-invariants.sh's
# needs-classification-lint-pass heal), while the file on `origin/main`
# — what every lane's Phase 1 reconcile trusts over the cache — kept
# reading `needs_classification`. The 2026-09-13 mcphost-agent-consent
# PRD sat unselectable for ~13h this exact way. This script closes that
# half: requeuing is now as durable as parking.
#
# What it does:
#   1. Resolves <prd-path> the same way mark-needs-classification.sh does
#      (a full path, or a bare slug under $PRD_DIR/build-queue/).
#   2. Idempotent no-op (no write, no commit) if `Status:` already reads
#      `queued` — a heal re-checking an already-requeued PRD, or a second
#      operator call, must never pile up duplicate commits.
#   3. Otherwise (`Status:` reads `needs_classification`): sets
#      `Status: queued` and PREPENDS one
#      `- iter_log: <ISO-ts> requeued: <reason-text>` line as the FIRST
#      iter_log line (ahead of any existing ones — a requeue is reported
#      before the history it's overriding, not buried after it).
#      A `Status:` reading anything else (not `queued`, not
#      `needs_classification`) is refused (exit 4) rather than guessed at.
#   4. Commits with the Joe Yen identity, subject
#      `"<slug>: requeued — <first 60 chars of reason-text>"`.
#   5. Same pull/push discipline as mark-needs-classification.sh:
#      `git pull --rebase --autostash` first (tolerates a sibling's
#      transient uncommitted dirt elsewhere in the shared clone), plain
#      `git push` after commit, on rejection one `git fetch` + `git rebase`
#      + retried push. A push still failing after that is exit 3 — the
#      commit is left local rather than silently reporting success.
#   6. On success, prints `requeued-committed: <slug> <sha>`.
#
# This script owns only the file+git layer, the same split
# mark-needs-classification.sh already uses: it never touches the
# manifest cache. A caller that also needs the cache updated (e.g.
# manifest-invariants.sh's needs-classification-lint-pass heal, see
# requirement 3) calls scripts/manifest-set.sh itself, and only AFTER
# this script returns 0 — so a failed requeue never leaves the cache
# claiming a file state that doesn't exist on disk/origin.
#
# Usage:
#   requeue-prd.sh <prd-path-or-slug> <reason-text> [--dry-run]
#
# Env:
#   PRD_DIR   Shared PRDs checkout root, used only to resolve a bare slug
#             argument (default: ~/Documents/PRDs). Ignored when
#             <prd-path> is already an existing file path.
#
# Options:
#   --dry-run   Print the Status/iter_log line that would be written (or
#               report the idempotent no-op) and exit 0; mutates nothing,
#               takes no lock, does not pull.
#
# Exit codes:
#   0   committed+pushed, or idempotent no-op (already queued)
#   2   usage error
#   3   not-found (<prd-path> doesn't resolve to a file under a
#       build-queue/ directory in a git repo) or push-failed (commit
#       landed locally; rebase+retry-once still couldn't push)
#   4   local git error (pull hit a real rebase conflict, or the header
#       write/`git add`/`git commit` step failed), or the PRD's current
#       `Status:` is neither `queued` nor `needs_classification` (refusing
#       to guess what a requeue should mean from an unexpected state) —
#       see stderr for which
#
# Stdout on success:
#   requeued-committed: <slug> <sha>
# Stdout on idempotent no-op:
#   requeued-noop: <slug> (already queued)

set -uo pipefail

GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"

die() { printf '%s\n' "requeue-prd: $*" >&2; exit "${2:-4}"; }

# ---- args ---------------------------------------------------------------
dry_run=false
prd_arg=""
reason=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,74p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
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
  || die "usage: requeue-prd.sh <prd-path-or-slug> <reason-text> [--dry-run]" 2

# Frontmatter values are one line each -- collapse any embedded newlines so
# a multi-line reason string can't split into a stray second field.
reason="${reason//$'\n'/ }"

# ---- resolve the PRD path -------------------------------------------------
# Same resolution rules as mark-needs-classification.sh: a bare slug is
# only ever looked up under build-queue/ (a parked/needs_classification
# PRD never leaves build-queue/ -- parked/ is a different, operator-driven
# state this script never touches).
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

# ---- write helper -----------------------------------------------------
# Sets Status: queued, PREPENDS one iter_log line as the first iter_log
# line (ahead of any existing ones) -- deliberately the opposite insertion
# point from mark-needs-classification.sh's append, per requirement 2:
# "prepends" a requeue announcement rather than tacking it onto the end of
# a possibly-long park/bounce history.
write_requeue() {
  local f="$1" iso_ts="$2" reason_text="$3"
  python3 - "$f" "$iso_ts" "$reason_text" <<'PYEOF'
import re, sys
f, iso_ts, reason_text = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]

status_re = re.compile(r'^(?P<pre>-\s*Status:|Status:|\*\*Status:\*\*)\s*(?P<val>.*)$')

status_idx = None
for i, ln in enumerate(head):
    if status_idx is None and status_re.match(ln.rstrip('\n')):
        status_idx = i

if status_idx is not None:
    m = status_re.match(head[status_idx].rstrip('\n'))
    head[status_idx] = f"{m.group('pre')} queued\n"
else:
    head.insert(1, "- Status: queued\n")
    status_idx = 1

new_line = f"- iter_log: {iso_ts} requeued: {reason_text}\n"
head.insert(status_idx + 1, new_line)

with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
}

# ---- dry-run: read-only, no pull, no lock --------------------------------
if $dry_run; then
  current_status="$(read_status_line "$prd_path")"
  if [ "$current_status" = "queued" ]; then
    echo "requeue-prd: DRY RUN for $slug — noop (already queued)"
    exit 0
  fi
  echo "requeue-prd: DRY RUN for $slug"
  echo "  would set Status: queued (was: ${current_status:-<none>})"
  echo "  would prepend: - iter_log: <ISO-ts> requeued: $reason"
  echo "  would commit '$slug: requeued — ${reason:0:60}' and push in $(git -C "$(dirname "$prd_path")" rev-parse --show-toplevel 2>/dev/null)"
  exit 0
fi

# ---- pull (tolerant of a sibling's transient dirt elsewhere in the clone) --
git_pull_or_die() {
  local r="$1"
  local pre_head; pre_head="$(git -C "$r" rev-parse HEAD 2>/dev/null)"
  if git -C "$r" pull --rebase --autostash -q 2>/tmp/requeue-prd.pull.err; then
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
  cat /tmp/requeue-prd.pull.err >&2
  die "checkout-conflict: rebase conflict pulling $r; aborted and restored" 4
}

git_pull_or_die "$root"

# ---- idempotency check (post-pull content) -------------------------------
current_status="$(read_status_line "$prd_path")"
if [ "$current_status" = "queued" ]; then
  echo "requeued-noop: $slug (already queued)"
  exit 0
fi
if [ "$current_status" != "needs_classification" ]; then
  die "unexpected-status: $prd_rel reads Status: ${current_status:-<none>} -- requeue-prd.sh only moves needs_classification -> queued, refusing to guess" 4
fi

# ---- write + commit --------------------------------------------------------
iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_requeue "$prd_path" "$iso_ts" "$reason" \
  || die "write: failed writing Status/iter_log into $prd_rel" 4

git -C "$root" add -- "$prd_rel" || die "add: git add failed for $prd_rel" 4
if git -C "$root" diff --cached --quiet -- "$prd_rel"; then
  die "commit: nothing staged after header write — aborting" 4
fi

subject="$slug: requeued — ${reason:0:60}"
git -C "$root" "${GIT_ID[@]}" commit -q -m "$subject" -- "$prd_rel" \
  || die "commit: git commit failed" 4
commit_sha="$(git -C "$root" rev-parse HEAD)"

# ---- push, with one rebase+retry on rejection ------------------------------
push_or_die() {
  local r="$1" branch
  branch=$(git -C "$r" symbolic-ref --short HEAD)
  if git -C "$r" push origin "$branch" -q 2>/tmp/requeue-prd.push.err; then
    return 0
  fi
  if ! git -C "$r" fetch origin -q 2>/tmp/requeue-prd.fetch.err; then
    cat /tmp/requeue-prd.fetch.err >&2
    die "push-failed: origin unreachable during push for $r; commit $commit_sha left local" 3
  fi
  if ! git -C "$r" rebase "origin/$branch" -q 2>/tmp/requeue-prd.rebase.err; then
    git -C "$r" rebase --abort >/dev/null 2>&1 || true
    cat /tmp/requeue-prd.rebase.err >&2
    die "push-failed: rebase conflict against origin/$branch for $r; commit $commit_sha left local" 3
  fi
  if git -C "$r" push origin "$branch" -q 2>/tmp/requeue-prd.push2.err; then
    return 0
  fi
  cat /tmp/requeue-prd.push2.err >&2
  die "push-failed: push still rejected after rebase retry for $r; commit $commit_sha left local" 3
}

push_or_die "$root"

echo "requeued-committed: $slug $commit_sha"
