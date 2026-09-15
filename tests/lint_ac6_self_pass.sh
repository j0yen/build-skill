#!/usr/bin/env bash
# lint_ac6_self_pass.sh —
# PRD-prd-contract-lint AC6.
#
# Given this PRD file itself (PRD-prd-contract-lint.md), When lint runs,
# Then it PASSes with exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
PRD="${PRD_DIR:-$HOME/Documents/PRDs}/build-queue/PRD-prd-contract-lint.md"

if [ ! -f "$PRD" ]; then
  # Already archived to built-prds/ by the time this runs post-ship — that's
  # still "this PRD file itself", just moved.
  PRD="${PRD_DIR:-$HOME/Documents/PRDs}/built-prds/PRD-prd-contract-lint.md"
fi
if [ ! -f "$PRD" ]; then
  echo "FAIL: PRD-prd-contract-lint.md not found in build-queue/ or built-prds/" >&2
  exit 1
fi

out="$("$LINT" "$PRD" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "OK" ]; then
  echo "ok  AC6: PRD-prd-contract-lint.md itself lints clean, exit 0"
  exit 0
fi
echo "FAIL: expected OK/exit0 for $PRD, got exit=$rc: $out" >&2
exit 1
