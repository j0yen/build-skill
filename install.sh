#!/usr/bin/env bash
# install.sh — install the build Claude Code skill.
#
# Two modes:
#   1. Repo-local: invoked as `./install.sh` from a checkout of
#      j0yen/build-skill. Symlinks ~/.claude/skills/build/ to this
#      script's parent dir.
#   2. Curl-piped: invoked as `curl ... | bash`. No checkout exists;
#      script self-clones the repo into ~/.local/share/build-skill/,
#      then runs mode 1 against that clone.
#
# state/ inside the skill is runtime state and stays git-ignored;
# install.sh rescues any existing state/ across re-installs.

set -euo pipefail

TARGET="$HOME/.claude/skills/build"

# --- Mode detection ---------------------------------------------------
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=""
if [ -f "$SCRIPT_PATH" ]; then
  SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)
fi

if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/SKILL.md" ]; then
  # Mode 2: curl|bash. Self-clone.
  echo "→ no local checkout detected; self-cloning j0yen/build-skill..."
  command -v git >/dev/null 2>&1 || { echo "fatal: git not found"; exit 1; }

  CLONE_ROOT="${BUILD_SKILL_CLONE_ROOT:-$HOME/.local/share/build-skill}"
  mkdir -p "$(dirname "$CLONE_ROOT")"

  if [ -d "$CLONE_ROOT/.git" ]; then
    echo "→ existing clone at $CLONE_ROOT — refreshing"
    git -C "$CLONE_ROOT" fetch --depth 1 origin main
    git -C "$CLONE_ROOT" reset --hard origin/main
  else
    echo "→ clone into $CLONE_ROOT"
    git clone --depth 1 https://github.com/j0yen/build-skill.git "$CLONE_ROOT"
  fi

  SCRIPT_DIR="$CLONE_ROOT"
fi

# --- Mode 1: symlink the skill into ~/.claude/skills/ ----------------

# Rescue existing state/ (manifest, budget, etc.) before relinking.
RESCUE_STATE=""
if [ -d "$TARGET/state" ] && [ ! -L "$TARGET" ]; then
  RESCUE_STATE=$(mktemp -d)
  cp -a "$TARGET/state/." "$RESCUE_STATE/"
  echo "→ rescued existing state → $RESCUE_STATE"
fi

# If the target is a real directory (not a symlink), back it up before linking.
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  BACKUP="$TARGET.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  echo "→ backing up existing $TARGET → $BACKUP"
  mv "$TARGET" "$BACKUP"
fi

# Remove a stale or wrong-target symlink.
if [ -L "$TARGET" ]; then
  rm "$TARGET"
fi

mkdir -p "$(dirname "$TARGET")"
ln -s "$SCRIPT_DIR" "$TARGET"
echo "→ symlinked $TARGET → $SCRIPT_DIR"

# Restore rescued state/ inside the new symlink target.
if [ -n "$RESCUE_STATE" ]; then
  mkdir -p "$SCRIPT_DIR/state"
  cp -a "$RESCUE_STATE/." "$SCRIPT_DIR/state/"
  rm -rf "$RESCUE_STATE"
  echo "→ restored state/ into $SCRIPT_DIR/state/"
fi

echo "✓ /build skill installed."
echo
echo "The skill is meant to run on a 5-min cadence via systemd-user timer."
echo "Timer unit installation is NOT done by this script — see the README."
