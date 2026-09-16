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

usage() {
  echo "usage: branch-protection.sh enable <repo> [--check <name>]..." >&2
  echo "       branch-protection.sh status <repo>" >&2
  echo "       branch-protection.sh push <repo> <slug> [--base <branch>]" >&2
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
}

# push_via_branch_for <repo_slug> -> "true"/"false" (default "false" —
# never assume the branch-only path for a repo `enable` never ran against).
push_via_branch_for() {
  local repo_slug="$1" state_file="$STATE_DIR/branch-protection.json"
  [ -f "$state_file" ] || { echo false; return; }
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        state = json.load(fh)
except (OSError, json.JSONDecodeError):
    state = {}
rec = state.get(sys.argv[2]) or {}
print('true' if rec.get('push_via_branch') else 'false')
" "$state_file" "$repo_slug"
}

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
}

[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  enable) cmd_enable "$@" ;;
  status) cmd_status "$@" ;;
  push)   cmd_push "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
