#!/usr/bin/env bash
# dreamdry_ac07 — PRD-dream-dryrun-hook AC7 / R4. The landed build-contract.md
# `## Dream hooks` table names scripts/dream-dryrun.sh for dream.dryrun with args
# `<PRD file>...` and phase `end of Phase 3, every PRD`, the script exists and is
# executable, and dream-contract-drift-selftest.sh exits 0.
set -uo pipefail
source "$(dirname "$0")/fixtures/dreamdry-common.sh"
row="$(python3 -I - "$DD_REPO/build-contract.md" <<'PY'
import re, sys
sec = ""
for ln in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if ln.startswith("## "):
        sec = ln[3:].strip(); continue
    if sec == "Dream hooks" and ln.startswith("| `dream.dryrun`"):
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", ln)[1:-1]]
        print("\t".join(cells))
PY
)"
want="$(printf '%s\t%s\t%s\t%s' '`dream.dryrun`' '`scripts/dream-dryrun.sh`' '`<PRD file>...`' 'end of Phase 3, every PRD')"
[ "$row" = "$want" ] && dd_ok "AC7 contract row: $row" || dd_fail "AC7 contract row: got '$row' want '$want'"
[ -x "$DD_REPO/scripts/dream-dryrun.sh" ] && dd_ok "AC7 the named script is executable" || dd_fail "AC7 scripts/dream-dryrun.sh missing or not executable"
out="$(DRIFT_NO_FETCH=1 bash "$DD_REPO/scripts/dream-contract-drift-selftest.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && dd_ok "AC7 dream-contract-drift-selftest.sh exits 0" || dd_fail "AC7 drift selftest rc=$rc: $out"
dd_finish
