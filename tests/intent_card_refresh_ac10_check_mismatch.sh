#!/usr/bin/env bash
# intent_card_refresh_ac10_check_mismatch.sh — PRD-build-intent-card-
# refresh AC10 (P2).
#
# Given a repo whose card names an older PRD than the newest built one,
# when --check runs, then exit 1 with both names printed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REFRESH="$HERE/../scripts/intent-card-refresh.sh"
JQ="${JQ:-jq}"

[ -x "$REFRESH" ] || { echo "ac10: $REFRESH not executable" >&2; exit 2; }

scratch="$(mktemp -d /tmp/icr-ac10.XXXXXXXX)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/agent"

old_prd="/nonexistent/PRD-fixture-intent-card-a-old.md"
new_prd="/nonexistent/PRD-fixture-intent-card-b-new.md"

manifest="$scratch/manifest.json"
"$JQ" -n --arg repo "$repo" --arg old "$old_prd" --arg new "$new_prd" '{
  prds: {
    "fixture-intent-card-a-old": {output_repo_path: $repo, status: "built", path: $old, last_action: "2026-01-01T00:00:00Z"},
    "fixture-intent-card-b-new": {output_repo_path: $repo, status: "built", path: $new, last_action: "2026-02-01T00:00:00Z"}
  }
}' > "$manifest"

"$JQ" -n --arg old "$old_prd" '{schema: "autobuilder.intent_card.v1", prd_source: $old, intent_slug: "fixture-intent-card-a-old"}' \
  > "$repo/agent/intent-card.json"

fail=0

out="$(MANIFEST="$manifest" "$REFRESH" --check "$repo" 2>&1)"
rc=$?

if [ "$rc" = "1" ]; then
  echo "ok  exit 1"
else
  echo "FAIL exit code: want 1 got $rc" >&2
  echo "    output: $out" >&2
  fail=1
fi

case "$out" in
  *"$old_prd"*) echo "ok  output names the card's (stale) PRD" ;;
  *) echo "FAIL output does not name $old_prd" >&2; echo "    output: $out" >&2; fail=1 ;;
esac

case "$out" in
  *"$new_prd"*) echo "ok  output names the newest built PRD" ;;
  *) echo "FAIL output does not name $new_prd" >&2; echo "    output: $out" >&2; fail=1 ;;
esac

exit $fail
