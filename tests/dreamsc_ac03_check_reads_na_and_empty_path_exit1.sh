#!/usr/bin/env bash
# dreamsc_ac03_check_reads_na_and_empty_path_exit1 — PRD-dream-scorecard-hook R1 `--check`
# on the AC3 shapes. Independent review gaps:
#   SM5  `--check` on a metric whose value is an na: string prints `na` and exits 0 (no
#        test ran --check on an na metric);
#   LOW3 a missing or malformed path exits 1, the empty path included (`--check ''` and
#        `--check=`), never 2 (usage).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
sc_prd_file built-prds sca

DREAM_REVIEW_LOG="$SC_T/state/no-such-review-log.jsonl" sc_run --check metrics.review.persisted_rows --since 2026-11-01
[ "$SC_OUT" = na ] && [ "$SC_RC" -eq 0 ] && sc_ok "SM5 --check on na:no-review-log prints 'na', exit 0" || sc_fail "SM5 --check na: '$SC_OUT' rc=$SC_RC :: $SC_ERR"

sc_review '{"ts": "2026-11-10T01:00:00Z", "host": "h", "slug": "sca", "outcome": "pushed"}'
sc_run --check metrics.review.approve_last --since 2026-11-01
[ "$SC_OUT" = na ] && [ "$SC_RC" -eq 0 ] && sc_ok "SM5 --check on na:schema-mismatch:verdict prints 'na', exit 0" || sc_fail "SM5 --check schema-mismatch: '$SC_OUT' rc=$SC_RC"
sc_run --check metrics.review.refused --since 2026-11-01
[ "$SC_OUT" = number ] && [ "$SC_RC" -eq 0 ] && sc_ok "SM5 control: a number metric in the same run prints 'number'" || sc_fail "SM5 control: '$SC_OUT' rc=$SC_RC"

sc_run --check '' --since 2026-11-01
[ -z "$SC_OUT" ] && [ "$SC_RC" -eq 1 ] && sc_ok "LOW3 --check '' exits 1 (missing path), not 2" || sc_fail "LOW3 --check '': '$SC_OUT' rc=$SC_RC :: $SC_ERR"
sc_run --check= --since 2026-11-01
[ -z "$SC_OUT" ] && [ "$SC_RC" -eq 1 ] && sc_ok "LOW3 --check= exits 1" || sc_fail "LOW3 --check=: '$SC_OUT' rc=$SC_RC"
for p in metrics..x metrics.review metrics.review.persisted_rows.source sources.review_log .; do
  sc_run --check "$p" --since 2026-11-01
  [ "$SC_RC" -eq 1 ] && sc_ok "R1 malformed path '$p' exits 1" || sc_fail "R1 malformed path '$p': '$SC_OUT' rc=$SC_RC"
done
sc_run --check
[ "$SC_RC" -eq 2 ] && sc_ok "usage: --check with no value at all is a usage error (exit 2)" || sc_fail "--check with no value: rc=$SC_RC"
sc_run --since '' --json
[ "$SC_RC" -eq 2 ] && sc_ok "usage: an empty --since stays a usage error" || sc_fail "--since '': rc=$SC_RC"
sc_home_untouched "R7"
sc_finish
