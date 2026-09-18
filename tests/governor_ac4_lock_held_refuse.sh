#!/usr/bin/env bash
# governor_ac4_lock_held_refuse.sh —
# PRD-dream-depth-governor AC4: given a second run while the run.lock is
# externally held, when `dream-governor.sh check` runs, then
# `refuse:lock=held` and the live run is untouched. Hermetic fixture,
# mirrors dream-governor-selftest.sh's AC4 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac4.XXXXXX")"
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
cat > "$t/prds/seeds/2026-09-15-green-seed.md" <<EOF
- Source: manual
- Observed: 2026-09-15
- Status: pending
- Fingerprint: deadbeefdeadbeef

An observation.
EOF
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n' > "$t/ledger/ledger.tsv"
printf '%s\t{}\t1000\tok\t1\t1\t0\t%s\n' "$(date -u +%F)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$t/ledger/ledger.tsv"

lockpath="$t/state/dream-governor/run.lock"
exec 30>"$lockpath"
flock -n 30

out="$(DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$lockpath" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  "$DG" check)"

flock -u 30
exec 30>&-

if [ "$out" != "refuse:lock=held" ]; then
  echo "FAIL AC4: expected refuse:lock=held, got: $out"
  exit 1
fi
echo "ok  AC4: refuse:lock=held while lockfile externally held ($out)"
exit 0
