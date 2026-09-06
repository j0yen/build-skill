#!/usr/bin/env bash
# carbon-lane-install.sh — symlinks the carbon-lane systemd units
# (systemd/carbon/*) into ~/.config/systemd/user/, mirroring how RedBaron's
# proven set is versioned (PRD-build-second-lane-carbon P0 "Carbon units
# mirror RedBaron's proven set").
#
# This script only SYMLINKS unit files into place; it never enables,
# starts, or daemon-reloads anything ("Enabled state is carbon-local;
# nothing syncs unit files to other machines" — the PRD's migration note).
# A human runs `systemctl --user enable --now claude-build.path
# prd-sync.timer` (and a `daemon-reload` if replacing live units) as an
# explicit, separate, carbon-local step.
#
# Idempotent: re-running just re-points already-correct symlinks (no-op).
# Existing regular (non-symlink) units are backed up to
# <name>.bak.<ISO-ts> before being replaced, same convention as the
# RedBaron path-unit-overlap-exit0 install used.
#
# Usage:
#   carbon-lane-install.sh [--dry-run]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/systemd/carbon"
DEST="${CARBON_LANE_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

die() { echo "carbon-lane-install: $*" >&2; exit 1; }

[ -d "$SRC" ] || die "no such source dir: $SRC"
mkdir -p "$DEST" 2>/dev/null || true

ts() { date -u +%Y%m%dT%H%M%SZ; }

link_one() {
  local src="$1" name; name="$(basename "$src")"
  local dest="$DEST/$name"
  if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
    echo "unchanged: $name"
    return 0
  fi
  if [ "$DRY" -eq 1 ]; then
    echo "would-link: $name -> $src"
    return 0
  fi
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    cp -a "$dest" "$dest.bak.$(ts)"
    echo "backed-up: $name -> $name.bak.$(ts)"
  fi
  ln -sfn "$src" "$dest"
  echo "linked: $name -> $src"
}

link_dropin_dir() {
  local src_dir="$1" name; name="$(basename "$src_dir")"
  local dest_dir="$DEST/$name"
  mkdir -p "$dest_dir" 2>/dev/null || [ "$DRY" -eq 1 ] || true
  local f
  for f in "$src_dir"/*; do
    [ -f "$f" ] || continue
    local fname; fname="$(basename "$f")"
    local dest="$dest_dir/$fname"
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$f")" ]; then
      echo "unchanged: $name/$fname"
      continue
    fi
    if [ "$DRY" -eq 1 ]; then
      echo "would-link: $name/$fname -> $f"
      continue
    fi
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      cp -a "$dest" "$dest.bak.$(ts)"
      echo "backed-up: $name/$fname -> $name/$fname.bak.$(ts)"
    fi
    ln -sfn "$f" "$dest"
    echo "linked: $name/$fname -> $f"
  done
}

for f in "$SRC"/*; do
  [ -e "$f" ] || continue
  if [ -d "$f" ]; then
    link_dropin_dir "$f"
  else
    link_one "$f"
  fi
done

if [ "$DRY" -eq 0 ]; then
  echo "note: units are linked but NOT enabled. Run explicitly on carbon:"
  echo "  systemctl --user daemon-reload"
  echo "  systemctl --user enable --now claude-build.path prd-sync.timer"
fi
