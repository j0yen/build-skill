#!/usr/bin/env bash
# depends-gate-superseded-selftest.sh — PRD-build-prd-superseded-by AC9.
#
# Given the predecessor's file is in built-prds/ (carrying Superseded-by:/
# transferred_acs: -- fields lib/depends-gate.sh has never heard of and,
# per requirement 6, is never taught: existence in built-prds/ is the
# whole check), When the successor's Depends-on names it, Then
# depends_gate_unmet prints nothing and returns 0 -- proving the transfer
# resolves the dependency edge through nothing but the ordinary archive
# step, no hand-edit and no depends-gate.sh change required.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends-gate.sh
source "$HERE/lib/depends-gate.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/built-prds"

cat > "$tmp/built-prds/PRD-pred-x.md" <<'EOF'
- Status: built
- build_target: shell
- Superseded-by: PRD-succ-y.md
- transferred_acs: [9, 10]

## Acceptance criteria

1. P0 — Given a, When b, Then c. TRANSFERRED -> PRD-succ-y#15
EOF

cat > "$tmp/PRD-succ-y.md" <<'EOF'
- Status: queued
- build_target: shell
- Depends-on: PRD-pred-x.md
- Absorbs: PRD-pred-x.md [9:15, 10:16]

## Acceptance criteria

15. P0 — Given a, When b, Then c.
16. P0 — Given a, When b, Then c.
EOF

fails=0
if out="$(depends_gate_unmet "$tmp/PRD-succ-y.md" "$tmp/built-prds")"; then
  if [ -z "$out" ]; then
    echo "ok: AC9 depends_gate_unmet prints nothing, exit 0"
  else
    echo "FAIL: AC9 expected empty output, got: $out"; fails=1
  fi
else
  echo "FAIL: AC9 expected exit 0, got non-zero (output: $out)"; fails=1
fi

if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED"; exit 1; fi
echo "SELFTEST PASSED"
