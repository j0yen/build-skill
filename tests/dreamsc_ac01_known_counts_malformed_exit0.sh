#!/usr/bin/env bash
# dreamsc_ac01 — PRD-dream-scorecard-hook AC1 (+ R7 read-only, R8 text table, R1 --check).
# Fixture review and decisions logs with known rows (pushed, refused, failed; APPROVE and
# FIX; launch and denied; dream and wwhtbt launches sharing a task id; one line cut
# mid-object) and a PRD file per real slug: every review.* and routing.* value equals its
# known count, each malformed_lines is 1, exit 0.
set -uo pipefail
REAL_HOME="$HOME"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
for s in sca scb scc scd sce; do sc_prd_file built-prds "$s"; done
r() { sc_review "{\"ts\": \"$1\", \"host\": \"h\", \"slug\": \"$2\", \"verdict\": $3, \"reviewer\": null, \"mode\": \"warn\", \"batch_size\": 1, \"outcome\": \"$4\", \"commit\": \"abc1234\", \"warnings\": []}"; }
r 2026-10-01T00:00:00Z sca '"APPROVE"' pushed     # before the window: excluded
r 2026-11-10T01:00:00Z sca '"FIX"' pushed
r 2026-11-10T02:00:00Z sca '"APPROVE"' pushed     # sca ends APPROVE
r 2026-11-10T01:00:00Z scb '"APPROVE"' pushed
r 2026-11-10T02:00:00Z scb '"FIX"' pushed         # scb ends FIX
r 2026-11-10T03:00:00Z scc null pushed            # pushed with no verdict
r 2026-11-10T03:00:00Z scd null refused
r 2026-11-10T03:00:00Z sce null failed
sc_raw "$DREAM_REVIEW_LOG" '{"ts": "2026-11-10T04:00:00Z", "host": "h", "slug": "sca", "verd'
d() { sc_decision "{\"ts\": \"$1\", \"decision\": \"$2\", \"task_id\": \"$3\", \"skill\": \"$4\", \"route\": \"$5\", \"model\": \"m\", \"effort\": \"e\", \"account\": \"acct\", \"session\": \"s-$RANDOM\", \"resume\": null, \"reasons\": []}"; }
d 2026-10-01T00:00:00Z launch T0 dream fable-high          # before the window
d 2026-11-10T01:00:00Z launch T1 dream fable-xhigh
d 2026-11-10T01:05:00Z launch T2 dream fable-xhigh
d 2026-11-10T01:10:00Z launch T3 dream sonnet-medium
d 2026-11-10T01:15:00Z denied T4 dream fable-max-exception
d 2026-11-10T01:20:00Z launch T1 wwhtbt fable-xhigh         # shares T1 with a dream launch
d 2026-11-10T01:25:00Z launch T9 5whysandrhyme fable-max   # no dream task
d 2026-11-10T01:30:00Z launch T4 wwhtbt fable-xhigh        # T4's dream row was a denial
d 2026-11-10T01:35:00Z launch T5 build sonnet-medium       # another skill
sc_raw "$SKILL_ROUTING_DECISIONS" '{"ts": "2026-11-10T02:00:00Z", "decision": "launch", "skill": "dr'

real_before="$(stat -c '%n %Y %s' "$REAL_HOME/.local/state/dream/review-log.jsonl" "$REAL_HOME/.local/state/skill-routing/decisions.jsonl" "$REAL_HOME/Documents/PRDs/notes/dream-log.md" 2>/dev/null)"
fix_before="$(find "$SC_T/prds" "$SC_T/state" "$SC_T/sidecar" -type f -printf '%p %T@ %s\n' | sort; sha256sum "$DREAM_REVIEW_LOG" "$SKILL_ROUTING_DECISIONS")"
chmod -R a-w "$SC_T/prds" "$SC_T/state" "$SC_T/sidecar"

sc_run --json --since 2026-11-01
sc_expect_rc 0 "AC1"
sc_expect window.since '"2026-11-01"' "AC1"
sc_expect metrics.review.persisted_rows.value 5 "AC1"
sc_expect metrics.review.with_verdict.value 4 "AC1"
sc_expect metrics.review.approve_last.value 1 "AC1"
sc_expect metrics.review.fix_last.value 1 "AC1"
sc_expect metrics.review.no_verdict_pushed.value 1 "AC1"
sc_expect metrics.review.refused.value 1 "AC1"
sc_expect metrics.review.failed.value 1 "AC1"
sc_expect metrics.review.rounds_max_per_slug.value 2 "AC1"
sc_expect metrics.review.malformed_lines.value 1 "AC1"
sc_expect metrics.review.schema_mismatch.value 0 "AC1"
sc_expect metrics.review.rows_without_prd.value 0 "AC1"
sc_expect metrics.routing.dream_launches_by_route.value '{"fable-xhigh": 2, "sonnet-medium": 1}' "AC1"
sc_expect metrics.routing.dream_denied.value 1 "AC1"
sc_expect metrics.routing.analysis_launches_with_dream_task.value 1 "AC1"
sc_expect metrics.routing.malformed_lines.value 1 "AC1"
sc_expect metrics.routing.schema_mismatch.value 0 "AC1"
sc_expect metrics.review.persisted_rows.source "\"$DREAM_REVIEW_LOG\"" "R1 source"
sc_expect metrics.routing.dream_denied.source "\"$SKILL_ROUTING_DECISIONS\"" "R1 source"
sc_expect sources.review_log "\"$DREAM_REVIEW_LOG\"" "R1 sources"
sc_expect sources.decisions_log "\"$SKILL_ROUTING_DECISIONS\"" "R1 sources"
sc_expect sources.run_note_lint "\"$DREAM_RUN_NOTE_LINT\"" "R1 sources (optional input named)"
sc_expect sources.pipeline_sidecar '"absent"' "R1 sources (optional input absent)"
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert set(d)=={"generated_at","window","sources","metrics"}, sorted(d)' "$SC_OUT" \
  && sc_ok "R1 one object {generated_at, window, sources, metrics}" || sc_fail "R1 top-level keys: $SC_OUT"

# R1 --check: number | na, exit 0; missing or malformed path, exit 1
sc_run --check metrics.review.persisted_rows --since 2026-11-01
[ "$SC_OUT" = number ] && [ "$SC_RC" -eq 0 ] && sc_ok "R1 --check number metric -> 'number', exit 0" || sc_fail "R1 --check: '$SC_OUT' rc=$SC_RC"
sc_run --check metrics.review.no_such_metric --since 2026-11-01
[ -z "$SC_OUT" ] && [ "$SC_RC" -eq 1 ] && sc_ok "R1 --check missing path -> exit 1" || sc_fail "R1 --check missing: '$SC_OUT' rc=$SC_RC"
sc_run --check window.since --since 2026-11-01
[ "$SC_RC" -eq 1 ] && sc_ok "R1 --check a path that is no metric -> exit 1" || sc_fail "R1 --check non-metric: '$SC_OUT' rc=$SC_RC"

# R8 text table: each value's source file and the window
sc_run --since 2026-11-01
if [ "$SC_RC" -eq 0 ] && grep -qE '^review\.persisted_rows +5 +.*review-log\.jsonl' <<<"$SC_OUT" && grep -q 'since 2026-11-01' <<<"$SC_OUT" \
   && grep -qE '^routing\.dream_launches_by_route +.*fable-xhigh.*2' <<<"$SC_OUT"; then
  sc_ok "R8 text table names the value, its source file and the window"
else sc_fail "R8 text table: $SC_OUT"; fi

# R7: nothing written anywhere (strace), fixture sources unchanged, real sources untouched
if command -v strace >/dev/null 2>&1; then
  w="$(sc_writes --json --since 2026-11-01)"
  [ -z "$w" ] && sc_ok "R7 strace: no write-class syscall on any path (except /dev/null)" || sc_fail "R7 strace writes: $w"
else echo "skip R7 strace: strace not installed"; fi
chmod -R u+w "$SC_T/prds" "$SC_T/state" "$SC_T/sidecar"
fix_after="$(find "$SC_T/prds" "$SC_T/state" "$SC_T/sidecar" -type f -printf '%p %T@ %s\n' | sort; sha256sum "$DREAM_REVIEW_LOG" "$SKILL_ROUTING_DECISIONS")"
[ "$fix_before" = "$fix_after" ] && sc_ok "R7 fixture sources unchanged (mtime, size, sha256)" || sc_fail "R7 fixture changed"
real_after="$(stat -c '%n %Y %s' "$REAL_HOME/.local/state/dream/review-log.jsonl" "$REAL_HOME/.local/state/skill-routing/decisions.jsonl" "$REAL_HOME/Documents/PRDs/notes/dream-log.md" 2>/dev/null)"
[ "$real_before" = "$real_after" ] && sc_ok "R7 real sources on this host unchanged" || sc_fail "R7 real sources changed"
sc_finish
