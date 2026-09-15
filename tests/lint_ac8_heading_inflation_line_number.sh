#!/usr/bin/env bash
# lint_ac8_heading_inflation_line_number.sh —
# PRD-prd-contract-lint AC8.
#
# Given an AC section with an h3 (or bold) heading between numbered lines
# (the inflation-trap fixture — real 2026-07-02 incident shape), When lint
# runs, Then it FAILs naming the heading and its line number.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/prd-lint-selftest.sh"
LINT="$HERE/../scripts/prd-lint.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: prd-lint-selftest.sh exited $rc" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi

fail=0
for label in \
  "ok: ac-heading-inflation/fail (h3) -> FAIL ac-heading-inflation" \
  "ok: ac-heading-inflation/fail (bold) -> FAIL ac-heading-inflation"
do
  if grep -qF "$label" <<<"$out"; then
    echo "ok  AC8: $label"
  else
    echo "FAIL: expected label missing from prd-lint-selftest.sh: $label" >&2
    fail=1
  fi
done

# Direct spot-check that the message actually carries a line NUMBER, not
# just the heading text (the selftest's expect_fail only checks the id).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/build-queue" "$tmp/visions"
echo "v" > "$tmp/visions/v.md"
{
  printf -- '- Status: queued\n- build_target: shell\n- Vision: visions/v.md\n- Grounding: wwhtbt -- test\n\n'
  printf '## Acceptance criteria\n\n'
  printf '1. P0 -- Given a, When b, Then c.\n2. P0 -- Given d, When e, Then f.\n\n'
  printf '### Anti-pattern audit\n\n'
  printf '1. Not a real AC.\n'
} > "$tmp/build-queue/PRD-lint-ac8-spotcheck.md"

json="$("$LINT" --format json "$tmp/build-queue/PRD-lint-ac8-spotcheck.md" 2>/dev/null)"
if printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)[0]
msg = next((f['message'] for f in d['failures'] if f['id'] == 'ac-heading-inflation'), '')
sys.exit(0 if 'line 11' in msg and 'Anti-pattern audit' in msg else 1)
" 2>/dev/null; then
  echo "ok  AC8: message names the heading text and its line number"
else
  echo "FAIL: ac-heading-inflation message missing line number/heading text: $json" >&2
  fail=1
fi

exit $fail
