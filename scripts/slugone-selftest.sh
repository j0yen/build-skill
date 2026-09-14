#!/usr/bin/env bash
# slugone-selftest.sh — runs the `slugone` fixture set (PRD-build-prd-
# slug-uniqueness) and names each case by file, so a human or a tick
# reading this script's output can tell which acceptance criterion is
# covered without opening every file under tests/.
#
# Covers: prd-lint.sh's corpus check names both paths/titles/dates on a
# real collision (AC1); scan-prds.sh journals and suppresses the buildable
# entry (AC2); the archive-commit in-flight transitional window is
# tolerated by both (AC3) while a genuine content difference is still
# flagged by both (AC4); prd-slug-check.sh refuses a taken slug with a
# proposed alternative (AC5) and passes a free one (AC6); manifest-set.sh
# refuses a status write on a colliding slug (AC7); mark-needs-
# classification.sh names a PRD's real location instead of creating a
# stray file (AC8); and the real corpus reports zero collisions (AC9).
#
# Usage: slugone-selftest.sh
# Exit: 0 iff every tests/slugone_ac*.sh case exits 0; 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SLUGONE_TESTS_DIR:-$HERE/../tests}"

fail=0
count=0
for f in "$TESTS_DIR"/slugone_ac*.sh; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  name="$(basename "$f" .sh)"
  if bash "$f" >"/tmp/slugone-selftest.$name.out" 2>&1; then
    echo "ok  $name"
  else
    echo "FAIL $name (see /tmp/slugone-selftest.$name.out)"
    fail=1
  fi
done

if [ "$count" -eq 0 ]; then
  echo "slugone-selftest: no tests/slugone_ac*.sh cases found" >&2
  exit 1
fi

echo "----"
echo "slugone-selftest: $count case(s), $([ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE")"
exit "$fail"
