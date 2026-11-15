#!/usr/bin/env bash
# dreamsc_ac01_last_row_parsed_ts_and_window_edges — PRD-dream-scorecard-hook AC1 and
# Technical considerations ("the last row per slug within the window decides approve_last
# versus fix_last"; "Window filtering uses each row's ts"). Independent review gaps:
#   SM1  first-vs-last: an asymmetric fixture where the first and the last row per slug
#        give different counts (AC1's two slugs are symmetric);
#   LOW4 the last row is chosen by the parsed instant, not the ts string: APPROVE at
#        10:00:00Z then FIX at 03:00:00-08:00 (= 11:00Z) ends FIX;
#   SM2  a row dated exactly --since is in the window; the day before is not;
#   SM6  a row whose ts does not parse (absent, garbage, trailing junk, a number) is a
#        schema_mismatch, never a counted row.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
for s in sca scb scf scm; do sc_prd_file built-prds "$s"; done
r() { sc_review "{\"ts\": $1, \"host\": \"h\", \"slug\": \"$2\", \"verdict\": $3, \"reviewer\": null, \"mode\": \"warn\", \"batch_size\": 1, \"outcome\": \"${4:-pushed}\", \"commit\": \"abc1234\", \"warnings\": []}"; }

# SM1: last APPROVE {sca, scf} = 2, FIX {scb} = 1; first would read FIX 2, APPROVE 1
r '"2026-11-10T01:00:00Z"' sca '"FIX"'
r '"2026-11-10T02:00:00Z"' sca '"APPROVE"'
r '"2026-11-10T01:00:00Z"' scb '"APPROVE"'
r '"2026-11-10T02:00:00Z"' scb '"FIX"'
r '"2026-11-10T01:00:00Z"' scf '"FIX"'
r '"2026-11-10T02:00:00Z"' scf '"FIX"'
r '"2026-11-10T03:00:00Z"' scf '"APPROVE"'
sc_run --json --since 2026-11-01
sc_expect metrics.review.approve_last.value 2 "SM1 last row per slug (asymmetric)"
sc_expect metrics.review.fix_last.value 1 "SM1 last row per slug (asymmetric)"
sc_expect metrics.review.rounds_max_per_slug.value 3 "SM1"

# LOW4: mixed offsets; string order would pick APPROVE as last
: > "$DREAM_REVIEW_LOG"
r '"2026-11-10T10:00:00Z"' scm '"APPROVE"'
r '"2026-11-10T03:00:00-08:00"' scm '"FIX"'
sc_run --json --since 2026-11-01
sc_expect metrics.review.fix_last.value 1 "LOW4 parsed instant: FIX at 11:00Z is last"
sc_expect metrics.review.approve_last.value 0 "LOW4"
# the same rows written in the other file order: still FIX
: > "$DREAM_REVIEW_LOG"
r '"2026-11-10T03:00:00-08:00"' scm '"FIX"'
r '"2026-11-10T10:00:00Z"' scm '"APPROVE"'
sc_run --json --since 2026-11-01
sc_expect metrics.review.fix_last.value 1 "LOW4 file order does not decide"
# fractional seconds against whole seconds at one instant's neighbourhood
: > "$DREAM_REVIEW_LOG"
r '"2026-11-10T10:00:00.900Z"' scm '"FIX"'
r '"2026-11-10T10:00:00Z"' scm '"APPROVE"'
sc_run --json --since 2026-11-01
sc_expect metrics.review.fix_last.value 1 "LOW4 10:00:00.900Z is after 10:00:00Z"

# SM2: --since boundary
: > "$DREAM_REVIEW_LOG"
r '"2026-11-01T00:00:00Z"' sca '"APPROVE"'
r '"2026-10-31T23:59:59Z"' scb '"APPROVE"'
sc_run --json --since 2026-11-01
sc_expect metrics.review.persisted_rows.value 1 "SM2 a row dated exactly --since is in the window, the day before is not"
sc_expect metrics.review.approve_last.value 1 "SM2"

# SM6: unparseable ts -> schema_mismatch, never counted
: > "$DREAM_REVIEW_LOG"
r '"2026-11-10T01:00:00Z"' sca '"APPROVE"'
r '"not-a-date"' scb '"APPROVE"'
r '"2026-11-10garbage"' scf '"APPROVE"'
r '1762736400' scm '"APPROVE"'
sc_review '{"host": "h", "slug": "scb", "verdict": "FIX", "outcome": "pushed"}'
sc_run --json --since 2026-11-01
sc_expect metrics.review.schema_mismatch.value 4 "SM6 four rows whose ts does not parse (or is absent)"
sc_expect metrics.review.persisted_rows.value 1 "SM6 only the parseable row counts"
sc_expect metrics.review.approve_last.value 1 "SM6"
sc_home_untouched "R7"
sc_finish
