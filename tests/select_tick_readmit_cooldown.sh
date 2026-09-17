#!/usr/bin/env bash
# select_tick_readmit_cooldown.sh — decision bced982e, regression test for
# select-tick.sh's re-admission pre-filter.
#
# The filter used to key on manifest field `verified_at`, which nothing in
# this repo ever writes, so a PRD that came back verified-blocked was
# re-admitted every tick with no cooldown
# (build-burst-gate-canary-invariant burned 10 dispatches). SKILL.md's own
# contract is `status: queued` + `last_action` within 24h + `action:
# verified-*` — this asserts the filter now honors THAT.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

seltick_write_prd fresh-block
seltick_write_prd stale-block
seltick_write_prd never-verified

recent="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"

"$SELTICK_JQ" -n --arg recent "$recent" --arg old "$old" '
  {"prds": {
    "fresh-block": {"status":"queued","action":"verified-blocked","last_action":$recent},
    "stale-block": {"status":"queued","action":"verified-blocked","last_action":$old},
    "never-verified": {"status":"queued"}
  }}' > "$ROOT/state/manifest.json"

out=$(seltick_run --format json)

reason=$(printf '%s' "$out" | "$SELTICK_JQ" -r '.skipped[] | select(.slug == "fresh-block") | .reason')
if [ "$reason" != "verified-within-24h" ]; then
  echo "FAIL fresh-block (verified-blocked 1m ago) should be skipped verified-within-24h, got: $out" >&2
  exit 1
fi
echo "ok  fresh-block (verified-blocked 1m ago) held out of re-admission"

printf '%s' "$out" | "$SELTICK_JQ" -e '.admitted[] | select(.slug == "stale-block")' >/dev/null \
  || { echo "FAIL stale-block (verified-blocked 25h ago) should be admitted, got: $out" >&2; exit 1; }
echo "ok  stale-block (verified-blocked 25h ago, cooldown elapsed) admitted"

printf '%s' "$out" | "$SELTICK_JQ" -e '.admitted[] | select(.slug == "never-verified")' >/dev/null \
  || { echo "FAIL never-verified (no action field) should be admitted, got: $out" >&2; exit 1; }
echo "ok  never-verified (no verified action) admitted"

echo "select_tick_readmit_cooldown: PASS"
