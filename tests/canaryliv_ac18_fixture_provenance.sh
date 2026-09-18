#!/usr/bin/env bash
# tests/canaryliv_ac18_fixture_provenance.sh — PRD-build-burst-canary-
# live-parity R10/AC18: "Given tests/fixtures/canaryliv/, When the
# predecessor's hand-written-fixture lint runs, Then every fixture carries
# a recorded-from provenance line naming the 2026-09-18 04:36Z run and the
# lint passes."
#
# Every fixture under tests/fixtures/canaryliv/ was recorded from the real
# 2026-09-18 04:36Z canary run on box 166412876 (head=f59b60b3) -- the
# stale-receipt baseline (state/burst-lane/canary-{baseline,runs}/) and the
# wait-lost journal lines (~/brain/journal/build/2026-09-18.md +
# burst-lane.log) this PRD's Problem-statement cites. JSON fixtures carry
# provenance the same way tests/fixtures/burst-status.json (R16) does: a
# leading "_comment" key, real values otherwise untouched. The journal
# excerpt carries it as a leading "#" comment (real journal lines have no
# comment syntax of their own, so this is additive, not a rewrite).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
FIXDIR="$SKILL_DIR/tests/fixtures/canaryliv"
LINT="$SKILL_DIR/scripts/handwritten-fixture-lint.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC18: every tests/fixtures/canaryliv/* fixture names the 2026-09-18 04:36Z run ==="

expect "tests/fixtures/canaryliv/ exists and is non-empty" \
  "[ -d '$FIXDIR' ] && [ -n \"\$(ls -A '$FIXDIR' 2>/dev/null)\" ]"

n_files=0
n_provenanced=0
for f in "$FIXDIR"/*; do
  [ -f "$f" ] || continue
  n_files=$((n_files + 1))
  if grep -q '2026-09-18' "$f" && grep -qE '04:?36' "$f"; then
    n_provenanced=$((n_provenanced + 1))
  else
    echo "  MISSING provenance: $f" >&2
  fi
done
echo "  fixtures found: $n_files, provenanced: $n_provenanced"
expect "at least one fixture is present" "[ \"$n_files\" -gt 0 ]"
expect "every fixture names the 2026-09-18 04:36Z run" "[ \"$n_provenanced\" -eq \"$n_files\" ]"

# AC18's "the lint passes": tests/fixtures/** is structurally exempt in
# handwritten-fixture-lint.sh (it is the recording, not a fake) -- proven
# here by actually invoking the lint against these exact files rather than
# trusting that exemption unverified.
lint_out="$("$LINT" "$FIXDIR"/* 2>&1)"
lint_rc=$?
echo "  lint output: ${lint_out:-<none>}"
expect "handwritten-fixture-lint.sh exits 0 on tests/fixtures/canaryliv/*" "[ \"$lint_rc\" -eq 0 ]"
expect "handwritten-fixture-lint.sh names no violations" "[ -z \"\$lint_out\" ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac18_fixture_provenance: ALL PASS"
else
  echo "canaryliv_ac18_fixture_provenance: FAILED" >&2
fi
exit "$fail"
