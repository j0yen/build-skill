#!/usr/bin/env bash
# self-push.sh — distribute build-skill self-modifications to the remote.
#
# The shell/config classify path (Phase 3/4) edits the build-skill's OWN
# files (scripts/*.sh, SKILL.md, .gitignore) in place and commits them to
# THIS repo. Unlike new-repo / rust-extend PRDs, those self-mods have no
# `wm-publish`/`wm-push` wrapper, so without this step they sit committed-
# but-unpushed and never reach other clones. Call this AFTER a self-
# modifying commit has landed to fast-forward the remote.
#
# Guards (refuse, never force): correct repo, expected remote, on the
# expected branch, no uncommitted *tracked* changes (untracked build
# artifacts are ignored), remote reachable, strictly fast-forward,
# >=1 commit ahead. Idempotent: a no-op (exit 0) when already in sync.
#
# Exit codes: 0 ok / nothing-to-push | 2 wrong repo/remote/branch
#             | 3 uncommitted tracked changes | 4 fetch failed
#             | 5 not fast-forward (diverged) | 6 push failed
set -uo pipefail

REPO="${BUILD_SKILL_REPO:-$HOME/.local/share/build-skill}"
BRANCH="${BUILD_SKILL_BRANCH:-main}"
# Accept either the canonical j0yen remote or a joeyen-atscale fork.
EXPECTED_REMOTE_RE='github\.com[:/](j0yen|joeyen-atscale)/build-skill(\.git)?$'

cd "$REPO" 2>/dev/null || { echo "self-push: repo not found at $REPO" >&2; exit 2; }

url="$(git remote get-url origin 2>/dev/null || true)"
# Redacted form for any log line — a token may be embedded as userinfo
# (https://<token>@github.com/...); never echo the raw credential.
safe_url="$(printf '%s' "$url" | sed -E 's#://[^@/]*@#://***@#')"
if ! printf '%s' "$url" | grep -qE "$EXPECTED_REMOTE_RE"; then
  echo "self-push: origin '$safe_url' is not the build-skill remote — refusing" >&2
  exit 2
fi

cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ "$cur" != "$BRANCH" ]; then
  echo "self-push: HEAD is '$cur', expected '$BRANCH' — refusing" >&2
  exit 2
fi

# Uncommitted TRACKED changes block the push (the self-mod must be a real
# commit first). Untracked files (build artifacts, logs) are intentionally
# ignored — they are never part of pushed history.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "self-push: uncommitted tracked changes — commit the self-mod first; refusing" >&2
  exit 3
fi

git fetch origin "$BRANCH" --quiet || { echo "self-push: fetch failed" >&2; exit 4; }

# left = commits on origin we lack (behind); right = local commits to push (ahead)
counts="$(git rev-list --left-right --count "origin/${BRANCH}...HEAD" 2>/dev/null || echo "")"
behind="$(printf '%s' "$counts" | awk '{print $1}')"
ahead="$(printf '%s' "$counts" | awk '{print $2}')"
[ -z "$behind" ] && behind=0
[ -z "$ahead" ] && ahead=0

if [ "$behind" -ne 0 ]; then
  echo "self-push: local is $behind behind origin/$BRANCH — not fast-forward; rebase manually; refusing" >&2
  exit 5
fi
if [ "$ahead" -eq 0 ]; then
  echo "self-push: already in sync (0 commits ahead) — nothing to push"
  exit 0
fi

if git push origin "$BRANCH"; then
  echo "self-push: pushed $ahead commit(s) to $safe_url"
  exit 0
fi
echo "self-push: push failed" >&2
exit 6
