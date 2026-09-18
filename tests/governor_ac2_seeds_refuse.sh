#!/usr/bin/env bash
# governor_ac2_seeds_refuse.sh —
# PRD-dream-depth-governor AC2: given queued=3 (< DEPTH_MIN) and zero
# pending seeds, when `dream-governor.sh check` runs, then
# `refuse:seeds=0`. Hermetic fixture, mirrors dream-governor-selftest.sh's
# AC2 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac2.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state/dream-governor" "$t/ledger" "$t/journal-dir"
git -C "$t/prds" init -q
git -C "$t/prds" config user.email test@example.com
git -C "$t/prds" config user.name "Test"
: > "$t/prds/.gitkeep"
git -C "$t/prds" add .gitkeep
git -C "$t/prds" commit -q -m init

printf 'DEPTH_MIN=8\nHEADROOM_MAX=500000\n' > "$t/state/dream-governor/config"
for i in 1 2 3; do
  printf '# PRD: fixture-q%s\n\n- Status: queued\n' "$i" > "$t/prds/build-queue/PRD-fixture-q$i.md"
done
# seeds/ deliberately left empty -- zero pending seeds

out="$(DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$t/state/dream-governor/run.lock" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  "$DG" check)"

if [ "$out" != "refuse:seeds=0" ]; then
  echo "FAIL AC2: expected refuse:seeds=0, got: $out"
  exit 1
fi
echo "ok  AC2: refuse:seeds=0 on queued=3 (<DEPTH_MIN), zero pending seeds ($out)"
exit 0
