#!/usr/bin/env bash
# udl_ac8_persist_tick_state_atomic.sh —
# PRD-build-tick-under-dispatch-ledger AC8.
#
# Given select-tick runs inside a tick, When it finishes, Then
# state/select-tick/<tick-id>.json exists with admitted, skipped, pinned,
# counts, started_at, and last.json resolves to it; the write is
# temp+rename (no partial file observable by a concurrent reader in the
# fixture).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

for i in 1 2 3 4 5 6 7 8; do
  seltick_write_prd "udl8-$i" shell "/tmp/udl-ac8-repo-$i"
done

fail=0

# Concurrent reader: while select-tick.sh runs (repeatedly, so there's a
# real window for a reader to catch it mid-write), poll the select-tick
# state dir and assert every *.json file it can open is valid JSON — a
# temp+rename write is never observable half-written; a write-in-place
# would be.
READER_LOG="$ROOT/reader.log"
: > "$READER_LOG"
(
  end=$((SECONDS + 3))
  while [ "$SECONDS" -lt "$end" ]; do
    for f in "$ROOT/state/select-tick"/*.json; do
      [ -f "$f" ] || continue
      if ! "$SELTICK_JQ" -e . "$f" >/dev/null 2>&1; then
        echo "invalid: $f" >> "$READER_LOG"
      fi
    done
  done
) &
READER_PID=$!

for _ in 1 2 3 4 5; do
  run_out=$(seltick_run --format json)
done

wait "$READER_PID" 2>/dev/null

if [ -s "$READER_LOG" ]; then
  echo "FAIL: concurrent reader observed a partial/invalid JSON file:"
  cat "$READER_LOG"
  fail=1
else
  echo "ok  AC8: no partial file observed by a concurrent reader"
fi

last_target="$(readlink "$ROOT/state/select-tick/last.json" 2>/dev/null || true)"
if [ -n "$last_target" ] && [ -f "$ROOT/state/select-tick/$last_target" ]; then
  echo "ok  AC8: last.json resolves to an existing tick-id file"
else
  echo "FAIL: last.json missing or does not resolve: target=$last_target"
  fail=1
fi

last_content="$(cat "$ROOT/state/select-tick/last.json" 2>/dev/null)"
for key in admitted skipped pinned counts started_at; do
  if printf '%s' "$last_content" | "$SELTICK_JQ" -e "has(\"$key\")" >/dev/null 2>&1; then
    echo "ok  AC8: persisted file has key $key"
  else
    echo "FAIL: persisted file missing key $key: $last_content"
    fail=1
  fi
done

exit "$fail"
