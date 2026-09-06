#!/usr/bin/env bash
# intent_card_refresh_ac5_malformed_prd.sh — PRD-build-intent-card-refresh AC5.
#
# Given a PRD with zero parseable AC lines, when the script runs, then
# it exits non-zero naming the PRD and writes nothing.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-intent-card-malformed.md"

[ -x "$REFRESH" ] || { echo "ac5: $REFRESH not executable" >&2; exit 2; }
[ -r "$FIXTURE" ]  || { echo "ac5: $FIXTURE missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/icr-ac5.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

fail=0

err="$("$REFRESH" "$repo" "$FIXTURE" 2>&1 1>/dev/null)"
rc=$?

if [ "$rc" = "3" ]; then
  echo "ok  exit 3"
else
  echo "FAIL exit code: want 3 got $rc" >&2
  fail=1
fi

case "$err" in
  *"$FIXTURE"*)
    echo "ok  stderr names the PRD path" ;;
  *)
    echo "FAIL stderr does not name $FIXTURE" >&2
    echo "    stderr was: $err" >&2
    fail=1 ;;
esac

if [ -e "$repo/agent" ]; then
  echo "FAIL agent/ dir was created for a malformed PRD" >&2
  fail=1
else
  echo "ok  nothing written"
fi

exit $fail
