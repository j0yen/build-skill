#!/usr/bin/env bash
# checkout-guard.sh — Pre-tick guard: ensure a build_into repo's primary checkout
# is on its default branch and clean between ticks.
#
# Usage:
#   checkout-guard.sh detect  <repo-path>
#   checkout-guard.sh restore <repo-path>
#
# Exit codes:
#   detect:
#     0  — always (advisory output only; see stdout for on-default / primary-off-default)
#   restore:
#     0  — on-default (no-op) or restored successfully
#     1  — wedged-needs-human (tracked modifications on off-default branch)
#     2  — usage / bad args
#
# Safety constraints (NEVER violated):
#   - NEVER deletes any file
#   - NEVER force-pushes or force-checkouts
#   - NEVER commits
#   - Only moves orphaned untracked files to a timestamped backup dir
#   - Only switches branch when primary is off-default AND no tracked modifications

set -uo pipefail

BACKUP_ROOT="${HOME}/.claude/scratch/checkout-guard"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

die() { echo "checkout-guard: error: $*" >&2; exit 2; }

# Resolve the default branch for a repo.
# Tries: git symbolic-ref refs/remotes/origin/HEAD → origin/main → strip prefix.
# Falls back: look for local branch named main, then master.
# Worst-case: returns "main".
default_branch() {
    local repo="$1"
    local sym
    sym=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$sym" ]]; then
        # e.g. "origin/main" → "main"
        echo "${sym#*/}"
        return
    fi

    # Try to infer from remote tracking branches
    local rb
    rb=$(git -C "$repo" branch -r 2>/dev/null | grep -E '^\s*origin/(main|master)$' | head -1 | xargs || true)
    if [[ -n "$rb" ]]; then
        echo "${rb#origin/}"
        return
    fi

    # Fallback: check local branches
    if git -C "$repo" rev-parse --verify main &>/dev/null; then
        echo "main"
    elif git -C "$repo" rev-parse --verify master &>/dev/null; then
        echo "master"
    else
        echo "main"
    fi
}

# Return the current branch name of the PRIMARY checkout (not a worktree).
# Returns empty string if in detached HEAD state.
current_branch() {
    local repo="$1"
    git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true
}

# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------

cmd_detect() {
    local repo="${1:-}"
    [[ -n "$repo" ]] || die "detect requires <repo-path>"
    [[ -d "$repo/.git" || -f "$repo/.git" ]] || die "not a git repo: $repo"

    local def cur
    def=$(default_branch "$repo")
    cur=$(current_branch "$repo")

    if [[ "$cur" == "$def" ]]; then
        echo "on-default $repo $cur"
    else
        echo "primary-off-default $repo ${cur:-DETACHED}"
    fi
    # Exit 0 in both cases — advisory output only
    return 0
}

cmd_restore() {
    local repo="${1:-}"
    [[ -n "$repo" ]] || die "restore requires <repo-path>"
    [[ -d "$repo/.git" || -f "$repo/.git" ]] || die "not a git repo: $repo"

    local def cur
    def=$(default_branch "$repo")
    cur=$(current_branch "$repo")

    # AC4: Already on default → no-op
    if [[ "$cur" == "$def" ]]; then
        # Also require clean (no tracked changes)
        local tracked_diff
        tracked_diff=$(git -C "$repo" status --porcelain 2>/dev/null | grep -v '^??' || true)
        if [[ -z "$tracked_diff" ]]; then
            echo "on-default $repo $cur"
            return 0
        fi
    fi

    # Off-default (or on-default but dirty with tracked changes — treat same)
    local status_lines
    status_lines=$(git -C "$repo" status --porcelain 2>/dev/null)

    # Classify: tracked modifications vs orphaned untracked
    local tracked_mods untracked_files
    tracked_mods=$(printf '%s\n' "$status_lines" | grep -v '^??' || true)
    untracked_files=$(printf '%s\n' "$status_lines" | grep '^??' | sed 's/^?? //' || true)

    # AC3: tracked modifications present → escalate, no mutation
    if [[ -n "$tracked_mods" ]]; then
        echo "wedged-needs-human $repo ${cur:-DETACHED}"
        return 1
    fi

    # Safe subset: only orphaned untracked files
    if [[ "$cur" == "$def" && -z "$untracked_files" ]]; then
        # Already clean on default — shouldn't reach here but be safe
        echo "on-default $repo $cur"
        return 0
    fi

    # Move untracked files to backup dir (reversible, never rm)
    local ts repo_slug backup_dir
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    repo_slug=$(basename "$(realpath "$repo")")
    backup_dir="${BACKUP_ROOT}/${repo_slug}-${ts}"

    if [[ -n "$untracked_files" ]]; then
        mkdir -p "$backup_dir"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local src="${repo}/${f}"
            local dst="${backup_dir}/${f}"
            # Preserve subdirectory structure in backup
            mkdir -p "$(dirname "$dst")"
            mv "$src" "$dst"
            echo "backup-moved $f → $backup_dir"
        done <<< "$untracked_files"
        echo "backup-dir $backup_dir"
    fi

    # Now switch to default branch (no --force; fails if there are any tracked changes)
    git -C "$repo" checkout "$def" 2>&1

    # Verify clean after switch
    local post_dirty
    post_dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
    if [[ -n "$post_dirty" ]]; then
        echo "restore-warning $repo still has dirty state after checkout:" >&2
        echo "$post_dirty" >&2
    fi

    echo "restored $repo"
    return 0
}

# --------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
    detect)  cmd_detect  "$@" ;;
    restore) cmd_restore "$@" ;;
    *)
        cat >&2 <<'EOF'
Usage: checkout-guard.sh detect  <repo-path>
       checkout-guard.sh restore <repo-path>
EOF
        exit 2
        ;;
esac
