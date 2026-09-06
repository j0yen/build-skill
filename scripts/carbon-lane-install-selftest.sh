#!/usr/bin/env bash
# carbon-lane-install-selftest.sh — offline checks for the carbon lane's
# systemd unit set (PRD-build-second-lane-carbon P0 "Carbon units mirror
# RedBaron's proven set" + its AC6 regression: the 20:12 TimeoutStartSec
# lesson must be baked in from day one, provable without a live carbon
# box). Also exercises carbon-lane-install.sh's dry-run/link/idempotent
# paths against a scratch systemd-user dir.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
UNITS="$REPO/systemd/carbon"

echo "== AC6 regression: TimeoutStartSec exceeds the pace ExecStartPost sleep =="
PACING="$UNITS/claude-build.service.d/pacing.conf"
[ -f "$PACING" ] || { echo "FAIL: missing $PACING"; exit 1; }
timeout=$(grep -E '^TimeoutStartSec=' "$PACING" | head -n1 | cut -d= -f2)
sleep_secs=$(grep -E '^ExecStartPost=.*sleep ' "$PACING" | head -n1 | sed -E 's/.*sleep ([0-9]+).*/\1/')
[ -n "$timeout" ] && [ -n "$sleep_secs" ] || { echo "FAIL: could not parse pacing.conf ($timeout / $sleep_secs)"; exit 1; }
[ "$timeout" -gt "$sleep_secs" ] || { echo "FAIL: TimeoutStartSec=$timeout does not exceed sleep=$sleep_secs"; exit 1; }
echo "ok (TimeoutStartSec=$timeout > sleep=$sleep_secs)"

echo "== every carbon unit file is present and non-empty =="
for f in claude-build.path claude-build.path.d/nolimit.conf \
         claude-build.service claude-build.service.d/pacing.conf \
         claude-build.timer prd-sync.service prd-sync.timer; do
  [ -s "$UNITS/$f" ] || { echo "FAIL: missing or empty $f"; exit 1; }
done
echo ok

echo "== path unit watches build-queue, points at claude-build.service =="
grep -q 'DirectoryNotEmpty=%h/Documents/PRDs/build-queue' "$UNITS/claude-build.path" || { echo "FAIL: path unit watch"; exit 1; }
grep -q '^Unit=claude-build.service' "$UNITS/claude-build.path" || { echo "FAIL: path unit target"; exit 1; }
echo ok

echo "== carbon-lane-install.sh: dry-run, link, idempotent re-link, never enables =="
SCRATCH=$(mktemp -d /tmp/carbon-lane-install-selftest.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
export CARBON_LANE_SYSTEMD_USER_DIR="$SCRATCH"

out=$("$HERE/carbon-lane-install.sh" --dry-run)
echo "$out" | grep -q '^would-link: claude-build.path ' || { echo "FAIL dry-run: $out"; exit 1; }
[ -e "$SCRATCH/claude-build.path" ] && { echo "FAIL: dry-run created a file"; exit 1; }

out=$("$HERE/carbon-lane-install.sh")
echo "$out" | grep -q '^linked: claude-build.path ' || { echo "FAIL link: $out"; exit 1; }
if ! echo "$out" | grep -q 'NOT enabled'; then echo "FAIL: missing not-enabled note"; exit 1; fi
[ -L "$SCRATCH/claude-build.path" ] || { echo "FAIL: not a symlink"; exit 1; }

out2=$("$HERE/carbon-lane-install.sh")
echo "$out2" | grep -q '^unchanged: claude-build.path' || { echo "FAIL idempotent: $out2"; exit 1; }
echo ok

echo "ALL PASS"
