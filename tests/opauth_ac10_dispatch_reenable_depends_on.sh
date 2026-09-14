#!/usr/bin/env bash
# opauth_ac10_dispatch_reenable_depends_on.sh —
# PRD-build-operator-authorization-contract AC10.
#
# Given PRD-build-burst-dispatch-reenable.md before this PRD's build, When
# its `Depends-on:` line and `iter_log` are read after, Then `Depends-on:`
# includes PRD-build-operator-authorization-contract.md alongside its
# existing entries and `iter_log` has one new line naming the amendment,
# its author, and its reason; no other line in the file changed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
TARGET="$PRD_DIR/build-queue/PRD-build-burst-dispatch-reenable.md"

fail=0

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found" >&2
  exit 1
fi

depends_line="$(grep -m1 '^- Depends-on:' "$TARGET")"
grep -qF 'PRD-build-operator-authorization-contract.md' <<<"$depends_line" \
  && echo "ok  AC10: Depends-on includes PRD-build-operator-authorization-contract.md" \
  || { echo "FAIL: Depends-on line ('$depends_line') missing the new entry" >&2; fail=1; }

# The existing entries must still be present alongside the new one (an
# amendment, not a replacement).
grep -qF 'PRD-build-burst-pull-back-restore.md' <<<"$depends_line" \
  && grep -qF 'PRD-build-burst-prove-forensics.md' <<<"$depends_line" \
  && echo "ok  AC10: pre-existing Depends-on entries are still present" \
  || { echo "FAIL: Depends-on line dropped a pre-existing entry: '$depends_line'" >&2; fail=1; }

grep -qE '^- iter_log:.*PRD-build-operator-authorization-contract' "$TARGET" \
  && echo "ok  AC10: iter_log has a line naming the amendment" \
  || { echo "FAIL: no iter_log line names PRD-build-operator-authorization-contract" >&2; fail=1; }

exit $fail
