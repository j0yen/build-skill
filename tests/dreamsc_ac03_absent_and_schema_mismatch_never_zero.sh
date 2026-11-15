#!/usr/bin/env bash
# dreamsc_ac03 — PRD-dream-scorecard-hook AC3 (+ R5). A missing review-log path makes
# every review.* value na:no-review-log, none 0; review rows that all lack `verdict` make
# review.approve_last na:schema-mismatch:verdict with review.schema_mismatch = the row
# count; decisions rows with `decision` renamed make routing.dream_launches_by_route
# na:schema-mismatch:decision, never 0. Known-bad controls, plus R5: empty source reads 0,
# unreadable reads na:unreadable, over 50 MB reads na:too-large, no python3 exits 2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
sc_prd_file built-prds sca
real_review="$DREAM_REVIEW_LOG"

all_review() { # <want value> <label> — every metrics.review.* value equals <want>
  python3 -I -c '
import json, sys
m = json.loads(sys.argv[1])["metrics"]["review"]
want = sys.argv[2]
bad = {k: v["value"] for k, v in m.items() if v["value"] != want}
assert len(m) == 11, sorted(m)
assert not bad, bad
' "$SC_OUT" "$1" && sc_ok "$2: all 11 review.* values are $1" || sc_fail "$2: $(sc_get metrics.review)"
}

DREAM_REVIEW_LOG="$SC_T/state/no-such-review-log.jsonl" sc_run --json --since 2026-11-01
sc_expect_rc 0 "AC3 missing review log"
all_review "na:no-review-log" "AC3 missing review log"
sc_expect sources.review_log '"absent"' "AC3 missing review log"

# empty source: 0 with its source named (the empty window is not an absence)
sc_run --json --since 2026-11-01
sc_expect metrics.review.persisted_rows.value 0 "R5 empty review log"
sc_expect metrics.review.persisted_rows.source "\"$real_review\"" "R5 empty review log"

for i in 1 2 3; do sc_review "{\"ts\": \"2026-11-10T0$i:00:00Z\", \"host\": \"h\", \"slug\": \"sca\", \"reviewer\": null, \"mode\": \"warn\", \"batch_size\": 1, \"outcome\": \"pushed\", \"commit\": \"abc1234\", \"warnings\": []}"; done
sc_run --json --since 2026-11-01
sc_expect metrics.review.approve_last.value '"na:schema-mismatch:verdict"' "AC3 every row lacks verdict"
sc_expect metrics.review.fix_last.value '"na:schema-mismatch:verdict"' "AC3 every row lacks verdict"
sc_expect metrics.review.with_verdict.value '"na:schema-mismatch:verdict"' "AC3 every row lacks verdict"
sc_expect metrics.review.no_verdict_pushed.value '"na:schema-mismatch:verdict"' "AC3 every row lacks verdict"
sc_expect metrics.review.schema_mismatch.value 3 "AC3 every row lacks verdict"
# partial: one more row that HAS a verdict -> rows lacking it are excluded, the rest counted
sc_review '{"ts": "2026-11-10T05:00:00Z", "host": "h", "slug": "sca", "verdict": "APPROVE", "reviewer": "r", "mode": "warn", "batch_size": 1, "outcome": "pushed", "commit": "abc1234", "warnings": []}'
sc_run --json --since 2026-11-01
sc_expect metrics.review.approve_last.value 1 "R2 partial mismatch: remaining rows counted"
sc_expect metrics.review.persisted_rows.value 1 "R2 partial mismatch: mismatched rows excluded"
sc_expect metrics.review.schema_mismatch.value 3 "R2 partial mismatch"

for i in 1 2; do sc_decision "{\"ts\": \"2026-11-10T0$i:00:00Z\", \"kind\": \"launch\", \"task_id\": \"T$i\", \"skill\": \"dream\", \"route\": \"fable-xhigh\", \"model\": \"m\", \"effort\": \"e\", \"account\": \"a\", \"session\": \"s$i\", \"resume\": null, \"reasons\": []}"; done
sc_run --json --since 2026-11-01
sc_expect metrics.routing.dream_launches_by_route.value '"na:schema-mismatch:decision"' "AC3 decision renamed"
sc_expect metrics.routing.dream_denied.value '"na:schema-mismatch:decision"' "AC3 decision renamed"
sc_expect metrics.routing.analysis_launches_with_dream_task.value '"na:schema-mismatch:decision"' "AC3 decision renamed"
sc_expect metrics.routing.schema_mismatch.value 2 "AC3 decision renamed"
# partial: a row lacking `route` among good rows is excluded and counted, the rest still count
sc_decision '{"ts": "2026-11-10T03:00:00Z", "decision": "launch", "task_id": "T3", "skill": "dream", "route": "sonnet-medium", "model": "m", "effort": "e", "account": "a", "session": "s3", "resume": null, "reasons": []}'
sc_decision '{"ts": "2026-11-10T04:00:00Z", "decision": "launch", "task_id": "T4", "skill": "dream", "model": "m", "effort": "e", "account": "a", "session": "s4", "resume": null, "reasons": []}'
sc_run --json --since 2026-11-01
sc_expect metrics.routing.dream_launches_by_route.value '{"sonnet-medium": 1}' "R3 partial mismatch: remaining rows counted"
sc_expect metrics.routing.schema_mismatch.value 3 "R3 partial mismatch"

SKILL_ROUTING_DECISIONS="$SC_T/state/none.jsonl" sc_run --json --since 2026-11-01
sc_expect metrics.routing.dream_denied.value '"na:no-decisions-log"' "R5 missing decisions log"
sc_expect metrics.routing.malformed_lines.value '"na:no-decisions-log"' "R5 missing decisions log"

if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$DREAM_REVIEW_LOG"
  sc_run --json --since 2026-11-01
  all_review "na:unreadable" "R5 unreadable review log"
  chmod 644 "$DREAM_REVIEW_LOG"
else echo "skip R5 unreadable: running as root"; fi

truncate -s 51M "$SC_T/state/huge.jsonl"
DREAM_REVIEW_LOG="$SC_T/state/huge.jsonl" sc_run --json --since 2026-11-01
all_review "na:too-large" "R5 review log over 50 MB"

mkdir -p "$SC_T/nopy"
SC_OUT="$(PATH="$SC_T/nopy" /bin/bash "$SC_SCRIPT" --json 2>"$SC_T/stderr")"; SC_RC=$?; SC_ERR="$(cat "$SC_T/stderr")"
[ "$SC_RC" -eq 2 ] && grep -q python3 <<<"$SC_ERR" && sc_ok "R5 no python3: exit 2 naming it ($SC_ERR)" || sc_fail "R5 no python3: rc=$SC_RC err=$SC_ERR"

sc_run --since not-a-date
sc_expect_rc 2 "R5 usage: bad --since"
sc_run --bogus
sc_expect_rc 2 "R5 usage: unknown flag"
sc_finish
