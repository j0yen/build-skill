#!/usr/bin/env bash
# laneclaim_ac6_lint_reclaims_flags_missing_probes.sh — PRD-build-lane-claim-integrity AC6.
#
# Given a reclaim journal line without recorded probes (injected
# fixture), when the tick lint (lint-reclaims) runs, then it flags the
# tick — a reclaim without recorded probes is itself a lint failure.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac6: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT
LINTJ="$T/journal.md"
cat > "$LINTJ" <<'EOF'
2026-09-12T10:00:00Z  good-prd  claim  reclaimed  (prd=good-prd age=99s probes: commit=no iter_log=no pid=no journal=no)
2026-09-12T10:05:00Z  bad-prd  claim  reclaimed  (prd=bad-prd age=99s)
EOF

set +e
out=$("$LC" lint-reclaims "$LINTJ" 2>&1); rc=$?
set -e
expect "lint-reclaims exits non-zero (exactly 1 bad line)" "[ $rc -eq 1 ]"
expect "lint-reclaims names the probe-less line" "echo '$out' | grep -q 'bad-prd'"
expect "lint-reclaims does not flag the well-formed line" "! echo '$out' | grep -q 'good-prd'"

exit $fail
