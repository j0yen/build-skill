#!/usr/bin/env bash
# land-resolve-coder.sh — R4's default `$LAND_RESOLVE_CODER` target
# (PRD-build-land-conflict-resolver). land-resolve.sh's `try_coder_resolve`
# invokes this (or a caller's own override, e.g. a selftest stub) as:
#   land-resolve-coder.sh <repo> <slug> <file...>
# against a worktree mid-rebase, with <file...> still showing conflict
# markers (index stages 1/2/3 — base/ours/theirs; see land-resolve.sh's
# header note on rebase's inverted ours/theirs). Job: resolve the markers
# in place. This script's own exit code is only a first-pass signal — the
# caller (try_coder_resolve) is the one that actually verifies the result
# against the repo's tests before trusting it (R4: "tests pass" is the
# check, never the coder's self-report), so this script errs toward
# attempting a fix rather than declining, and a resolution that looks
# plausible but leaves tests red is caught one layer up, not here.
#
# Same invocation shape extend-gate.sh's reviewer-agent phase already
# uses for its own headless sonnet call (`claude -p ... --model sonnet
# --permission-mode bypassPermissions --output-format text`) — see that
# script's run_reviewer(). `9>&-` closes the caller's lock fd (if any)
# before spawning, same reason: a long-lived subprocess must never hold a
# flock the parent only meant to hold for a moment.
#
# Exit: 0 if the coder ran to completion (says nothing about whether the
# resolution is correct — that's try_coder_resolve's test-command check);
# non-zero on any invocation failure (missing `claude` binary, no PRD
# found for <slug>, the coder process itself exiting non-zero).
set -uo pipefail

repo="${1:?usage: land-resolve-coder.sh <repo> <slug> <file...>}"
slug="${2:?usage: land-resolve-coder.sh <repo> <slug> <file...>}"
shift 2
files=("$@")
[ "${#files[@]}" -gt 0 ] || { echo "land-resolve-coder: no files given" >&2; exit 2; }

command -v claude >/dev/null 2>&1 || { echo "land-resolve-coder: claude CLI not on \$PATH" >&2; exit 2; }

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
prd_path=""
for cand in "$PRD_DIR/build-queue/PRD-$slug.md" "$PRD_DIR/built-prds/PRD-$slug.md"; do
  [ -f "$cand" ] && { prd_path="$cand"; break; }
done

conflict_dump=""
for f in "${files[@]}"; do
  conflict_dump="$conflict_dump

--- $f ---
$(cat "$repo/$f" 2>/dev/null)"
done

prompt="You are resolving a git rebase conflict inside a mid-rebase worktree at $repo (slug: $slug). The following files still contain git conflict markers (<<<<<<<, =======, >>>>>>>). Resolve each conflict in place by editing the file directly under $repo — do not create new files, do not run any git commands (no add/commit/rebase --continue; the caller does that). Preserve the intent of BOTH sides where they do not truly conflict; where they do, prefer the change that keeps the code correct and the tests passing. After editing, no conflict markers should remain in any of these files.

Files:$conflict_dump"

if [ -n "$prd_path" ]; then
  prompt="$prompt

For reference, this land belongs to PRD $slug — its Acceptance Criteria (do not violate them while resolving):
$(cat "$prd_path")"
fi

( cd "$repo" && claude -p "$prompt" --model sonnet --permission-mode bypassPermissions --output-format text ) 9>&-
