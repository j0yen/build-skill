#!/usr/bin/env bash
# dreamdry_live.sh — PRD-dream-dryrun-hook AC8 live proof. Run by the judge as
# `bash -c` on the build host with whatever PATH it carries: stages a fresh-slug copy
# of the shipped fixture (tests/dreamdry_fixture/) and runs the landed
# scripts/dream-dryrun.sh against the real destination corpus (default
# ~/Documents/PRDs, override DREAMDRY_LIVE_PRD_DIR) with the real wm-build binary
# found by the script's own R8 chain. Read-only toward the destination.
#
# Exit 0 only when the header reads wm-build=<version> (never absent) and the one
# verdict is `eligible` or `ineligible — prefix-denied@<this host>` (never unknown);
# else 1. The script's own output is printed in full.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="${DREAMDRY_LIVE_PRD_DIR:-$HOME/Documents/PRDs}"
host="$(hostname)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/visions"
cp "$HERE/dreamdry_fixture/visions/"*.md "$t/visions/"
slug="dreamdry-live-$(date +%Y%m%d%H%M%S)-$$"
sed -e "s/^# PRD — dreamdry-fixture:/# PRD — $slug:/" \
    -e "s/^- test_prefix: dreamdryfx$/- test_prefix: $(printf '%s' "$slug" | tr -cd 'a-z0-9')/" \
    "$HERE/dreamdry_fixture/PRD-dreamdry-fixture.md" > "$t/PRD-$slug.md"
out="$(bash "$REPO/scripts/dream-dryrun.sh" --prd-dir "$DEST" "$t/PRD-$slug.md" 2>&1)"; rc=$?
printf '%s\n(dream-dryrun exit %s)\n' "$out" "$rc"
hdr="$(head -1 <<<"$out")"
line="$(grep -E "^admit-would: $slug " <<<"$out" | head -1)"
fail=0
if [[ "$hdr" =~ ^dream-dryrun:\ host=$host\ wm-build=([0-9]+\.[0-9]+\.[0-9]+)\ prd-dir= ]]; then
  echo "ok   header names host $host and wm-build ${BASH_REMATCH[1]}"
else
  echo "FAIL header is not 'host=$host wm-build=<version>': $hdr"; fail=1
fi
case "$line" in
  "admit-would: $slug eligible claims=unknown open-runs=unknown"|"admit-would: $slug ineligible — prefix-denied@$host claims=unknown open-runs=unknown")
    echo "ok   verdict: ${line#admit-would: $slug }" ;;
  *) echo "FAIL verdict is neither eligible nor prefix-denied@$host: '$line'"; fail=1 ;;
esac
[ "$fail" -eq 0 ] && echo "PASS dreamdry_live" || echo "FAILED dreamdry_live"
exit "$fail"
