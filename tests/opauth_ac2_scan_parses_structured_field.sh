#!/usr/bin/env bash
# opauth_ac2_scan_parses_structured_field.sh —
# PRD-build-operator-authorization-contract AC2.
#
# Given a PRD with `Operator-authorization: Joe 2026-09-13T23:15:00Z "run
# prove" scope: one real ccx43 for prove`, When scan-prds.sh scans it, Then
# the manifest entry for that PRD carries a parsed `operator_authorization`
# object with who/ts/words/scope fields, not a generic/display-only string.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/../scripts/scan-prds.sh"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/build-queue"
cat > "$T/build-queue/PRD-opauth-ac2-fixture.md" <<'EOF'
# PRD: opauth ac2 fixture
- Status: building
- Operator-authorization: Joe 2026-09-13T23:15:00Z "run prove" scope: one real ccx43 for prove
EOF

out="$(PRD_DIR="$T" JOURNAL="$T/journal.md" bash "$SCAN" 2>"$T/err.log")"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: scan-prds.sh exited $rc" >&2
  cat "$T/err.log" >&2
  exit 1
fi

entry="$(printf '%s' "$out" | "$JQ" -c '.[] | select(.slug=="opauth-ac2-fixture")')"
if [ -z "$entry" ]; then
  echo "FAIL: no manifest entry for opauth-ac2-fixture" >&2
  exit 1
fi

who="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization.who // empty')"
ts="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization.ts // empty')"
words="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization.words // empty')"
scope="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization.scope // empty')"

fail=0
[ "$who" = "Joe" ] && echo "ok  AC2: who=Joe" || { echo "FAIL: who='$who'" >&2; fail=1; }
[ "$ts" = "2026-09-13T23:15:00Z" ] && echo "ok  AC2: ts=2026-09-13T23:15:00Z" || { echo "FAIL: ts='$ts'" >&2; fail=1; }
[ "$words" = "run prove" ] && echo "ok  AC2: words='run prove'" || { echo "FAIL: words='$words'" >&2; fail=1; }
[ "$scope" = "one real ccx43 for prove" ] && echo "ok  AC2: scope='one real ccx43 for prove'" || { echo "FAIL: scope='$scope'" >&2; fail=1; }

unparsed="$(printf '%s' "$entry" | "$JQ" -r '.operator_authorization_unparsed')"
[ "$unparsed" = "false" ] && echo "ok  AC2: operator_authorization_unparsed=false" || { echo "FAIL: operator_authorization_unparsed='$unparsed'" >&2; fail=1; }

exit $fail
