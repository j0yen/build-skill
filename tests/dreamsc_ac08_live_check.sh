#!/usr/bin/env bash
# dreamsc_ac08 — PRD-dream-scorecard-hook AC8 live shape, run on the build host against
# its REAL sources (read-only), through `bash -c` like the judge: `--check
# metrics.review.persisted_rows` prints `number` or `na` and exits 0, and `--json` prints
# one object whose metrics.review.persisted_rows.value is that number or an na: string.
# The landed-path evidence (`~/wintermute/build-skill/scripts/dream-scorecard.sh`) is the
# judge's after land; this test runs the script of the tree it lives in.
# lint-journal-fixtures:tests-exempt PRD-dream-*-hook — AC8's live shape reads the REAL host sources on purpose; the scorecard opens nothing for writing (R7, strace-checked in dreamsc_ac01/ac04).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts/dream-scorecard.sh"
fail=0
out="$(bash -c "$S --check metrics.review.persisted_rows")"; rc=$?
case "$out" in number|na) [ "$rc" -eq 0 ] && echo "ok   AC8 --check printed '$out', exit 0" || { echo "FAIL AC8 --check exit $rc"; fail=1; } ;;
  *) echo "FAIL AC8 --check printed '$out' (exit $rc)"; fail=1 ;; esac
js="$(bash -c "$S --json")"; jrc=$?
v="$(python3 -I -c '
import json, sys
d = json.loads(sys.argv[1]); v = d["metrics"]["review"]["persisted_rows"]["value"]
if isinstance(v, bool): sys.exit(1)
if isinstance(v, (int, float)): print("number", v)
elif isinstance(v, str) and v.startswith("na:"): print("na", v)
else: sys.exit(1)' "$js")" || { echo "FAIL AC8 --json value is neither a number nor an na: string"; fail=1; }
[ "$jrc" -eq 0 ] || { echo "FAIL AC8 --json exit $jrc"; fail=1; }
[ -n "$v" ] && [ "${v%% *}" = "$out" ] && echo "ok   AC8 --json metrics.review.persisted_rows.value: ${v#* } (agrees with --check)" || { echo "FAIL AC8 --check '$out' vs --json '$v'"; fail=1; }
echo "host $(hostname); sources: $(python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["sources"]))' "$js" 2>/dev/null)"
[ "$fail" -eq 0 ] && echo "PASS dreamsc_ac08_live_check" || echo "FAILED dreamsc_ac08_live_check"
exit "$fail"
