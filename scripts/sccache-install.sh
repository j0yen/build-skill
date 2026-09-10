#!/usr/bin/env bash
# sccache-install.sh — symlinks systemd/sccache-server.service into
# ~/.config/systemd/user/ (PRD-build-gate-wall-clock requirement 1),
# mirroring carbon-lane-install.sh's convention exactly.
#
# This script only SYMLINKS the unit into place; it never daemon-reloads,
# enables, or starts it. A human runs the printed `systemctl --user
# daemon-reload && enable --now sccache-server.service` as an explicit,
# separate step — deliberately, so this install can land mid-tick without
# ever swapping the live sccache server out from under cargo processes
# some other branch agent may have in flight on this same box right now.
#
# Idempotent: re-running just re-points an already-correct symlink
# (no-op). An existing regular (non-symlink) unit is backed up to
# sccache-server.service.bak.<ISO-ts> before being replaced.
#
# Usage:
#   sccache-install.sh [--dry-run]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/systemd/sccache-server.service"
DEST_DIR="${SCCACHE_INSTALL_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

die() { echo "sccache-install: $*" >&2; exit 1; }

[ -f "$SRC" ] || die "no such source unit: $SRC"
mkdir -p "$DEST_DIR" 2>/dev/null || true

ts() { date -u +%Y%m%dT%H%M%SZ; }

dest="$DEST_DIR/sccache-server.service"
if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$SRC")" ]; then
  echo "unchanged: sccache-server.service"
elif [ "$DRY" -eq 1 ]; then
  echo "would-link: sccache-server.service -> $SRC"
else
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    cp -a "$dest" "$dest.bak.$(ts)"
    echo "backed-up: sccache-server.service -> sccache-server.service.bak.$(ts)"
  fi
  ln -sfn "$SRC" "$dest"
  echo "linked: sccache-server.service -> $SRC"
fi

if [ "$DRY" -eq 0 ]; then
  echo "note: unit is linked but NOT enabled or started. Run explicitly,"
  echo "when no cargo build depending on the current sccache server is in flight:"
  echo "  systemctl --user daemon-reload"
  echo "  systemctl --user enable --now sccache-server.service"
fi
