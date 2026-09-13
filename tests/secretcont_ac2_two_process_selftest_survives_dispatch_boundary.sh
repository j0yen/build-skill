#!/usr/bin/env bash
# secretcont_ac2_two_process_selftest_survives_dispatch_boundary.sh —
# PRD-build-tenant-secret-continuity AC2: given a two-process selftest
# (write in process A, read in a freshly-spawned process B), when run,
# then it passes, proving the convention survives a dispatch boundary
# and isn't a same-process illusion.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST="$HERE/../scripts/secret-store-selftest.sh"

if [ ! -x "$SELFTEST" ]; then
  echo "FAIL SECRETCONT AC2: $SELFTEST missing or not executable"
  exit 1
fi

out="$("$SELFTEST" 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "FAIL SECRETCONT AC2: secret-store-selftest.sh exited $rc"
  echo "$out"
  exit 1
fi

if ! printf '%s\n' "$out" | grep -q 'writer pid .* != reader pid .* -- confirmed cross-process'; then
  echo "FAIL SECRETCONT AC2: selftest output did not assert distinct writer/reader pids"
  echo "$out"
  exit 1
fi

if ! printf '%s\n' "$out" | grep -q '^ALL PASS$'; then
  echo "FAIL SECRETCONT AC2: selftest output missing ALL PASS"
  echo "$out"
  exit 1
fi

echo "ok  SECRETCONT AC2: secret-store-selftest.sh ALL PASS (cross-process pids confirmed distinct)"
exit 0
