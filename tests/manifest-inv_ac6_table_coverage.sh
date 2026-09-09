#!/usr/bin/env bash
# manifest-inv_ac6_table_coverage.sh — PRD-build-manifest-invariants AC6.
#
# Given every status present in the live manifest, When the table-coverage
# selftest runs, Then each status appears in docs/manifest-transitions.md.
#
# Also asserts every status in manifest-invariants.sh's own KNOWN_STATUSES
# list (the hand-synced set the script actually checks against — see the
# PRD's Technical considerations: generating the check from the doc is
# explicitly NOT required) appears in the doc, so the doc can't silently
# drift behind the code either.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../docs/manifest-transitions.md"
MI="$HERE/../scripts/manifest-invariants.sh"
MANIFEST_LIVE="${BUILD_MANIFEST:-$HOME/.claude/skills/build/state/manifest.json}"

[ -f "$DOC" ] || { echo "ac6: $DOC not found" >&2; exit 2; }
[ -f "$MI" ]  || { echo "ac6: $MI not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# 1. Every status named in manifest-invariants.sh's KNOWN_STATUSES appears
#    in the doc (as a `### `status`` heading — every status section in the
#    doc uses that heading shape).
known_statuses="$(python3 -c "
import re
src = open('$MI').read()
m = re.search(r'KNOWN_STATUSES = \{(.*?)\}', src, re.S)
assert m, 'KNOWN_STATUSES block not found in manifest-invariants.sh'
print('\n'.join(re.findall(r'\"([a-z_]+)\"', m.group(1))))
")"
while IFS= read -r st; do
  [ -n "$st" ] || continue
  expect "doc covers KNOWN_STATUSES entry '$st'" "grep -q '\`$st\`' '$DOC'"
done <<<"$known_statuses"

# 2. Every status actually present in the LIVE manifest (if one exists on
#    this host) also appears in the doc — the AC's literal wording. Skipped
#    gracefully (not a failure) when no live manifest exists, e.g. a fresh
#    checkout or CI box that never ran a tick.
if [ -f "$MANIFEST_LIVE" ]; then
  live_statuses="$(python3 -c "
import json
m = json.load(open('$MANIFEST_LIVE'))
prds = m.get('prds', {})
items = prds.values() if isinstance(prds, dict) else prds
statuses = sorted({e.get('status') for e in items if isinstance(e, dict) and e.get('status')})
print('\n'.join(statuses))
")"
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    expect "doc covers live manifest status '$st'" "grep -q '\`$st\`' '$DOC'"
  done <<<"$live_statuses"
else
  echo "ok  no live manifest on this host — live-status check skipped"
fi

exit $fail
