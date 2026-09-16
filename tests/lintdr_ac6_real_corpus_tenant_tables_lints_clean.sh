#!/usr/bin/env bash
# lintdr_ac6_real_corpus_tenant_tables_lints_clean.sh —
# PRD-build-prd-lint-deferred-reasons-key AC6.
#
# Given the current shared PRDs corpus, When prd-lint.sh runs over
# build-queue/ and built-prds/, Then PRD-mcphost-tenant-tables exits 0 and
# no PRD carrying a `deferred_ac_reasons:` map anywhere in the corpus fails
# `deferred-acs-missing-justification` (the class of defect this PRD fixes).
#
# Read-only: never mutates the real corpus or manifest. Skips cleanly (exit
# 0) when the real PRD workspace isn't present on this host, same
# convention as durheal_ac8_real_corpus_lint_pass_sweep.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }

PRD_DIR_REAL="${PRD_DIR:-$HOME/Documents/PRDs}"
if [ ! -d "$PRD_DIR_REAL/build-queue" ]; then
  echo "ac6: skip -- no real PRD workspace at $PRD_DIR_REAL"
  exit 0
fi

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

TT="$PRD_DIR_REAL/build-queue/PRD-mcphost-tenant-tables.md"
if [ -f "$TT" ]; then
  "$LINT" "$TT" >/dev/null 2>&1
  expect "AC6: PRD-mcphost-tenant-tables lints clean (exit 0)" "[ $? -eq 0 ]"
else
  echo "ac6: PRD-mcphost-tenant-tables.md not present at $TT (already archived, or moved) -- skipping that specific assertion"
fi

# No file anywhere in the corpus that declares deferred_ac_reasons should
# ever fail deferred-acs-missing-justification -- that's the exact defect
# this PRD closes, and a regression here is countable directly.
hits=0
while IFS= read -r -d '' pf; do
  grep -q '^\s*[-*+]\?\s*deferred_ac_reasons\s*:' "$pf" || continue
  out="$("$LINT" "$pf" --format json 2>/dev/null)"
  if python3 -c "import json,sys; d=json.load(sys.stdin)[0]; sys.exit(0 if 'deferred-acs-missing-justification' in [x['id'] for x in d['failures']] else 1)" <<<"$out" 2>/dev/null; then
    echo "ac6: REGRESSION -- $pf declares deferred_ac_reasons but still fails deferred-acs-missing-justification" >&2
    hits=$((hits+1))
  fi
done < <(find "$PRD_DIR_REAL/build-queue" "$PRD_DIR_REAL/built-prds" -maxdepth 1 -name 'PRD-*.md' -print0 2>/dev/null)
expect "AC6: no deferred_ac_reasons-carrying PRD fails deferred-acs-missing-justification" "[ $hits -eq 0 ]"

exit $fail
