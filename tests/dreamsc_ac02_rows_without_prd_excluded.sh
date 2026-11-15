#!/usr/bin/env bash
# dreamsc_ac02 — PRD-dream-scorecard-hook AC2. Review-log rows for slugs with no
# PRD-<slug>.md anywhere in the fixture corpus change no review.* count and
# review.rows_without_prd equals their number. Known-bad control: the persist
# selftest's own rows, copied verbatim from the rows `dream-persist.sh --selftest`
# leaked into ryzen7's real review log (slugs ok-one, bad-two, new-three), plus one row
# for a PRD that was renamed away.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
sc_prd_file built-prds scx; sc_prd_file parked scy; sc_prd_file build-queue scz
sc_review '{"ts": "2026-11-01T01:00:00Z", "host": "h", "slug": "scx", "verdict": "APPROVE", "reviewer": "fable", "mode": "warn", "batch_size": 1, "outcome": "pushed", "commit": "1111111", "warnings": []}'
sc_review '{"ts": "2026-11-01T02:00:00Z", "host": "h", "slug": "scy", "verdict": "FIX", "reviewer": "fable", "mode": "warn", "batch_size": 1, "outcome": "pushed", "commit": "2222222", "warnings": []}'
sc_review '{"ts": "2026-11-01T03:00:00Z", "host": "h", "slug": "scz", "verdict": null, "reviewer": null, "mode": "warn", "batch_size": 1, "outcome": "refused", "commit": null, "warnings": []}'
counts() { python3 -I -c 'import json,sys; m=json.loads(sys.argv[1])["metrics"]["review"]; m.pop("rows_without_prd"); print(json.dumps({k: v["value"] for k, v in m.items()}, sort_keys=True))' "$SC_OUT"; }
sc_run --json --since 2026-10-25
before="$(counts)"
sc_expect metrics.review.rows_without_prd.value 0 "AC2 before"
sc_expect metrics.review.persisted_rows.value 2 "AC2 before (build-queue, built-prds and parked all count)"
sc_expect metrics.review.refused.value 1 "AC2 before"
# the persist selftest's own rows, verbatim
sc_raw "$DREAM_REVIEW_LOG" '{"ts": "2026-11-01T03:10:00Z", "host": "ryzen7", "slug": "ok-one", "verdict": null, "reviewer": null, "mode": "warn", "batch_size": 3, "outcome": "pushed", "commit": "f0eed32", "warnings": ["review-missing (no --review file given)"]}'
sc_raw "$DREAM_REVIEW_LOG" '{"ts": "2026-11-01T03:10:00Z", "host": "ryzen7", "slug": "bad-two", "verdict": null, "reviewer": null, "mode": "warn", "batch_size": 3, "outcome": "pushed", "commit": "f0eed32", "warnings": ["review-missing (no --review file given)"]}'
sc_raw "$DREAM_REVIEW_LOG" '{"ts": "2026-11-01T03:10:00Z", "host": "ryzen7", "slug": "new-three", "verdict": null, "reviewer": null, "mode": "warn", "batch_size": 3, "outcome": "pushed", "commit": "f0eed32", "warnings": ["review-missing (no --review file given)"]}'
sc_review '{"ts": "2026-11-02T00:00:00Z", "host": "h", "slug": "renamed-away", "verdict": "FIX", "reviewer": "fable", "mode": "warn", "batch_size": 1, "outcome": "pushed", "commit": "3333333", "warnings": []}'
sc_run --json --since 2026-10-25
sc_expect_rc 0 "AC2"
after="$(counts)"
[ -n "$before" ] && [ "$before" = "$after" ] && sc_ok "AC2 the rows without a PRD changed no review.* count: $after" || sc_fail "AC2 counts moved: before $before after $after"
sc_expect metrics.review.rows_without_prd.value 4 "AC2"
sc_home_untouched "R7"
sc_finish
