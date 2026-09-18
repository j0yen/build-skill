#!/usr/bin/env bash
# governor_ac1_depth_refuse.sh —
# PRD-dream-depth-governor AC1: given queued=20, DEPTH_MIN=8, when
# `dream-governor.sh check` runs, then `refuse:depth=20` and no dream
# process starts (no run.lock ever created). Hermetic fixture, mirrors
# scripts/dream-governor-selftest.sh's AC1 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac1.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state" "$t/ledger" "$t/journal-dir"
git -C "$t/prds" init -q
git -C "$t/prds" config user.email test@example.com
git -C "$t/prds" config user.name "Test"
: > "$t/prds/.gitkeep"
git -C "$t/prds" add .gitkeep
git -C "$t/prds" commit -q -m init

mkdir -p "$t/state/dream-governor"
printf 'DEPTH_MIN=8\nHEADROOM_MAX=500000\n' > "$t/state/dream-governor/config"
for i in $(seq 1 20); do
  printf '# PRD: fixture-q%s\n\n- Status: queued\n' "$i" > "$t/prds/build-queue/PRD-fixture-q$i.md"
done

out="$(DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$t/state/dream-governor/run.lock" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  "$DG" check)"

if [ "$out" != "refuse:depth=20" ]; then
  echo "FAIL AC1: expected refuse:depth=20, got: $out"
  exit 1
fi
if [ -e "$t/state/dream-governor/run.lock" ] && [ -s "$t/state/dream-governor/run.lock" ]; then
  echo "FAIL AC1: run.lock unexpectedly populated -- a dream process appears to have started"
  exit 1
fi
echo "ok  AC1: refuse:depth=20 on queued=20/DEPTH_MIN=8, no dream process started ($out)"
exit 0
