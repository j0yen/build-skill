# lib/repo-slug.sh — shared repo-slug resolver.
#
# repo_slug_for_ci <repo-dir> -> basename of the REAL repo, not of $1 itself.
# Under --pinned-landing, $1 is a detached verify worktree (e.g.
# ~/.cache/build-worktrees/mcphost-mcphost-agent-wake-verify), so a plain
# `basename "$repo"` yields the worktree's own name instead of the repo
# slug that push_via_branch_for() and branch-protection.sh key on.
# `git rev-parse --git-common-dir` always points at the main repo's .git
# (a linked worktree's own .git is a file pointing there; a plain clone's
# IS the main repo, and git-common-dir there is the relative ".git" — made
# absolute against $1 before stripping the trailing /.git).
repo_slug_for_ci() {
  local repo="$1" gcd
  gcd="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || { basename "$repo"; return; }
  case "$gcd" in
    /*) : ;;
    *) gcd="$repo/$gcd" ;;
  esac
  basename "${gcd%/.git}"
}
