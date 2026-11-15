#!/usr/bin/env bash
# dreamsc_ac02_no_prd_rows_filtered_before_schema_accounting — PRD-dream-scorecard-hook R2
# ("rows whose slug has no PRD file anywhere in the corpus are excluded from every review.*
# count and counted in review.rows_without_prd"), AC2 and AC3 together (independent review
# SC-LOW-2). The PRD filter runs before the field check:
#   [P2] no-PRD rows lacking `verdict` are rows_without_prd, never schema_mismatch;
#   [P1] when every real-slug row lacks `verdict` and only no-PRD rows carry it, the
#        verdict metrics read na:schema-mismatch:verdict, never 0 (the masked-na class);
#   a row lacking `slug` cannot be classified: it stays a schema_mismatch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
sc_prd_file built-prds sca
full() { sc_review "{\"ts\": \"$1\", \"host\": \"h\", \"slug\": \"$2\", \"verdict\": $3, \"reviewer\": null, \"mode\": \"warn\", \"batch_size\": 1, \"outcome\": \"pushed\", \"commit\": \"abc1234\", \"warnings\": []}"; }
noverdict() { sc_review "{\"ts\": \"$1\", \"host\": \"h\", \"slug\": \"$2\", \"reviewer\": null, \"mode\": \"warn\", \"batch_size\": 1, \"outcome\": \"pushed\", \"commit\": \"abc1234\", \"warnings\": []}"; }

# [P2] one complete real row; two no-PRD rows lacking verdict
full 2026-11-10T01:00:00Z sca '"APPROVE"'
noverdict 2026-11-10T02:00:00Z d1
noverdict 2026-11-10T03:00:00Z ok-one
sc_run --json --since 2026-11-01
sc_expect_rc 0 "P2"
sc_expect metrics.review.schema_mismatch.value 0 "P2 no-PRD rows lacking verdict are not schema mismatches"
sc_expect metrics.review.rows_without_prd.value 2 "P2 they are rows without a PRD"
sc_expect metrics.review.approve_last.value 1 "P2"
sc_expect metrics.review.persisted_rows.value 1 "P2"

# [P1] every real-slug row lacks verdict; only no-PRD rows carry one
: > "$DREAM_REVIEW_LOG"
noverdict 2026-11-10T01:00:00Z sca
noverdict 2026-11-10T02:00:00Z sca
full 2026-11-10T03:00:00Z g1 '"APPROVE"'
full 2026-11-10T04:00:00Z aaa '"FIX"'
sc_run --json --since 2026-11-01
sc_expect_rc 0 "P1"
sc_expect metrics.review.approve_last.value '"na:schema-mismatch:verdict"' "P1 masked-na class: never 0"
sc_expect metrics.review.fix_last.value '"na:schema-mismatch:verdict"' "P1"
sc_expect metrics.review.with_verdict.value '"na:schema-mismatch:verdict"' "P1"
sc_expect metrics.review.no_verdict_pushed.value '"na:schema-mismatch:verdict"' "P1"
sc_expect metrics.review.schema_mismatch.value 2 "P1 the two real rows"
sc_expect metrics.review.rows_without_prd.value 2 "P1"
sc_expect metrics.review.refused.value 0 "P1 a metric not needing verdict still counts"

# a row lacking slug is unclassifiable: a schema mismatch, not a row without a PRD
: > "$DREAM_REVIEW_LOG"
full 2026-11-10T01:00:00Z sca '"FIX"'
full 2026-11-10T02:00:00Z d1 '"FIX"'
sc_review '{"ts": "2026-11-10T03:00:00Z", "host": "h", "verdict": "APPROVE", "outcome": "pushed"}'
sc_run --json --since 2026-11-01
sc_expect metrics.review.schema_mismatch.value 1 "slug-less row"
sc_expect metrics.review.rows_without_prd.value 1 "slug-less row"
sc_expect metrics.review.fix_last.value 1 "slug-less row"
sc_home_untouched "R7"
sc_finish
