#!/usr/bin/env bash
# dreamsc_ac06 — PRD-dream-scorecard-hook AC6 / R6. The landed build-contract.md
# `## Dream hooks` table names scripts/dream-scorecard.sh for dream.scorecard with args
# `--json [--since <date>]` and phase `Phase 0`, and dream-contract-drift-selftest.sh exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
row="$(python3 -I - "$SC_REPO/build-contract.md" <<'PY'
import re, sys
sec = ""
for ln in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if ln.startswith("## "):
        sec = ln[3:].strip(); continue
    if sec == "Dream hooks" and ln.startswith("| `dream.scorecard`"):
        print("\t".join(c.strip() for c in re.split(r"(?<!\\)\|", ln)[1:-1]))
PY
)"
want="$(printf '%s\t%s\t%s\t%s' '`dream.scorecard`' '`scripts/dream-scorecard.sh`' '`--json [--since <date>]`' 'Phase 0')"
[ "$row" = "$want" ] && sc_ok "AC6 contract row: $row" || sc_fail "AC6 contract row: got '$row' want '$want'"
[ -x "$SC_REPO/scripts/dream-scorecard.sh" ] && sc_ok "AC6 the named script is executable" || sc_fail "AC6 scripts/dream-scorecard.sh missing or not executable"
out="$(DRIFT_NO_FETCH=1 bash "$SC_REPO/scripts/dream-contract-drift-selftest.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && sc_ok "AC6 dream-contract-drift-selftest.sh exits 0" || sc_fail "AC6 drift selftest rc=$rc: $out"
sc_finish
