#!/usr/bin/env bash
# dreamsc_ac05 — PRD-dream-scorecard-hook AC5. --since later than every fixture row and
# file, both seams pointing at a stub lint and sidecar: every windowed count is 0 with its
# source named and no value is an na: string. Both seams empty and no lint on PATH: exactly
# the runs.* metrics after `entries` read na:no-run-record-lint and the pipeline.* metrics
# na:no-pipeline-sidecar.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
sc_prd_file built-prds sca
sc_review '{"ts": "2026-11-10T01:00:00Z", "host": "h", "slug": "sca", "verdict": "APPROVE", "reviewer": "r", "mode": "warn", "batch_size": 1, "outcome": "pushed", "commit": "abc1234", "warnings": []}'
sc_decision '{"ts": "2026-11-10T01:00:00Z", "decision": "launch", "task_id": "T1", "skill": "dream", "route": "fable-xhigh", "model": "m", "effort": "e", "account": "a", "session": "s", "resume": null, "reasons": []}'
sc_queued sc-clean
printf '# v\nsee x-wwhtbt.md\n' > "$SC_T/prds/visions/v.md"
printf '# p\nprd-defect\n' > "$SC_T/prds/parked/PRD-p.md"
printf '# Dream log\n\n## 2026-11-10T10:00:00Z  /dream  vision-a\nState: a=drafted\n' > "$SC_T/prds/notes/dream-log.md"
printf '2026-11-10T10:00:00Z\t0\tran\tinline\n' > "$SC_LINT_ANSWERS"
printf '{"date": "2026-11-14", "drafted": 3, "shipped": 1, "blocked": 0, "queued": 2, "runway_h": "na", "wtok_per_ship": "na:no-ships", "weighted": 12345}\n' > "$SC_T/sidecar/2026-11-14.json"
printf '{"date": "2026-11-13", "drafted": 9, "shipped": 9, "weighted": 9}\n' > "$SC_T/sidecar/2026-11-13.json"

sc_run --json --since 2099-01-01
sc_expect_rc 0 "AC5 future window"
python3 -I - "$SC_OUT" <<'PY' && sc_ok "AC5 every windowed count is 0 with its source named; no value is na:" || sc_fail "AC5 future window: $SC_OUT"
import json, sys
d = json.loads(sys.argv[1]); bad = []
for grp, ms in d["metrics"].items():
    for name, m in ms.items():
        v, key = m["value"], f"{grp}.{name}"
        if not m.get("source"): bad.append(f"{key}: no source")
        if isinstance(v, str): bad.append(f"{key}: {v}"); continue
        if grp == "pipeline": continue                     # copied from the sidecar, not windowed
        vals = list(v.values()) if isinstance(v, dict) else [v]
        if any(x != 0 for x in vals): bad.append(f"{key}: {v}")
if bad: print("\n".join(bad)); sys.exit(1)
PY
sc_expect metrics.pipeline.drafted.value 3 "R4 newest sidecar copied"
sc_expect metrics.pipeline.weighted.value 12345 "R4 newest sidecar copied"
sc_expect sources.pipeline_sidecar "\"$SC_T/sidecar/2026-11-14.json\"" "R4 sources names the newest sidecar"

export PATH="/usr/bin:/bin"
DREAM_RUN_NOTE_LINT="" DREAM_PIPELINE_SIDECAR_DIR="" DREAM_SKILL_DIR="" sc_run --json --since 2026-11-01
sc_expect_rc 0 "AC5 seams empty"
python3 -I - "$SC_OUT" <<'PY' && sc_ok "AC5 exactly runs.{with_run_record,lint_fail,no_record,analysis} and pipeline.* read their na reason" || sc_fail "AC5 seams empty: $SC_OUT"
import json, sys
d = json.loads(sys.argv[1])
na = {f"{g}.{n}": m["value"] for g, ms in d["metrics"].items() for n, m in ms.items() if isinstance(m["value"], str)}
want = {k: "na:no-run-record-lint" for k in ("runs.with_run_record", "runs.lint_fail", "runs.no_record", "runs.analysis")}
want.update({k: "na:no-pipeline-sidecar" for k in ("pipeline.drafted", "pipeline.shipped", "pipeline.weighted")})
if na != want: print(json.dumps(na, indent=1, sort_keys=True)); sys.exit(1)
assert d["metrics"]["runs"]["entries"]["value"] == 1, d["metrics"]["runs"]
assert d["sources"]["run_note_lint"] == "absent" and d["sources"]["pipeline_sidecar"] == "absent", d["sources"]
PY
sc_home_untouched "R7"
sc_finish
