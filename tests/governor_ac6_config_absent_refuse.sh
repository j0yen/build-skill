#!/usr/bin/env bash
# governor_ac6_config_absent_refuse.sh —
# PRD-dream-depth-governor AC6: given no config file, when
# `dream-governor.sh check` runs, then `refuse:config=absent` (never
# fires on defaults). Hermetic fixture, mirrors dream-governor-
# selftest.sh's AC6 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac6.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state" "$t/ledger" "$t/journal-dir"
git -C "$t/prds" init -q
git -C "$t/prds" config user.email test@example.com
git -C "$t/prds" config user.name "Test"
: > "$t/prds/.gitkeep"
git -C "$t/prds" add .gitkeep
git -C "$t/prds" commit -q -m init
# state/dream-governor/config deliberately never written

out="$(DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config-does-not-exist" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$t/state/dream-governor/run.lock" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  "$DG" check)"

if [ "$out" != "refuse:config=absent" ]; then
  echo "FAIL AC6: expected refuse:config=absent, got: $out"
  exit 1
fi
echo "ok  AC6: refuse:config=absent with no config file ($out)"
exit 0
