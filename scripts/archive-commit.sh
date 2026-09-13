#!/usr/bin/env bash
# archive-commit.sh <slug> — the WHOLE archive write for a shipped PRD, as
# one atomic sequence. Per PRD-build-archive-atomic-commit.
#
# Before this script, SKILL.md's "archive" action was prose: a builder
# agent hand-sequenced setting Status/Built/Receipts, `git mv` into
# built-prds/, and commit+push against the ONE shared `~/Documents/PRDs`
# checkout up to 4 parallel /build branches use. On tick n=27
# (2026-09-12) a builder committed the move first (85086e6, zero content
# change) and the header edit separately afterwards (e3b06a5), and in the
# gap a sibling's `lane-claim.sh` pull hit the dirty checkout and failed.
# This script removes the ordering decision from the agent entirely: the
# header write, the move, the manifest-line flip, and the commit all land
# together, in one commit, or none of them land at all.
#
# Serializes against `worktree-extend.sh`'s integrate/land (same per-repo
# lock file, `<repo>/.git/autobuilder-integrate.lock`, same `flock`
# discipline) so an archive and an integrate/land against the same repo
# never interleave, and so two archives in the same tick queue on each
# other rather than race.
#
# Order, all under the lock:
#   1. verify build-queue/PRD-<slug>.md exists and neither it nor
#      MANIFEST.md already carries an uncommitted change in this checkout
#      (a sibling's dirty file ELSEWHERE in the checkout does not block
#      this — the check is scoped to the two paths this script touches).
#   2. resolve the receipt (state/manifest.json's `receipts_dir` for this
#      slug, plus `gate.verdict` / `tag` / `rollback_base` if present) —
#      the same sources SKILL.md's old manual sequence named; the agent no
#      longer types them.
#   3. write `Status: built`, `Built: <date>`, `Receipts: <path>` into the
#      PRD while it is still in build-queue/.
#   4. `git mv` it into built-prds/.
#   5. flip its line in the checkout's own MANIFEST.md to `shipped` — or,
#      per PRD-build-archive-manifest-backfill, when no line exists yet
#      for this slug (a hand-queued PRD /dream never reconciled),
#      BACKFILL one into the `## built-prds` section instead of dying.
#      The backfilled line's format is derived from a sibling entry
#      already in the file (same field order/separators); if no sibling
#      can be parsed, a documented fallback format is used and that fact
#      is journaled. A MANIFEST.md that is unreadable, or that carries
#      two-or-more conflicting lines for the same slug, still fails
#      loudly (distinct exit codes — see below).
#   6. `git add` exactly those two paths, one commit `archive: <slug>
#      shipped` (plus a body line naming the backfill, when one happened).
#   7. `git pull --rebase --autostash` (tolerate a sibling's transient
#      dirt the same way the hardened lane-claim.sh pull does).
#   8. `git push`.
#
# Any failure at steps 1-5 (before the commit) reverts the working tree
# for the two touched paths and exits non-zero naming the step. A failure
# at step 7/8 (after the commit already landed locally) leaves the commit
# in place and reports the push as pending — the write itself already
# happened atomically, so there is no half-archived state to clean up; a
# later `git push` (or a re-run of this script, which is a no-op once the
# PRD is already in built-prds/) finishes the job.
#
# Usage:
#   archive-commit.sh <slug> [--dry-run] [--lock-wait N]
#
# Env:
#   PRD_DIR         Shared PRDs checkout root (default: ~/Documents/PRDs).
#   BUILD_MANIFEST  build-skill's own state manifest (default:
#                   <skill-dir>/state/manifest.json) — same variable name
#                   manifest-set.sh uses, read here (not written) for
#                   `receipts_dir` / `gate.verdict` / `tag` /
#                   `rollback_base`.
#   JQ              jq binary (default: /usr/bin/jq).
#
# Options:
#   --dry-run       Print the header lines and paths that would be
#                   touched; mutate nothing, exit 0. Does not take the
#                   lock (nothing is written).
#   --lock-wait N   Seconds to wait for the integrate lock before giving
#                   up (default 120).
#
# Exit codes:
#   0   archived (or dry-run printed the plan, or already-archived no-op —
#       see Idempotence below) — ONLY ever returned once the postcondition
#       below is independently verified, never on the strength of the
#       write steps having merely run without erroring.
#   2   usage error
#   3   not-queued (PRD missing from build-queue/) or receipt unresolved
#   4   dirty checkout for the touched paths, or a write step failed
#       (including an unreadable MANIFEST.md) — working tree for those
#       paths restored
#   5   lock-timeout — no writes
#   6   commit landed but push is pending (network/rebase-conflict after
#       our own commit) — not a corrupt state, just an unfinished push
#   7   manifest-duplicate: MANIFEST.md carries two-or-more conflicting
#       lines for this slug — genuine corruption, not absence; no writes
#   8   postcondition-failed (PRD-build-archive-verify-before-shipped):
#       the write steps and push all reported success, but re-checking
#       the filesystem/reachability afterward disagrees — built-prds/
#       missing, build-queue/ still present, or the commit isn't
#       reachable from origin's current branch. Never treat a caller-side
#       "it exited without dying" as success; only exit 0 satisfies this.
#
# Idempotence: if the slug is already gone from build-queue/, already
# present in built-prds/, AND MANIFEST.md already shows it `shipped`,
# this is a no-op: prints one line and exits 0 without touching the
# checkout (a retry after a prior fully-successful archive, or a
# duplicate dispatch, is always safe to re-run) — PROVIDED the commit is
# also reachable from origin (requirement 1); if the local state already
# looks archived but the commit never reached origin, this finishes the
# push under the lock instead of silently no-opping (see below).
#
# Retry (PRD-build-archive-verify-before-shipped requirement 4): a
# transient failure — lock-timeout (5) or push-still-pending after a
# local commit (6) — is retried ONCE, after a short delay
# ($ARCHIVE_COMMIT_RETRY_DELAY, default 5s), by re-invoking this same
# script as a fresh process. A real blocking condition (2/3/4/7/8) is
# never retried — it fails loudly on the first attempt, exactly as
# before.
#
# Stdout on a successful (or push-pending) run:
#   archive-commit <slug> commit=<sha> pushed=<yes|pending> lock_wait=<s>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
JQ="${JQ:-/usr/bin/jq}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
BUILD_MANIFEST="${BUILD_MANIFEST:-$SKILL_DIR/state/manifest.json}"
export JQ PRD_DIR BUILD_MANIFEST
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

log() { printf '%s\n' "archive-commit: $*" >&2; }
die() { printf '%s\n' "archive-commit: $*" >&2; exit "${2:-2}"; }

slug=""
dry_run=false
lock_wait=120

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)     dry_run=true; shift ;;
    --lock-wait)   lock_wait="${2:?archive-commit: --lock-wait needs a value}"; shift 2 ;;
    --lock-wait=*) lock_wait="${1#--lock-wait=}"; shift ;;
    -h|--help)     sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    --)            shift; break ;;
    -*)            die "unknown flag $1" ;;
    *)             [ -z "$slug" ] && slug="$1" || die "unexpected arg $1"; shift ;;
  esac
done

[ -n "$slug" ] || die "usage: archive-commit.sh <slug> [--dry-run] [--lock-wait N]"
[ -x "$JQ" ] || die "jq not at $JQ"
[ -d "$PRD_DIR/.git" ] || die "not-queued: $PRD_DIR is not a git checkout" 3

prd_rel="build-queue/PRD-$slug.md"
built_rel="built-prds/PRD-$slug.md"
manifest_rel="MANIFEST.md"
prd_path="$PRD_DIR/$prd_rel"
manifest_md="$PRD_DIR/$manifest_rel"

# ---- reachability helpers (requirement 1: a commit isn't "archived"
# until it's reachable from origin, not just present in the local
# working tree — checked against origin/<the branch actually checked
# out here>, since this script only ever pushes the current branch and
# never assumes the remote's name for it is "main"). --------------------
current_branch() { git -C "$PRD_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null; }
commit_reachable() {
  local sha="${1:-}" branch
  [ -n "$sha" ] || return 1
  branch="$(current_branch)"
  [ -n "$branch" ] || return 1
  git -C "$PRD_DIR" merge-base --is-ancestor "$sha" "origin/$branch" 2>/dev/null
}

# ---- requirement 4: retry once on a TRANSIENT failure (lock contention
# / a concurrent rebase-push race), never on a real blocking condition.
# A thin outer wrapper that re-invokes this same script once, as a fresh
# child process, with $_ARCHIVE_COMMIT_ATTEMPT set — so the single-attempt
# logic below (idempotence check through the final postcondition
# verification) never has to know it might run twice. Skipped entirely
# for --dry-run (read-only, nothing to retry) and inside the child
# invocation itself (guarded by $_ARCHIVE_COMMIT_ATTEMPT). Exit 5
# (lock-timeout, no writes yet) and exit 6 (push pending after a local
# commit) are the two transient codes this retries; 2/3/4/7/8 are real
# blocking conditions and pass straight through unretried on the first
# attempt — retrying those would risk a false success on the second pass
# instead of failing loudly, exactly what requirement 4 forbids.
if [ "$dry_run" = false ] && [ -z "${_ARCHIVE_COMMIT_ATTEMPT:-}" ]; then
  retry_delay="${ARCHIVE_COMMIT_RETRY_DELAY:-5}"
  out="$(_ARCHIVE_COMMIT_ATTEMPT=1 bash "${BASH_SOURCE[0]}" "$slug" --lock-wait "$lock_wait")"
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 5 ] || [ "$rc" -eq 6 ]; then
    log "transient failure (exit $rc) on attempt 1 for $slug; retrying in ${retry_delay}s"
    sleep "$retry_delay"
    out="$(_ARCHIVE_COMMIT_ATTEMPT=2 bash "${BASH_SOURCE[0]}" "$slug" --lock-wait "$lock_wait")"
    rc=$?
    printf '%s\n' "$out"
  fi
  exit "$rc"
fi

# ---- idempotence: already fully archived is a no-op, not a failure ----
# (PRD-build-archive-manifest-backfill requirement 5.) Only short-circuits
# when ALL of: the PRD is gone from build-queue/, present in built-prds/,
# and MANIFEST.md's own line for this slug already says shipped — i.e.
# the whole atomic step-6 commit from a prior run already landed. A
# partial/in-between state can't persist past this script's own atomic
# commit, so this never masks a genuine not-queued/receipt-unresolved
# failure.
#
# PRD-build-archive-verify-before-shipped requirement 1 extends this: the
# check above only ever looked at this checkout's own working tree,
# which is exactly the blind spot the whole PRD is about — a prior run's
# commit can satisfy every local-file condition while never having
# reached origin (a `git push` that silently no-ops, or a rebase that
# drops it). When that's the state found here, this is NOT a no-op: the
# write already happened locally, so finish the push under the lock
# rather than re-doing the mv/header/manifest edit (which would just die
# "nothing staged", having nothing new to write).
if [ ! -f "$prd_path" ] && [ -f "$PRD_DIR/$built_rel" ] && [ -r "$manifest_md" ] \
   && grep -Eq -- "^-[[:space:]]*PRD-${slug}\.md[[:space:]]+—[[:space:]]+shipped([[:space:]]|·)" "$manifest_md"; then
  local_commit="$(git -C "$PRD_DIR" log -1 --format=%H -- "$built_rel" 2>/dev/null)"
  if [ -n "$local_commit" ] && commit_reachable "$local_commit"; then
    printf 'archive-commit %s already-archived (no-op) commit=%s\n' "$slug" "$local_commit"
    exit 0
  fi
  log "already-archived locally (commit ${local_commit:-<unknown>}) but not yet reachable from origin/$(current_branch) — finishing the pending push under the lock rather than re-writing"
  lock_file="$PRD_DIR/.git/autobuilder-integrate.lock"
  exec 9>"$lock_file"
  wait_start=$(date +%s)
  if ! flock -w "$lock_wait" 9; then
    die "lock-timeout: could not acquire integration lock to finish pending push for $slug" 5
  fi
  lock_wait_secs=$(( $(date +%s) - wait_start ))
  if ! git -C "$PRD_DIR" pull --rebase --autostash -q 2>/tmp/archive-commit.pull.err; then
    cat /tmp/archive-commit.pull.err >&2
    git -C "$PRD_DIR" rebase --abort 2>/dev/null || true
    die "push-pending: pull --rebase --autostash still failing while finishing $slug" 6
  fi
  if ! git -C "$PRD_DIR" push -q 2>/tmp/archive-commit.push.err; then
    cat /tmp/archive-commit.push.err >&2
    die "push-pending: push still failing while finishing $slug" 6
  fi
  local_commit="$(git -C "$PRD_DIR" log -1 --format=%H -- "$built_rel" 2>/dev/null)"
  if ! commit_reachable "$local_commit"; then
    die "postcondition-failed: $local_commit still not reachable from origin/$(current_branch) after finishing the push for $slug" 8
  fi
  printf 'archive-commit %s commit=%s pushed=yes lock_wait=%s\n' "$slug" "$local_commit" "$lock_wait_secs"
  exit 0
fi

# ---- resolve the receipt + header values (state/manifest.json) --------
resolve_receipt() {
  [ -r "$BUILD_MANIFEST" ] || { log "receipt: $BUILD_MANIFEST unreadable"; return 1; }
  local entry
  entry="$("$JQ" -c --arg s "$slug" '.prds[$s] // empty' "$BUILD_MANIFEST" 2>/dev/null)"
  [ -n "$entry" ] || { log "receipt: no manifest entry for slug '$slug' in $BUILD_MANIFEST"; return 1; }
  receipts_dir="$("$JQ" -r '.receipts_dir // empty' <<<"$entry" 2>/dev/null)"
  if [ -z "$receipts_dir" ] || [ ! -e "$receipts_dir" ]; then
    log "receipt: manifest entry '$slug' has no existing receipts_dir (got '${receipts_dir:-<empty>}')"
    return 1
  fi
  gate_verdict="$("$JQ" -r '.gate.verdict // empty' <<<"$entry" 2>/dev/null)"
  tag_val="$("$JQ" -r '.tag // empty' <<<"$entry" 2>/dev/null)"
  rollback_base="$("$JQ" -r '.rollback_base // empty' <<<"$entry" 2>/dev/null)"
  receipts_val="$receipts_dir"
  local extra=()
  [ -n "$gate_verdict" ]  && extra+=("verdict=$gate_verdict")
  [ -n "$tag_val" ]       && extra+=("tag $tag_val")
  [ -n "$rollback_base" ] && extra+=("rollback base $rollback_base")
  if [ "${#extra[@]}" -gt 0 ]; then
    local joined="" e
    for e in "${extra[@]}"; do joined="${joined:+$joined; }$e"; done
    receipts_val="$receipts_val ($joined)"
  fi
  return 0
}

# Write/replace Status + Built + Receipts lines in $1 (PRD path), first-80
# convention shared with lane-claim.sh's write_claim(). Any pre-existing
# Built:/Receipts: lines are dropped first so a re-run never duplicates
# them; Status is rewritten in place preserving its existing line form.
write_archive_header() {
  local f="$1" built_date="$2" receipts_val="$3"
  python3 - "$f" "$built_date" "$receipts_val" <<'PYEOF'
import re, sys
f, built_date, receipts_val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]

status_re = re.compile(r'^(?P<pre>-\s*Status:|Status:|\*\*Status:\*\*)\s*(?P<val>.*)$')
built_re = re.compile(r'^(?:-\s*Built:|Built:|\*\*Built:\*\*)\s*.*$')
receipts_re = re.compile(r'^(?:-\s*Receipts:|Receipts:|\*\*Receipts:\*\*)\s*.*$')

status_idx = None
for i, ln in enumerate(head):
    if status_idx is None and status_re.match(ln.rstrip('\n')):
        status_idx = i

if status_idx is not None:
    m = status_re.match(head[status_idx].rstrip('\n'))
    head[status_idx] = f"{m.group('pre')} built\n"
else:
    head.insert(1, "- Status: built\n")
    status_idx = 1

head = [ln for i, ln in enumerate(head)
        if i == status_idx or not (built_re.match(ln.rstrip('\n')) or receipts_re.match(ln.rstrip('\n')))]
status_idx = next(i for i, ln in enumerate(head) if status_re.match(ln.rstrip('\n')))

head[status_idx + 1:status_idx + 1] = [f"- Built: {built_date}\n", f"- Receipts: {receipts_val}\n"]

with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
}

# Flip this slug's own line in the checkout's MANIFEST.md to `shipped`,
# preserving whatever build_target/date tail it already has — OR, per
# PRD-build-archive-manifest-backfill, when no line exists yet for this
# slug, BACKFILL one into the `## built-prds` section (the section the
# slug's file now lives in, post-mv) instead of failing.
#
# $1 = MANIFEST.md path, $2 = slug, $3 = the PRD's now-built-prds/ path
#      (read-only, to source build_target/Drafted for a backfilled line).
#
# Prints one of the following to stdout on success:
#   FLIPPED               — an existing line was found and flipped
#   BACKFILLED sibling     — no line existed; appended using a sibling
#                            entry's exact format (field order/separators)
#   BACKFILLED fallback    — no line existed and no sibling entry could be
#                            parsed anywhere in the file; appended using
#                            the documented hardcoded format instead
#
# Exit codes (no output, no write, on any nonzero):
#   2   duplicate: more than one existing line matches this slug — real
#       corruption, distinct from "absent" (mapped to exit 7 by the caller)
#   3   no `## built-prds` section header found (can't place a backfill)
update_manifest_md() {
  local f="$1" slug="$2" prd_path_for_fields="${3:-}"
  python3 - "$f" "$slug" "$prd_path_for_fields" <<'PYEOF'
import re, sys
f, slug, prd_path_for_fields = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
name = f"PRD-{slug}.md"

with open(f) as fh:
    lines = fh.readlines()

# Any line naming this slug's PRD file with the "— <status> ..." shape.
entry_pat = re.compile(r'^-\s*' + re.escape(name) + r'\s+—\s+([^·\n]+?)(\s*·.*)$')
matches = [i for i, ln in enumerate(lines) if entry_pat.match(ln.rstrip('\n'))]

if len(matches) > 1:
    sys.stderr.write(f"duplicate: {len(matches)} MANIFEST.md lines match {name}\n")
    sys.exit(2)

if len(matches) == 1:
    i = matches[0]
    m = entry_pat.match(lines[i].rstrip('\n'))
    prefix = lines[i].rstrip('\n')[:m.start(1)]
    lines[i] = f"{prefix}shipped{m.group(2)}\n"
    with open(f, 'w') as fh:
        fh.writelines(lines)
    print("FLIPPED")
    sys.exit(0)

# ---- no existing line: backfill into the built-prds section -----------
sec_start = None
sec_end = len(lines)
for i, ln in enumerate(lines):
    if ln.rstrip('\n') == "## built-prds":
        sec_start = i
    elif sec_start is not None and ln.startswith("## "):
        sec_end = i
        break
if sec_start is None:
    sys.stderr.write("no '## built-prds' section header found in MANIFEST.md\n")
    sys.exit(3)

# A full sibling entry: "- PRD-<other>.md — <status> · <target> · <date>".
# Group 1 ("lead") is only the bullet ("- "); the sibling's own
# "PRD-<other>.md" is captured separately (and discarded) so it is never
# accidentally prepended onto this slug's own name below.
sib_pat = re.compile(
    r'^(-\s*)PRD-([^ ]+\.md)(\s+—\s+)([^·\n]+?)(\s*·\s*)([^·\n]+?)(\s*·\s*)([^\n]+?)\s*$'
)

def find_sibling(idx_range):
    for i in idx_range:
        m = sib_pat.match(lines[i].rstrip('\n'))
        if m:
            return m
    return None

sib = find_sibling(range(sec_start + 1, sec_end)) or find_sibling(range(len(lines)))

# Pull build_target / Drafted straight from the PRD file (already moved
# into built-prds/ by step 4) so the backfilled line reflects real values,
# never guesses.
build_target = "?"
drafted = "?"
if prd_path_for_fields:
    try:
        with open(prd_path_for_fields) as pf:
            body = pf.read()
    except OSError:
        body = ""
    mt = re.search(r'^-\s*build_target:\s*(\S+)', body, re.MULTILINE)
    if mt:
        build_target = mt.group(1)
    md_ = re.search(r'^-\s*Drafted:\s*(\S+)', body, re.MULTILINE)
    if md_:
        drafted = md_.group(1)

if sib is None:
    new_line = f"- {name} — shipped · {build_target} · {drafted}\n"
    verdict = "BACKFILLED fallback"
else:
    lead, _sib_name, mid1, _sib_status, mid2, _sib_target, mid3, _sib_date = sib.groups()
    # `lead` is just the "- " bullet (e.g. "- "); `name` already carries the
    # full "PRD-<slug>.md" — do not also copy the sibling's own filename.
    new_line = f"{lead}{name}{mid1}shipped{mid2}{build_target}{mid3}{drafted}\n"
    verdict = "BACKFILLED sibling"

# Insert right after the section's last real entry — before any blank
# line(s) that separate this section from the next header — so a
# backfilled line never leaves a stray gap ahead of it (matches /dream's
# own contiguous-entries-then-one-blank-line convention).
insert_at = sec_end
while insert_at > sec_start + 1 and lines[insert_at - 1].strip() == "":
    insert_at -= 1
lines[insert_at:insert_at] = [new_line]
with open(f, 'w') as fh:
    fh.writelines(lines)
print(verdict)
PYEOF
}

# ---- dry-run: read-only, no lock -----------------------------------
if $dry_run; then
  [ -f "$prd_path" ] || die "not-queued: $prd_rel not found under $PRD_DIR" 3
  resolve_receipt || die "receipt: could not resolve a receipt for '$slug'" 3
  built_date="$(date +%Y-%m-%d)"
  echo "archive-commit: DRY RUN for $slug"
  echo "  would write into $prd_rel:"
  echo "    - Status: built"
  echo "    - Built: $built_date"
  echo "    - Receipts: $receipts_val"
  echo "  would git mv $prd_rel -> $built_rel"
  echo "  would flip $manifest_rel's $slug line to shipped"
  echo "  would commit 'archive: $slug shipped' and push in $PRD_DIR"
  exit 0
fi

# ---- take the integrate lock (shared with worktree-extend.sh) ---------
lock_file="$PRD_DIR/.git/autobuilder-integrate.lock"
exec 9>"$lock_file"
wait_start=$(date +%s)
if ! flock -w "$lock_wait" 9; then
  die "lock-timeout: could not acquire integration lock for $PRD_DIR within ${lock_wait}s" 5
fi
lock_wait_secs=$(( $(date +%s) - wait_start ))

# ---- step 1: verify queued + scoped-clean ------------------------------
[ -f "$prd_path" ] || die "not-queued: $prd_rel not found under $PRD_DIR" 3
dirty="$(git -C "$PRD_DIR" status --porcelain -- "$prd_rel" "$manifest_rel" 2>/dev/null)"
[ -z "$dirty" ] || die "dirty: $prd_rel or $manifest_rel already has an uncommitted change in $PRD_DIR — refusing" 4

# ---- step 2: resolve receipt / header values ---------------------------
resolve_receipt || die "receipt: could not resolve a receipt for '$slug' — no writes made" 3
built_date="$(date +%Y-%m-%d)"

# From here on we mutate the working tree; arm a pre-commit revert so any
# failure through step 6 leaves the checkout exactly as it started.
committed=false
cleanup_on_fail() {
  $committed && return
  git -C "$PRD_DIR" checkout --quiet -- "$manifest_rel" 2>/dev/null
  if [ -f "$PRD_DIR/$built_rel" ] && [ ! -f "$prd_path" ]; then
    git -C "$PRD_DIR" mv -f "$built_rel" "$prd_rel" 2>/dev/null || mv -f "$PRD_DIR/$built_rel" "$prd_path" 2>/dev/null
  fi
  git -C "$PRD_DIR" checkout --quiet -- "$prd_rel" 2>/dev/null
  git -C "$PRD_DIR" reset --quiet -- "$prd_rel" "$built_rel" "$manifest_rel" 2>/dev/null
}
trap cleanup_on_fail EXIT

# ---- step 3: write header (while still in build-queue/) ---------------
write_archive_header "$prd_path" "$built_date" "$receipts_val" \
  || die "header: failed writing Status/Built/Receipts into $prd_rel" 4

# ---- step 4: move into built-prds/ -------------------------------------
git -C "$PRD_DIR" mv "$prd_rel" "$built_rel" \
  || die "mv: git mv $prd_rel -> $built_rel failed" 4

# ---- step 5: flip the MANIFEST.md line, or backfill a missing one -----
[ -r "$manifest_md" ] || die "manifest: $manifest_rel unreadable under $PRD_DIR" 4
manifest_result="$(update_manifest_md "$manifest_md" "$slug" "$PRD_DIR/$built_rel")"
manifest_rc=$?
if [ "$manifest_rc" -eq 2 ]; then
  die "manifest: MANIFEST.md carries conflicting/duplicate lines for $slug under $PRD_DIR" 7
elif [ "$manifest_rc" -ne 0 ]; then
  die "manifest: could not update MANIFEST.md for $slug under $PRD_DIR (rc=$manifest_rc)" 4
fi
manifest_backfill_format=""
case "$manifest_result" in
  "BACKFILLED sibling")
    manifest_backfill_format="sibling"
    log "manifest-backfill (slug=$slug section=built-prds format=sibling)"
    ;;
  "BACKFILLED fallback")
    manifest_backfill_format="fallback"
    log "manifest-backfill (slug=$slug section=built-prds format=fallback)"
    ;;
esac

# ---- step 6: one commit, exactly these three paths ---------------------
# `git mv` already staged BOTH halves of the rename (delete $prd_rel, add
# $built_rel) directly in the index — only the manifest edit (a plain
# file write, not a git op) still needs an explicit `git add`. But the
# commit's OWN pathspec must still name all three: `git commit --
# <pathspec>` only carries through index changes matching that pathspec,
# and omitting $prd_rel here once left its already-staged deletion out of
# the commit entirely — HEAD kept tracking the PRD at its build-queue/
# location even though `git mv` had "moved" it (found via smoke-testing
# this script against a real fixture before writing the selftest;
# `git add -- "$prd_rel"` itself then fails outright, since the path no
# longer exists on disk for plain `git add` to look at).
git -C "$PRD_DIR" add -- "$manifest_rel" \
  || die "add: git add failed for $manifest_rel" 4
if git -C "$PRD_DIR" diff --cached --quiet -- "$prd_rel" "$built_rel" "$manifest_rel"; then
  die "commit: nothing staged after mv+header+manifest edit — aborting" 4
fi
commit_msg="archive: $slug shipped"
if [ -n "$manifest_backfill_format" ]; then
  commit_msg="$commit_msg"$'\n\n'"manifest-backfill: appended MANIFEST.md line for $slug (section=built-prds, format=$manifest_backfill_format)"
fi
git -C "$PRD_DIR" "${GIT_ID[@]}" commit -q -m "$commit_msg" -- "$prd_rel" "$built_rel" "$manifest_rel" \
  || die "commit: git commit failed" 4
commit_sha="$(git -C "$PRD_DIR" rev-parse HEAD)"
committed=true   # the write already landed atomically; disarm the revert

# ---- step 7/8: pull --rebase --autostash, then push --------------------
pushed=yes
if ! git -C "$PRD_DIR" pull --rebase --autostash -q 2>/tmp/archive-commit.pull.err; then
  log "pull --rebase --autostash failed after commit $commit_sha; leaving commit local, push pending"
  cat /tmp/archive-commit.pull.err >&2
  git -C "$PRD_DIR" rebase --abort 2>/dev/null || true
  pushed=pending
fi
if [ "$pushed" = yes ] && ! git -C "$PRD_DIR" push -q 2>/tmp/archive-commit.push.err; then
  log "push failed after commit $commit_sha; commit kept, push pending"
  cat /tmp/archive-commit.push.err >&2
  pushed=pending
fi

# ---- postcondition (requirement 1): only a push-verified-yes result is
# allowed to claim success — re-check the filesystem AND reachability
# from origin before trusting our own "pushed=yes" bookkeeping. This is
# the exact gap the PRD is named for: without this, a transient
# rebase/push race can report success while the commit never actually
# reached origin.
#
# `git pull --rebase` can REWRITE our own commit onto a new SHA when it
# replays it on top of a sibling's commit that landed on origin first —
# $commit_sha (captured right after our own `git commit`, before the
# rebase) can therefore point at a SHA that no longer exists on any
# branch at all, which would make an honest, fully-landed archive look
# like a postcondition failure. Re-resolve it to whatever commit now
# actually carries $built_rel (same technique the pending-push-finish
# branch above uses) before checking reachability.
if [ "$pushed" = yes ]; then
  resolved_sha="$(git -C "$PRD_DIR" log -1 --format=%H -- "$built_rel" 2>/dev/null)"
  [ -n "$resolved_sha" ] && commit_sha="$resolved_sha"
  if [ ! -f "$PRD_DIR/$built_rel" ] || [ -f "$prd_path" ] || ! commit_reachable "$commit_sha"; then
    die "postcondition-failed: pushed=yes for $commit_sha but built-prds/$slug.md presence, build-queue absence, or origin/$(current_branch) reachability doesn't hold for $slug — treat as NOT archived" 8
  fi
fi

printf 'archive-commit %s commit=%s pushed=%s lock_wait=%s\n' "$slug" "$commit_sha" "$pushed" "$lock_wait_secs"
[ "$pushed" = yes ] || exit 6
