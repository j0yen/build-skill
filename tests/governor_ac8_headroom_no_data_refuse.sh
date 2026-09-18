#!/usr/bin/env bash
# governor_ac8_headroom_no_data_refuse.sh —
# PRD-dream-depth-governor AC8: given a missing telemetry JSON/ledger row
# for today, when `dream-governor.sh check` runs, then
# `refuse:headroom=no-data` (fail-closed, not a silent pass). Hermetic
# fixture, mirrors dream-governor-selftest.sh's AC8 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac8.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state/dream-governor" "$t/ledger" "$t/journal-dir"
git -C "$t/prds" init -q
git -C "$t/prds" config user.email test@example.com
git -C "$t/prds" config user.name "Test"
: > "$t/prds/.gitkeep"
git -C "$t/prds" add .gitkeep
git -C "$t/prds" commit -q -m init

printf 'DEPTH_MIN=8\nHEADROOM_MAX=500000\n' > "$t/state/dream-governor/config"
for i in 1 2; do
  printf '# PRD: fixture-q%s\n\n- Status: queued\n' "$i" > "$t/prds/build-queue/PRD-fixture-q$i.md"
done
cat > "$t/prds/seeds/2026-09-15-headroom-seed.md" <<EOF
- Source: manual
- Observed: 2026-09-15
- Status: pending
- Fingerprint: deadbeefdeadbeef

An observation.
EOF
# t/ledger deliberately left with no ledger.tsv at all -> ledger_weighted_for
# sees no file for today

out="$(DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$t/state/dream-governor/run.lock" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  "$DG" check)"

if [ "$out" != "refuse:headroom=no-data" ]; then
  echo "FAIL AC8: expected refuse:headroom=no-data, got: $out"
  exit 1
fi
echo "ok  AC8: refuse:headroom=no-data with no telemetry for today ($out)"
exit 0
