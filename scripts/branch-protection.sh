#!/usr/bin/env bash
# branch-protection.sh — turn on GitHub's required-status-check protection
# for a repo's main branch (PRD-build-main-push-gate requirement 6).
#
# main-push-gate.sh and the pre-push hook are the LOCAL half of this PRD —
# both are bypassable (MAIN_PUSH_GATE_BYPASS=1, or simply pushing from a
# checkout that never got the hook installed). This is the belt: even a
# red head that slips past both local checks cannot become `main` if
# GitHub itself refuses it.
#
# Usage:
#   branch-protection.sh enable <repo> [--check <name>]...
#   branch-protection.sh status <repo>
#
#   <repo>    A bare fleet slug (resolved against ~/wintermute/<repo>,
#             same convention as main-push-gate.sh/ci-status.sh) or an
#             absolute path to a local clone -- needed to read the repo's
#             own `.github/workflows/*.yml` when `--check` names a
#             WORKFLOW rather than a job.
#   --check   May be a job/context name (used as-is) or the `name:` field
#             of a workflow in `.github/workflows/*.yml` (resolved to that
#             workflow's TERMINAL job names -- every job nothing else
#             `needs:`, since GitHub only reports success on a job once
#             its own `needs:` have succeeded, requiring the terminal jobs
#             transitively requires the whole workflow; PRD's "require the
#               FULL CI workflow" instruction). Repeatable; when omitted,
#             every terminal job of every workflow file is required.
#
# Enable: `gh api -X PUT repos/j0yen/<repo>/branches/main/protection` with
# `strict: false` (a required check need not be re-run against the latest
# main after other pushes -- Requirements say nothing about staleness),
# no required PR reviews, admins enforced (`enforce_admins: true` --
# otherwise the loop's own GitHub identity, which very likely has admin,
# would sail past the requirement it just set).
#
# Status: prints the current required-check contexts, or "not protected".
#
# push-via-branch discovery (Technical considerations / AC6 -- "the PRD's
# weakest link, tested first"): classic branch protection's required
# status checks gate MERGES, not direct pushes -- a user/token with push
# access can push straight to a protected branch with no check having run
# at all, unless the branch also restricts who can push. `enable` records
# what protection it actually configured to
# state/branch-protection.json; whether direct pushes are in fact refused
# is verified LIVE, once, by attempting one (see this PRD's own journal
# and AC6/AC7 for that evidence) -- `enable` cannot determine this itself
# without pushing something, so it does not claim to.
#
# Exit: 0 ok | 2 usage | 3 gh not found/unauthenticated | 4 repo/workflow
#       not found locally (only relevant when --check names a workflow,
#       not a literal context) | 5 gh api call failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
OWNER="${BRANCH_PROTECTION_OWNER:-j0yen}"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"

usage() {
  echo "usage: branch-protection.sh enable <repo> [--check <name>]..." >&2
  echo "       branch-protection.sh status <repo>" >&2
  echo "       branch-protection.sh push <repo> <slug> [--base <branch>]" >&2
  echo "       branch-protection.sh landing-check <repo> <slug>" >&2
  echo "       branch-protection.sh pr-checks <repo> <slug>" >&2
  echo "       branch-protection.sh sync <repo>" >&2
}

die() { local rc="$1"; shift; echo "branch-protection: $*" >&2; exit "$rc"; }

command -v gh >/dev/null 2>&1 || die 3 "gh CLI not found on \$PATH"
gh auth status >/dev/null 2>&1 || die 3 "gh not authenticated (gh auth status failed)"

resolve_repo_dir() {
  local repo_arg="$1"
  if [ -d "$repo_arg/.git" ] || git -C "$repo_arg" rev-parse --git-dir >/dev/null 2>&1; then
    (cd "$repo_arg" && pwd); return 0
  fi
  if [ -d "$HOME/wintermute/$repo_arg" ]; then
    echo "$HOME/wintermute/$repo_arg"; return 0
  fi
  return 1
}

# resolve_checks <repo_dir> <name>... -> prints one resolved context name
# per line. A name matching a workflow's `name:` field expands to that
# workflow's terminal jobs (best-effort regex parse -- no PyYAML
# dependency, workflow files are a fixed, simple indentation shape); any
# other name passes through unchanged as a literal context.
resolve_checks() {
  local repo_dir="$1"; shift
  python3 - "$repo_dir" "$@" <<'PY'
import re, sys, glob, os

repo_dir = sys.argv[1]
names = sys.argv[2:]

wf_dir = os.path.join(repo_dir, ".github", "workflows")
workflows = {}  # workflow name -> (jobs list, needs map)
for path in glob.glob(os.path.join(wf_dir, "*.yml")) + glob.glob(os.path.join(wf_dir, "*.yaml")):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r'(?m)^name:\s*(.+?)\s*$', text)
    wf_name = m.group(1).strip() if m else os.path.basename(path)

    jm = re.search(r'(?m)^jobs:\s*$', text)
    if not jm:
        continue
    body = text[jm.end():]
    job_starts = [(m.start(), m.group(1)) for m in re.finditer(r'(?m)^  ([A-Za-z0-9_.-]+):\s*$', body)]
    jobs = [name for _, name in job_starts]
    needs_map = {j: set() for j in jobs}
    # GitHub's required-status-check `contexts` match the CHECK RUN name,
    # which for a GitHub Actions job is its `name:` display field when the
    # job sets one -- NOT the YAML job key (mcphost: job key `gate` posts
    # its check as "static analysis + core suites"; a required context of
    # literal `gate` never matches, leaving the PR permanently BLOCKED even
    # once that job is green -- the exact failure this mapping exists to
    # avoid, caught live on this PRD's own AC7 landing). A job whose `name:`
    # is templated (`${{ matrix.* }}`, e.g. the `sandbox` matrix job here)
    # is never itself terminal in this repo's shape, so the untemplated
    # display name is only ever needed for non-matrix jobs -- falls back to
    # the job key when no `name:` is set at all.
    display_name = {}
    for i, (start, jname) in enumerate(job_starts):
        end = job_starts[i + 1][0] if i + 1 < len(job_starts) else len(body)
        chunk = body[start:end]
        dn = re.search(r'(?m)^[ \t]+name:[ \t]*(\S.*)$', chunk)
        display_name[jname] = dn.group(1).strip().strip('"\'') if dn else jname
    for i, (start, jname) in enumerate(job_starts):
        end = job_starts[i + 1][0] if i + 1 < len(job_starts) else len(body)
        chunk = body[start:end]
        # Scalar/flow form on the SAME line as `needs:` (`needs: build` or
        # `needs: [a, b]`) -- [ \t]* (not \s*) so this never crosses a
        # newline into the block-list form below.
        nm = re.search(r'(?m)^[ \t]+needs:[ \t]*(\S.*)$', chunk)
        if nm:
            val = nm.group(1).strip()
            if val.startswith('['):
                needs_map[jname] |= {n.strip().strip('"\'') for n in val.strip('[]').split(',') if n.strip()}
            elif val:
                needs_map[jname].add(val.strip('"\''))
        else:
            # Block-list form: `needs:` alone on its line, then `  - a`.
            nm2 = re.search(r'(?m)^[ \t]+needs:[ \t]*\n((?:[ \t]+-[ \t]*.+\n?)+)', chunk)
            if nm2:
                for line in nm2.group(1).splitlines():
                    v = line.strip().lstrip('-').strip().strip('"\'')
                    if v:
                        needs_map[jname].add(v)
    needed_by_someone = set()
    for j, needs in needs_map.items():
        needed_by_someone |= needs
    terminal = [display_name[j] for j in jobs if j not in needed_by_someone]
    workflows[wf_name] = terminal

if not names:
    # No --check given: require every workflow's terminal jobs (the
    # generic "protect everything CI declares" default).
    for terminal in workflows.values():
        for j in terminal:
            print(j)
else:
    for name in names:
        if name in workflows:
            for j in workflows[name]:
                print(j)
        else:
            print(name)
PY
}

cmd_enable() {
  local repo_arg=""
  local -a checks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) checks+=("${2:?branch-protection: --check needs a value}"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) [ -z "$repo_arg" ] && repo_arg="$1" || { echo "branch-protection: too many arguments" >&2; usage; exit 2; }; shift ;;
    esac
  done
  [ -n "$repo_arg" ] || { usage; exit 2; }

  local repo_dir; repo_dir="$(resolve_repo_dir "$repo_arg")" || die 4 "repo not found locally: $repo_arg"
  local repo_slug; repo_slug="$(basename "$repo_dir")"

  local -a resolved=()
  if [ "${#checks[@]}" -eq 0 ]; then
    mapfile -t resolved < <(resolve_checks "$repo_dir")
  else
    mapfile -t resolved < <(resolve_checks "$repo_dir" "${checks[@]}")
  fi
  [ "${#resolved[@]}" -gt 0 ] || die 4 "no jobs/contexts resolved for $repo_arg (checked ${checks[*]:-<all workflows>})"

  local contexts_json; contexts_json="$(printf '%s\n' "${resolved[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

  local payload
  payload="$(python3 -c "
import json
print(json.dumps({
    'required_status_checks': {'strict': False, 'contexts': $contexts_json},
    'enforce_admins': True,
    'required_pull_request_reviews': None,
    'restrictions': None,
}))
")"

  echo "branch-protection: enabling on $OWNER/$repo_slug main, required contexts: ${resolved[*]}"
  if ! printf '%s' "$payload" | gh api -X PUT "repos/$OWNER/$repo_slug/branches/main/protection" --input - >/tmp/branch-protection.$$.out 2>&1; then
    cat /tmp/branch-protection.$$.out >&2
    rm -f "/tmp/branch-protection.$$.out"
    die 5 "gh api PUT failed for $OWNER/$repo_slug"
  fi
  rm -f "/tmp/branch-protection.$$.out"

  mkdir -p "$STATE_DIR"
  local state_file="$STATE_DIR/branch-protection.json"
  python3 -c "
import json, os, sys
state_file = sys.argv[1]
repo = sys.argv[2]
contexts = json.loads(sys.argv[3])
try:
    with open(state_file, encoding='utf-8') as fh:
        state = json.load(fh)
except (OSError, json.JSONDecodeError):
    state = {}
existing = state.get(repo, {})
existing.update({'owner': sys.argv[4], 'required_contexts': contexts, 'enforce_admins': True})
state[repo] = existing
tmp = state_file + '.tmp'
with open(tmp, 'w', encoding='utf-8') as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
os.replace(tmp, state_file)
" "$state_file" "$repo_slug" "$contexts_json" "$OWNER"

  echo "branch-protection: enabled — $state_file updated"
}

cmd_status() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; exit 2; }
  local repo_dir; repo_dir="$(resolve_repo_dir "$repo_arg")" || die 4 "repo not found locally: $repo_arg"
  local repo_slug; repo_slug="$(basename "$repo_dir")"

  local out rc
  out="$(gh api "repos/$OWNER/$repo_slug/branches/main/protection" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -q "Branch not protected"; then
      echo "branch-protection: $OWNER/$repo_slug main — not protected"
      exit 0
    fi
    die 5 "gh api GET failed for $OWNER/$repo_slug: $out"
  fi
  printf '%s' "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rsc = d.get('required_status_checks') or {}
contexts = rsc.get('contexts', [])
checks = rsc.get('checks', [])
names = contexts or [c.get('context') for c in checks]
print('branch-protection: $OWNER/$repo_slug main — protected')
print('  strict:', rsc.get('strict'))
print('  required contexts:', ', '.join(names) if names else '(none)')
print('  enforce_admins:', (d.get('enforce_admins') or {}).get('enabled'))
"

  local state_file="$STATE_DIR/branch-protection.json"
  if [ -f "$state_file" ]; then
    python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        state = json.load(fh)
except (OSError, json.JSONDecodeError):
    state = {}
rec = state.get(sys.argv[2])
if rec and 'push_via_branch' in rec:
    print('  push_via_branch:', rec['push_via_branch'])
" "$state_file" "$repo_slug"
  fi

  # PRD-build-main-push-gate-pr-path requirement 11 (P2, AC 'status
  # subcommand'): the landing record, if any, and the last `main-synced`
  # line for this repo -- so an operator running `status` sees a pending
  # PR-path landing without also having to know to go read
  # state/landings/ or grep the journal by hand.
  local landings_dir="$STATE_DIR/landings/$repo_slug"
  if [ -d "$landings_dir" ]; then
    local f
    for f in "$landings_dir"/*.json; do
      [ -f "$f" ] || continue
      python3 -c "
import json, sys
slug = sys.argv[2]
try:
    d = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    d = {}
print(f\"  landing record ({slug}): pr={d.get('pr_url','?')} head={d.get('head_sha','?')} armed_at={d.get('armed_at','?')}\")
" "$f" "$(basename "$f" .json)"
    done
  fi

  # Last `main-synced` line for this repo, most recent match across the
  # journal (today's file first, falling back across older files --
  # `sync_log`'s own `journal_line` writes to journal_root()/<date>.md).
  local jroot; jroot="$(journal_root)"
  if [ -d "$jroot" ]; then
    local last_sync
    last_sync="$(grep -h "  $repo_slug  main-synced " "$jroot"/*.md 2>/dev/null | tail -1)"
    if [ -n "$last_sync" ]; then
      echo "  last main-synced: $last_sync"
    fi
  fi
}

# push_via_branch_for is defined in lib/push-via-branch.sh (shared with
# gate-then-land.sh and main-push-gate.sh — PRD-build-main-push-gate-pr-path).

# cmd_push — AC7 / Technical considerations: the one command SKILL.md's
# push steps call regardless of whether a repo's main is protected.
#   branch-protection.sh push <repo> <slug> [--base <branch>]
# <repo>'s CURRENT HEAD (the commit already made ready to ship — bump,
# intent-card refresh, whatever the caller already committed) is what
# gets published:
#   push_via_branch=false (default, unset): plain `git push origin
#     HEAD:<base>` (same as the old direct wm-push behaviour).
#   push_via_branch=true: push HEAD to `refs/heads/loop/<slug>`, open (or
#     reuse) a PR against <base> via `gh pr create`, and arm
#     `gh pr merge --auto --squash` -- main only advances once that PR's
#     required checks go green (AC7). Prints the PR URL on stdout; the
#     merge itself happens asynchronously (GitHub Actions + auto-merge),
#     so this returns as soon as the PR/auto-merge is armed, not once
#     merged -- same "fire the mechanism, don't block the tick on CI wall
#     time" shape as `gate-launch.sh --wait` vs its no-wait mode.
cmd_push() {
  local repo_arg="${1:-}" slug="${2:-}" base="main"
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:?branch-protection: --base needs a value}"; shift 2 ;;
      *) echo "branch-protection: push: unexpected arg $1" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$repo_arg" ] && [ -n "$slug" ] || { usage; exit 2; }

  local repo_dir; repo_dir="$(resolve_repo_dir "$repo_arg")" || die 4 "repo not found locally: $repo_arg"
  local repo_slug; repo_slug="$(basename "$repo_dir")"
  local via_branch; via_branch="$(push_via_branch_for "$repo_slug")"

  if [ "$via_branch" != "true" ]; then
    git -C "$repo_dir" push origin "HEAD:$base" || die 5 "direct push to $base failed for $repo_slug"
    echo "branch-protection: pushed directly to $repo_slug $base"
    exit 0
  fi

  local head_sha; head_sha="$(git -C "$repo_dir" rev-parse HEAD)"
  local branch="loop/$slug"
  git -C "$repo_dir" branch -f "$branch" HEAD
  git -C "$repo_dir" push origin "$branch" || die 5 "push of $branch failed for $repo_slug"

  local pr_url
  pr_url="$(gh pr list --repo "$OWNER/$repo_slug" --head "$branch" --state open --json url --jq '.[0].url' 2>/dev/null)"
  if [ -z "$pr_url" ]; then
    pr_url="$(cd "$repo_dir" && gh pr create --title "loop: $slug" \
      --body "Automated loop landing for $slug (push-via-branch: $repo_slug main is protected, direct pushes are refused — PRD-build-main-push-gate AC6/AC7)." \
      --base "$base" --head "$branch" 2>&1)" || die 5 "gh pr create failed for $repo_slug/$branch: $pr_url"
  fi
  echo "branch-protection: PR $pr_url"

  local pr_number; pr_number="$(printf '%s' "$pr_url" | grep -oE '[0-9]+$')"
  gh pr merge "$pr_number" --repo "$OWNER/$repo_slug" --auto --squash \
    || die 5 "gh pr merge --auto failed for $OWNER/$repo_slug#$pr_number (is auto-merge enabled on the repo? gh repo edit --enable-auto-merge)"
  echo "branch-protection: auto-merge armed for $OWNER/$repo_slug#$pr_number — main advances once required checks pass"

  # requirement 1 / AC1, AC13 (P0/P1): record the landing so the tick can
  # resume it (landing-check/sync, or a later tick after this one exits).
  # Idempotent across ticks (AC13) — an existing record for this slug is
  # REFRESHED (armed_at bumped, pr fields kept in sync with the PR `gh pr
  # list`/`create` above just reused or opened), never duplicated: there is
  # exactly one file per <repo>/<slug>, so "duplicated" here means never
  # writing a second pr_number for the same slug, which this single
  # write-the-whole-record-in-place approach can't do by construction.
  local record; record="$(landing_record_path "$repo_slug" "$slug")"
  mkdir -p "$(dirname "$record")"
  local armed_at; armed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 -c "
import json, sys
path, pr_url, pr_number, head_sha, armed_at = sys.argv[1:6]
with open(path, 'w', encoding='utf-8') as fh:
    json.dump({
        'pr_url': pr_url,
        'pr_number': int(pr_number),
        'head_sha': head_sha,
        'armed_at': armed_at,
    }, fh, indent=2)
    fh.write('\n')
" "$record" "$pr_url" "$pr_number" "$head_sha" "$armed_at"
}

# landing_record_path is defined in lib/push-via-branch.sh. Written by
# cmd_push below once it has opened/reused a PR and armed auto-merge;
# read here by `landing-check` and consumed by `sync` once merged.

# cmd_landing_check — requirement 2 / AC3: reads the landing record for
# <repo>/<slug>, makes exactly ONE `gh pr view` call, and reduces the PR's
# state + its required contexts' statusCheckRollup entries to one of:
#   merged <sha>   exit 0   PR MERGED, every required context SUCCESS
#   pending        exit 3   PR open (or merged with unresolved contexts —
#                           should not happen under real branch protection,
#                           treated conservatively as still-pending), any
#                           required context not yet COMPLETED/SUCCESS
#   red <check>    exit 4   any required context completed non-success
#   closed         exit 5   PR CLOSED, unmerged
# `red` outranks `closed` (a red-then-closed PR is reported as red, naming
# the failing check, not a bare "closed"); `merged` requires every required
# context SUCCESS -- a MERGED state with an unresolved/failing required
# context is never reported as `merged` (branch protection should make
# that state unreachable, but this call never claims a merge it cannot
# also vouch the required checks for).
cmd_landing_check() {
  local repo_arg="${1:-}" slug="${2:-}"
  [ -n "$repo_arg" ] && [ -n "$slug" ] || { usage; exit 2; }
  local repo_dir; repo_dir="$(resolve_repo_dir "$repo_arg")" || die 4 "repo not found locally: $repo_arg"
  local repo_slug; repo_slug="$(basename "$repo_dir")"
  local record; record="$(landing_record_path "$repo_slug" "$slug")"
  [ -f "$record" ] || die 4 "no landing record at $record"

  local pr_number
  pr_number="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    d = {}
print(d.get('pr_number') or '')
" "$record")"
  [ -n "$pr_number" ] || die 4 "landing record $record has no pr_number"

  local required_json="[]" state_file="$STATE_DIR/branch-protection.json"
  if [ -f "$state_file" ]; then
    required_json="$(python3 -c "
import json, sys
try:
    state = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    state = {}
rec = state.get(sys.argv[2]) or {}
print(json.dumps(rec.get('required_contexts', [])))
" "$state_file" "$repo_slug")"
  fi

  local pr_json rc
  pr_json="$(gh pr view "$pr_number" --repo "$OWNER/$repo_slug" --json state,mergeCommit,statusCheckRollup 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || die 5 "gh pr view failed for $OWNER/$repo_slug#$pr_number: $pr_json"

  python3 - "$pr_json" "$required_json" "$record" <<'PY'
import json, sys

pr = json.loads(sys.argv[1])
required = list(dict.fromkeys(json.loads(sys.argv[2])))  # de-dup, keep order
record_path = sys.argv[3]
state = pr.get("state")
merge_sha = (pr.get("mergeCommit") or {}).get("oid")
rollup = pr.get("statusCheckRollup") or []

# Reduce each reported context/check to "success" | "pending" | "red" --
# later entries win (a rerun's own final conclusion, not its first attempt).
by_name = {}
for item in rollup:
    name = item.get("context") or item.get("name")
    if not name:
        continue
    if "conclusion" in item or "status" in item:
        # Checks API shape (GitHub Actions job/check run).
        verdict = (
            "pending" if item.get("status") != "COMPLETED"
            else "success" if item.get("conclusion") == "SUCCESS"
            else "red"
        )
    else:
        # Legacy Status API shape.
        legacy = (item.get("state") or "").upper()
        verdict = "success" if legacy == "SUCCESS" else "pending" if legacy in ("", "PENDING") else "red"
    by_name[name] = verdict

if not required:
    # No branch-protection.json entry for this repo -- fall back to
    # whatever the rollup itself reported (should not occur for a
    # push_via_branch=true repo, which `enable` always records).
    required = list(by_name.keys())

red = [n for n in required if by_name.get(n) == "red"]
unresolved = [n for n in required if by_name.get(n, "pending") != "success"]

if red:
    print(f"red {red[0]}")
    sys.exit(4)
if state == "MERGED" and merge_sha and not unresolved:
    # PRD-build-main-verdict-pinned-to-landing R1: persist merge_sha into
    # the landing record itself, not just this call's stdout -- a later
    # re-verify/archive step (possibly a different process, possibly after
    # more PRDs have landed and moved HEAD) needs S's merge sha M from the
    # record on disk, not from a `landing-check` stdout line nobody kept.
    # Idempotent (same field, same value on every re-run) and best-effort:
    # a write failure here never turns a real "merged" verdict into a
    # failure -- the caller already has merge_sha on stdout either way.
    try:
        with open(record_path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, json.JSONDecodeError):
        rec = {}
    if rec.get("merge_sha") != merge_sha:
        rec["merge_sha"] = merge_sha
        tmp_path = record_path + ".tmp"
        try:
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(rec, fh, indent=2)
                fh.write("\n")
            import os
            os.replace(tmp_path, record_path)
        except OSError:
            pass
    print(f"merged {merge_sha}")
    sys.exit(0)
if state == "CLOSED":
    print("closed")
    sys.exit(5)
print("pending")
sys.exit(3)
PY
  exit $?
}

# cmd_pr_checks — PRD-build-main-push-gate-pr-path requirement 4 (P0,
# AC6): the main-scope `ci-checks` producer (extend-gate.sh) for a
# push_via_branch=true repo needs the SAME one `gh pr view` data
# `landing-check` reads, but as a full per-context breakdown (a receipt
# needs "one entry per required context with its conclusion", not
# landing-check's single collapsed verdict) — this is that data, in the
# shape extend-gate.sh assembles its `autobuilder.ci_checks_receipt.v1`
# from, without extend-gate.sh (a general-purpose gate script, not a
# GitHub API client) making its own `gh pr view` call or re-deriving the
# required-contexts reduction a second time.
#   branch-protection.sh pr-checks <repo> <slug>
# Prints one JSON object on stdout:
#   {"pr_number": N, "state": "OPEN"|"MERGED"|"CLOSED",
#    "merge_sha": "<oid>"|"", "contexts": [{"name": "...",
#    "conclusion": "SUCCESS"|"PENDING"|"FAILURE"}, ...]}
# Exit: 0 ok | 2 usage | 4 no landing record / no pr_number | 5 gh call failed.
cmd_pr_checks() {
  local repo_arg="${1:-}" slug="${2:-}"
  [ -n "$repo_arg" ] && [ -n "$slug" ] || { usage; exit 2; }
  local repo_dir; repo_dir="$(resolve_repo_dir "$repo_arg")" || die 4 "repo not found locally: $repo_arg"
  local repo_slug; repo_slug="$(basename "$repo_dir")"
  local record; record="$(landing_record_path "$repo_slug" "$slug")"
  [ -f "$record" ] || die 4 "no landing record at $record"

  local pr_number
  pr_number="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    d = {}
print(d.get('pr_number') or '')
" "$record")"
  [ -n "$pr_number" ] || die 4 "landing record $record has no pr_number"

  local required_json="[]" state_file="$STATE_DIR/branch-protection.json"
  if [ -f "$state_file" ]; then
    required_json="$(python3 -c "
import json, sys
try:
    state = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    state = {}
rec = state.get(sys.argv[2]) or {}
print(json.dumps(rec.get('required_contexts', [])))
" "$state_file" "$repo_slug")"
  fi

  local pr_json rc
  pr_json="$(gh pr view "$pr_number" --repo "$OWNER/$repo_slug" --json state,mergeCommit,statusCheckRollup 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || die 5 "gh pr view failed for $OWNER/$repo_slug#$pr_number: $pr_json"

  python3 - "$pr_number" "$pr_json" "$required_json" <<'PY'
import json, sys

pr_number = sys.argv[1]
pr = json.loads(sys.argv[2])
required = list(dict.fromkeys(json.loads(sys.argv[3])))
state = pr.get("state")
merge_sha = (pr.get("mergeCommit") or {}).get("oid") or ""
rollup = pr.get("statusCheckRollup") or []

by_name = {}
for item in rollup:
    name = item.get("context") or item.get("name")
    if not name:
        continue
    if "conclusion" in item or "status" in item:
        conclusion = (
            "PENDING" if item.get("status") != "COMPLETED"
            else "SUCCESS" if item.get("conclusion") == "SUCCESS"
            else "FAILURE"
        )
    else:
        legacy = (item.get("state") or "").upper()
        conclusion = "SUCCESS" if legacy == "SUCCESS" else "PENDING" if legacy in ("", "PENDING") else "FAILURE"
    by_name[name] = conclusion

if not required:
    required = list(by_name.keys())

contexts = [{"name": n, "conclusion": by_name.get(n, "PENDING")} for n in required]
print(json.dumps({"pr_number": int(pr_number), "state": state, "merge_sha": merge_sha, "contexts": contexts}))
PY
}

# cmd_sync — requirement 3 / AC4/AC5: fast-forward (or, when the merge
# produced a squash commit with the SAME tree as local main, re-point) local
# `main` to `origin/main` after a `landing-check merged <sha>` verdict.
# Never `--force`, never `reset --hard` -- a refusal leaves `main` byte-for-
# byte untouched and is always recoverable from `git reflog main`.
cmd_sync() {
  local repo_arg="${1:-}"
  [ -n "$repo_arg" ] || { usage; exit 2; }
  local repo_dir; repo_dir="$(resolve_repo_dir "$repo_arg")" || die 4 "repo not found locally: $repo_arg"
  local repo_slug; repo_slug="$(basename "$repo_dir")"

  git -C "$repo_dir" fetch origin main >/dev/null 2>&1 || true

  local cur_branch
  cur_branch="$(git -C "$repo_dir" symbolic-ref --short -q HEAD || true)"
  if [ "$cur_branch" != "main" ]; then
    sync_refuse "$repo_slug" "not-on-main"
    exit 6
  fi

  # Dirty TRACKED tree only -- untracked build artifacts never block a sync
  # (same convention as self-push.sh).
  if ! git -C "$repo_dir" diff --quiet -- || ! git -C "$repo_dir" diff --cached --quiet --; then
    sync_refuse "$repo_slug" "dirty"
    exit 6
  fi

  local old_sha new_sha
  old_sha="$(git -C "$repo_dir" rev-parse main)"
  new_sha="$(git -C "$repo_dir" rev-parse origin/main 2>/dev/null)" || die 4 "no origin/main ref for $repo_slug (fetch it first)"

  if [ "$old_sha" = "$new_sha" ]; then
    echo "branch-protection: $repo_slug main already synced at $new_sha"
    exit 0
  fi

  if git -C "$repo_dir" merge --ff-only origin/main >/dev/null 2>&1; then
    sync_log "$repo_slug" "$old_sha" "$new_sha" "ff-only"
    echo "branch-protection: $repo_slug main fast-forwarded $old_sha -> $new_sha"
    exit 0
  fi

  local old_tree new_tree
  old_tree="$(git -C "$repo_dir" rev-parse "main^{tree}")"
  new_tree="$(git -C "$repo_dir" rev-parse "origin/main^{tree}" 2>/dev/null)"
  if [ -n "$new_tree" ] && [ "$old_tree" = "$new_tree" ]; then
    # checkout -B moves the branch ref -- $old_sha stays reachable via
    # `git reflog main` (AC4), never lost, never `reset --hard`.
    git -C "$repo_dir" checkout -B main origin/main >/dev/null 2>&1 \
      || die 5 "checkout -B main origin/main failed for $repo_slug"
    sync_log "$repo_slug" "$old_sha" "$new_sha" "identical"
    echo "branch-protection: $repo_slug main synced (tree-identical) $old_sha -> $new_sha"
    exit 0
  fi

  sync_refuse "$repo_slug" "tree-diff"
  exit 6
}

sync_log() {
  local repo_slug="$1" old="$2" new="$3" tree="$4"
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  branch-protection  $repo_slug  main-synced old=$old new=$new tree=$tree"
}

sync_refuse() {
  local repo_slug="$1" reason="$2"
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  branch-protection  $repo_slug  main-sync-refused reason=$reason"
}

[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  enable)        cmd_enable "$@" ;;
  status)        cmd_status "$@" ;;
  push)          cmd_push "$@" ;;
  landing-check) cmd_landing_check "$@" ;;
  pr-checks)     cmd_pr_checks "$@" ;;
  sync)          cmd_sync "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
