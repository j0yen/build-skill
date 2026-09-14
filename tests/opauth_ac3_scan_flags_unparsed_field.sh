#!/usr/bin/env bash
# opauth_ac3_scan_flags_unparsed_field.sh —
# PRD-build-operator-authorization-contract AC3.
#
# Given a PRD with `Operator-authorization: Joe 2026-09-13T23:15:00Z "run
# prove"` and no `scope:` segment, When scan-prds.sh scans it, Then the
# manifest flags `operator_authorization_unparsed: true` rather than
# silently treating the key as absent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/../scripts/scan-prds.sh"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/build-queue"
cat > "$T/build-queue/PRD-opauth-ac3-fixture.md" <<'EOF'
# PRD: opauth ac3 fixture
- Status: building
- Operator-authorization: Joe 2026-09-13T23:15:00Z "run prove"
EOF

out="$(PRD_DIR="$T" JOURNAL="$T/journal.md" bash "$SCAN" 2>"$T/err.log")"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: scan-prds.sh exited $rc" >&2
  cat "$T/err.log" >&2
  exit 1
fi

entry="$(printf '%s' "$out" | "$JQ" -c '.[] | select(.slug=="opauth-ac3-fixture")')"
if [ -z "$entry" ]; then
  echo "FAIL: no manifest entry for opauth-ac3-fixture" >&2
  exit 1
fi

unparsed="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization_unparsed')"
authobj="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization')"

fail=0
[ "$unparsed" = "true" ] && echo "ok  AC3: operator_authorization_unparsed=true" || { echo "FAIL: operator_authorization_unparsed='$unparsed'" >&2; fail=1; }
# Never silently widen an unparsed line into a blanket authorization object.
[ "$authobj" = "null" ] && echo "ok  AC3: operator_authorization stays null (never a blanket-scope object)" || { echo "FAIL: operator_authorization='$authobj' (expected null)" >&2; fail=1; }

exit $fail
