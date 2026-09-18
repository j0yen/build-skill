#!/usr/bin/env bash
# scripts-index-gen-selftest.sh — fixture coverage for
# scripts/scripts-index-gen.sh (PRD-build-branch-contract-split
# requirement 8 / AC7). Builds a throwaway repo layout under $TMPDIR —
# never touches this repo's own scripts/ or docs/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/scripts-index-gen.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/scripts-index-gen-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/scripts" "$T/docs"
cp "$GEN" "$T/scripts/scripts-index-gen.sh"
printf '#!/usr/bin/env bash\n# good.sh — a well-documented fixture script\necho hi\n' > "$T/scripts/good.sh"
printf '#!/usr/bin/env bash\necho no header comment on line 2\n' > "$T/scripts/no-header.sh"
printf '#!/usr/bin/env bash\n\necho blank line 2, also undocumented\n' > "$T/scripts/blank-line2.sh"

bash "$T/scripts/scripts-index-gen.sh"
rc_gen=$?
expect "AC7: generator exits 0" "[ $rc_gen -eq 0 ]"
expect "AC7: docs/scripts-index.md was written" "[ -f '$T/docs/scripts-index.md' ]"
expect "AC7: documented script gets its stripped description" \
  "grep -qE '^- \`scripts/good\.sh\` — a well-documented fixture script\$' '$T/docs/scripts-index.md'"
expect "AC7: header-less script listed under Undocumented" \
  "awk '/^## Undocumented/{u=1} u' '$T/docs/scripts-index.md' | grep -q 'scripts/no-header.sh'"
expect "AC7: blank-line-2 script also listed under Undocumented" \
  "awk '/^## Undocumented/{u=1} u' '$T/docs/scripts-index.md' | grep -q 'scripts/blank-line2.sh'"
expect "AC7: undocumented scripts are NOT listed under the Scripts section" \
  "! awk '/^## Scripts/{s=1} /^## Undocumented/{s=0} s' '$T/docs/scripts-index.md' | grep -q 'no-header.sh'"

# --check mode: up to date immediately after a fresh generate, stale once
# a new script is dropped in without regenerating.
bash "$T/scripts/scripts-index-gen.sh" --check >/dev/null 2>&1
expect "AC7: --check reports up to date right after generating" "[ $? -eq 0 ]"
printf '#!/usr/bin/env bash\n# extra.sh — added after the last generate\necho hi\n' > "$T/scripts/extra.sh"
bash "$T/scripts/scripts-index-gen.sh" --check >/dev/null 2>&1
rc_stale=$?
expect "AC7: --check exits non-zero once the index is stale" "[ $rc_stale -eq 1 ]"
expect "AC7: --check never rewrites the file on its own" \
  "! grep -q 'extra.sh' '$T/docs/scripts-index.md'"

if [ "$fail" -eq 0 ]; then
  echo "scripts-index-gen-selftest: PASS"
else
  echo "scripts-index-gen-selftest: FAIL — see above" >&2
fi
exit "$fail"
