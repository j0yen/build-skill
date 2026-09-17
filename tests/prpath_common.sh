#!/usr/bin/env bash
# tests/prpath_common.sh — shared fixture helpers for the
# prpath_ac*.sh selftests (PRD-build-main-push-gate-pr-path,
# test_prefix: prpath). Must be sourced, not executed.
set -uo pipefail

PRPATH_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRPATH_SCRIPTS="$(cd "$PRPATH_HERE/scripts" && pwd)"
PRPATH_BP="$PRPATH_SCRIPTS/branch-protection.sh"

prpath_fail=0
prpath_expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label ($cond)" >&2
    prpath_fail=1
  fi
}

# prpath_install_gh_stub <bindir> <mode> — writes a fake `gh` to
# <bindir>/gh (caller must put <bindir> first on $PATH) that:
#   - always answers `auth status` with exit 0 (branch-protection.sh's
#     top-of-file precondition check).
#   - answers `pr view <n> --repo <o>/<r> --json ...` from $PRPATH_GH_PR_JSON
#     (an env var the caller sets before invoking branch-protection.sh),
#     and appends one line to <bindir>/pr-view-calls.log per call so tests
#     can assert "exactly one gh call" (AC3).
#   - anything else exits 1 with a marker on stderr (never silently
#     no-ops an unexpected call).
#
# Also handles the three `gh` calls `branch-protection.sh push` makes (AC1/
# AC2/AC13 fixtures): `pr list` (existing-PR lookup — empty by default, so
# `push` takes the "open a new PR" branch), `pr create` (prints a PR URL),
# and `pr merge --auto --squash` (arms auto-merge). Each logs to its own
# <bindir>/pr-<verb>-calls.log so a test can assert call counts (AC13:
# exactly one open PR across two `push` calls for the same slug).
prpath_install_gh_stub() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "auth status") exit 0 ;;
esac
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "call" >> "$(dirname "$0")/pr-view-calls.log"
  # NOTE: deliberately not `${PRPATH_GH_PR_JSON:-{}}` -- a literal `{}`
  # inside a `${VAR:-word}` default confuses bash's own brace matching
  # (it terminates the expansion one `}` early, leaking a stray `}` into
  # the output) -- verified live while building this fixture.
  body="${PRPATH_GH_PR_JSON:-}"
  [ -n "$body" ] || body='{}'
  printf '%s' "$body"
  exit "${PRPATH_GH_PR_VIEW_RC:-0}"
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo "call" >> "$(dirname "$0")/pr-list-calls.log"
  # Empty by default: no open PR found for the branch, so `push` takes the
  # `gh pr create` branch below. Set PRPATH_GH_PR_LIST_URL to simulate an
  # already-open PR (the reuse/idempotent path, AC13).
  printf '%s' "${PRPATH_GH_PR_LIST_URL:-}"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "call" >> "$(dirname "$0")/pr-create-calls.log"
  printf '%s\n' "${PRPATH_GH_PR_CREATE_URL:-https://github.com/j0yen/fixture-repo/pull/1}"
  exit "${PRPATH_GH_PR_CREATE_RC:-0}"
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  echo "$3" >> "$(dirname "$0")/pr-merge-calls.log"
  exit "${PRPATH_GH_PR_MERGE_RC:-0}"
fi
echo "gh-stub: unexpected invocation: $*" >&2
exit 1
STUB
  chmod +x "$bindir/gh"
  : > "$bindir/pr-view-calls.log"
  : > "$bindir/pr-list-calls.log"
  : > "$bindir/pr-create-calls.log"
  : > "$bindir/pr-merge-calls.log"
}

# prpath_mk_repo <root> -> prints a bare "origin.git" + working clone
# "work" path, one commit deep, branch "main". A tiny real git repo is
# all landing-check/sync need (neither touches build content).
prpath_mk_repo() {
  local root="${1:?prpath_mk_repo: missing root}"
  local origin="$root/origin.git" work="$root/work"
  mkdir -p "$root"
  git init --bare -q -b main "$origin"
  git clone -q "$origin" "$work"
  (
    cd "$work"
    git config user.name "Fixture Bot"
    git config user.email "fixture@example.invalid"
    echo "one" > file.txt
    git add file.txt
    git commit -qm "initial"
    git push -q origin main
  )
  echo "$work"
}
