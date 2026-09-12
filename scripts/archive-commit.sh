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
#   5. flip its line in the checkout's own MANIFEST.md to `shipped`.
#   6. `git add` exactly those two paths, one commit `archive: <slug>
#      shipped`.
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
#   0   archived (or dry-run printed the plan)
#   2   usage error
#   3   not-queued (PRD missing from build-queue/) or receipt unresolved
#   4   dirty checkout for the touched paths, or a write step failed —
#       working tree for those paths restored
#   5   lock-timeout — no writes
#   6   commit landed but push is pending (network/rebase-conflict after
#       our own commit) — not a corrupt state, just an unfinished push
#
# Stdout on a successful (or push-pending) run:
#   archive-commit <slug> commit=<sha> pushed=<yes|pending> lock_wait=<s>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
JQ="${JQ:-/usr/bin/jq}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
BUILD_MANIFEST="${BUILD_MANIFEST:-$SKILL_DIR/state/manifest.json}"
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
# preserving whatever build_target/date tail it already has. Exit 1 (no
# write) if no such line is found.
update_manifest_md() {
  local f="$1" slug="$2"
  python3 - "$f" "$slug" <<'PYEOF'
import re, sys
f, slug = sys.argv[1], sys.argv[2]
name = f"PRD-{slug}.md"
with open(f) as fh:
    lines = fh.readlines()
pat = re.compile(r'^(-\s*' + re.escape(name) + r'\s+—\s+)([^·]+?)(\s*·.*)$')
changed = False
for i, ln in enumerate(lines):
    m = pat.match(ln.rstrip('\n'))
    if m:
        lines[i] = f"{m.group(1)}shipped{m.group(3)}\n"
        changed = True
        break
if not changed:
    sys.exit(1)
with open(f, 'w') as fh:
    fh.writelines(lines)
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

# ---- step 5: flip the MANIFEST.md line ---------------------------------
update_manifest_md "$manifest_md" "$slug" \
  || die "manifest: no MANIFEST.md line found for $slug under $PRD_DIR" 4

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
git -C "$PRD_DIR" "${GIT_ID[@]}" commit -q -m "archive: $slug shipped" -- "$prd_rel" "$built_rel" "$manifest_rel" \
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

printf 'archive-commit %s commit=%s pushed=%s lock_wait=%s\n' "$slug" "$commit_sha" "$pushed" "$lock_wait_secs"
[ "$pushed" = yes ] || exit 6
