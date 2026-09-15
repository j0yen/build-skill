#!/usr/bin/env bash
# seltick_ac6_journal_line_and_schema.sh —
# PRD-build-select-tick-deterministic AC6: given any run, when it
# completes, then today's journal contains exactly one
# `select-tick  admitted=<n> skipped=<n> pool=<n> ...` line for that run
# and the JSON validates against scripts/select-tick.schema.json.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

seltick_write_prd solo shell /tmp/seltick-ac6-solo-repo

out=$(seltick_run --format json)

n=$(grep -c '  select-tick  ' "$JOURNAL")
if [ "$n" -ne 1 ]; then
  echo "FAIL AC6: expected exactly 1 select-tick journal line, got $n" >&2
  cat "$JOURNAL" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import jsonschema" 2>/dev/null; then
  echo "ok  AC6: journal line count correct (jsonschema module unavailable, schema leg skipped)"
  exit 0
fi

SCHEMA="$HERE/../scripts/select-tick.schema.json"
printf '%s' "$out" > "$ROOT/last-output.json"
python3 - "$ROOT/last-output.json" "$SCHEMA" <<'PYEOF'
import json, sys
import jsonschema
doc = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
jsonschema.validate(doc, schema)
PYEOF
if [ $? -ne 0 ]; then
  echo "FAIL AC6: JSON did not validate against select-tick.schema.json" >&2
  exit 1
fi
echo "ok  AC6: exactly one journal line, JSON validates against schema"
