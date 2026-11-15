#!/usr/bin/env bash
# dreamsc_ac07_no_elapsed_time_deadline_on_reused_tools — the scorecard puts no elapsed-time
# deadline on the tools it reuses (prd-lint, the run-note lint): a healthy but slow tool is
# waited for, never turned into na:prd-lint-error or an unbucketed entry by a timer.
# Applies Joe's standing no-agent-imposed worker limits, the same rule the A1710 timeout
# amendment applies to dream.dryrun's explain (hooks/timeout-amendment.md). A static check
# (a behavioral one would need a tool slower than the old 120 s and 600 s guards), plus a
# behavioral control: a run-note lint that takes 3 s is still counted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
body="$(sed -n "/^exec python3 -I - \"\$SELF\" \"\$@\" <<'PY'$/,/^PY$/p" "$SC_SCRIPT")"
[ -n "$body" ] || sc_fail "static: could not find the python body"
hits="$(grep -nE 'timeout *=' <<<"$body" || true)"
[ -z "$hits" ] && sc_ok "static: no subprocess call in the scorecard carries a timeout" || sc_fail "static: elapsed-time deadlines remain: $hits"

printf '# dream log\n\n## 2026-11-10T01:00:00Z  /dream  vision-x\nState: x\n' > "$SC_T/prds/notes/dream-log.md"
printf '2026-11-10T01:00:00Z\t0\tran\tskipped\n' > "$SC_LINT_ANSWERS"
slow="$SC_T/bin/slow-lint.sh"
printf '#!/usr/bin/env bash\nsleep 3\nexec %q "$@"\n' "$SC_T/bin/dream-run-note-lint.sh" > "$slow"; chmod +x "$slow"
DREAM_RUN_NOTE_LINT="$slow" sc_run --json --since 2026-11-01
sc_expect metrics.runs.with_run_record.value 1 "a 3 s run-note lint is waited for"
sc_expect metrics.runs.analysis.value '{"inline": 0, "ran": 1, "reused": 0, "skipped": 1}' "a 3 s run-note lint is waited for"
sc_home_untouched "R7"
sc_finish
