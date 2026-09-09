#!/usr/bin/env bash
# install-hcloud.sh — pinned-version, sha256-checked install of the Hetzner
# Cloud CLI under ~/.local/bin (PRD-build-burst-lane-ccx53 requirement 2).
#
# gate-burst.sh precondition and burst-lane.sh's own precondition both
# require `hcloud` on PATH. Requirement 2 asked for a specific mechanism —
# "a release binary, pinned version, sha256 checked" — not just "hcloud
# happens to be present": the binary that was actually on this box (RedBaron,
# 2026-09-09) got there by hand, with no script anywhere in this repo able to
# reproduce, verify, or re-install it on a fresh host or after a bad update.
# This script closes that gap.
#
# What it does:
#   1. If ~/.local/bin/hcloud already exists AND its sha256 matches the
#      pinned $HCLOUD_SHA256 below, exit 0 "already-installed" — no network
#      call, no re-download (idempotent).
#   2. Otherwise, downloads hcloud-linux-amd64.tar.gz for the pinned
#      $HCLOUD_VERSION from the project's GitHub Releases, verifies its
#      sha256 against the pinned checksum (an offline constant in this
#      script — never trust a checksum fetched over the same channel as the
#      artifact), extracts the `hcloud` binary, and installs it atomically
#      (write to a temp file in the same directory, chmod +x, then `mv`) to
#      ~/.local/bin/hcloud.
#   3. On any mismatch (download failure, sha256 mismatch, missing binary in
#      the tarball), leaves any existing install untouched and exits nonzero
#      with a message naming the failure — never installs an unverified
#      binary.
#
# The version/checksum pin is bumped by hand, deliberately: this is a
# security-relevant download for a script that authenticates a billing-
# capable API, so an automatic "always fetch latest checksums.txt" mode is
# not offered here.
#
# The `HCLOUD_TOKEN` used by burst-lane.sh / gate-burst.sh is never touched
# by this script — it lives in ~/.config/wm-burst/.env and is sourced (never
# echoed) by those scripts, not this installer.
#
# Usage: install-hcloud.sh [--force]
#   --force   Re-download and reinstall even if the pinned sha256 already
#             matches what's on disk (useful for verifying the pin itself).
# All HCLOUD_* pins below are env-overridable so install-hcloud-selftest.sh
# can point this script at a fake curl + a throwaway tarball/hash pair and
# exercise the skip / mismatch-refusal / reinstall logic with no network
# call — the real pins are the defaults every real invocation gets.
set -uo pipefail

HCLOUD_VERSION="${HCLOUD_VERSION:-1.67.0}"
HCLOUD_TARBALL="${HCLOUD_TARBALL:-hcloud-linux-amd64.tar.gz}"
# Pinned sha256 of hcloud-linux-amd64.tar.gz for v1.67.0, taken from the
# release's own published checksums.txt (verified 2026-09-09) — an offline
# constant, not fetched at install time.
HCLOUD_TARBALL_SHA256="${HCLOUD_TARBALL_SHA256:-7164483e05a1abef492768db429a28c21d579dc70e807558cb140debc2971477}"
# sha256 of the `hcloud` binary once extracted from that same tarball (a
# different hash from the tarball's own — verified by hand, 2026-09-09,
# against the binary this PRD found already installed on RedBaron: they
# matched exactly, byte for byte). Used both for the idempotent skip-check
# and for post-install verification.
HCLOUD_BIN_SHA256="${HCLOUD_BIN_SHA256:-e82146e4d83494e7883bd05f92768c39bd03918b8e2632c07c5c4b76659bd485}"
HCLOUD_URL="${HCLOUD_URL:-https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/${HCLOUD_TARBALL}}"
CURL_BIN="${HCLOUD_CURL_BIN:-curl}"

INSTALL_DIR="${HCLOUD_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/hcloud"

force=false
for a in "$@"; do
  case "$a" in
    --force) force=true ;;
    *) echo "usage: install-hcloud.sh [--force]" >&2; exit 2 ;;
  esac
done

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

if ! $force && [ -x "$INSTALL_PATH" ]; then
  existing_sha="$(sha256_of "$INSTALL_PATH")"
  if [ "$existing_sha" = "$HCLOUD_BIN_SHA256" ]; then
    echo "already-installed: $INSTALL_PATH matches pinned v${HCLOUD_VERSION} (sha256=$HCLOUD_BIN_SHA256)"
    exit 0
  fi
  echo "install-hcloud: $INSTALL_PATH exists but does not match pinned v${HCLOUD_VERSION} sha256 (got $existing_sha) — reinstalling"
fi

mkdir -p "$INSTALL_DIR" || { echo "install-hcloud: cannot create $INSTALL_DIR" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

tarball="$tmpdir/$HCLOUD_TARBALL"
if ! "$CURL_BIN" -fsSL --max-time 60 -o "$tarball" "$HCLOUD_URL"; then
  echo "install-hcloud: download failed - $HCLOUD_URL" >&2
  exit 1
fi

got_sha="$(sha256_of "$tarball")"
if [ "$got_sha" != "$HCLOUD_TARBALL_SHA256" ]; then
  echo "install-hcloud: sha256 mismatch for $HCLOUD_TARBALL - expected $HCLOUD_TARBALL_SHA256, got $got_sha (refusing to install)" >&2
  exit 1
fi

if ! tar -xzf "$tarball" -C "$tmpdir" hcloud; then
  echo "install-hcloud: tarball did not contain an 'hcloud' binary" >&2
  exit 1
fi

chmod +x "$tmpdir/hcloud"
# Atomic install: temp file in the SAME directory as the final path, then
# rename — never leaves a half-written binary at $INSTALL_PATH.
mv -f "$tmpdir/hcloud" "$INSTALL_PATH.new"
mv -f "$INSTALL_PATH.new" "$INSTALL_PATH"

installed_sha="$(sha256_of "$INSTALL_PATH")"
if [ "$installed_sha" != "$HCLOUD_BIN_SHA256" ]; then
  echo "install-hcloud: post-install verification failed (sha256=$installed_sha)" >&2
  exit 1
fi

echo "installed: $INSTALL_PATH v${HCLOUD_VERSION} (sha256=$HCLOUD_BIN_SHA256)"
exit 0
