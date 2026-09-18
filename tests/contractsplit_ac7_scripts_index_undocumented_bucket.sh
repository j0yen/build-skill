#!/usr/bin/env bash
# contractsplit_ac7_scripts_index_undocumented_bucket.sh —
# PRD-build-branch-contract-split AC7 (P2): given the scripts index is
# generated, when a script lacks a header comment, then the generator
# lists it under `undocumented`. Fuller fixture coverage (deduped
# descriptions, --check drift detection) lives in
# scripts/scripts-index-gen-selftest.sh; this file is the direct,
# minimal Given/When/Then the AC itself names.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GEN="$REPO_ROOT/scripts/scripts-index-gen.sh"

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

expect "AC7: scripts/scripts-index-gen.sh exists and is executable" "[ -x '$GEN' ]"

T="$(mktemp -d "${TMPDIR:-/tmp}/contractsplit-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/docs"
cp "$GEN" "$T/scripts/scripts-index-gen.sh"
printf '#!/usr/bin/env bash\necho a script whose line 2 is not a header comment\n' > "$T/scripts/undocumented-one.sh"

bash "$T/scripts/scripts-index-gen.sh" >/dev/null
expect "AC7: docs/scripts-index.md was generated" "[ -f '$T/docs/scripts-index.md' ]"
expect "AC7: the headerless script is listed under an Undocumented section" \
  "awk '/^## Undocumented/{u=1} u' '$T/docs/scripts-index.md' | grep -q 'scripts/undocumented-one.sh'"

exit "$fail"
