#!/usr/bin/env bash
# dreamdry_ac04 — PRD-dream-dryrun-hook AC4. A fake printing "eligible": true then
# tick-would: skip:prefix-denied -> `ineligible — prefix-denied@<hostname>`, exit 3
# (the JSON flag is never trusted). DREAM_DRYRUN_WM_BUILD naming a missing path ->
# header wm-build=absent, `unknown — wm-build not found`, exit 4. A fake printing no
# tick-would line -> `unknown — explain: no tick-would line`, exit 4.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-p
dd_answer dreamdry-p 'tick-would: skip:prefix-denied {"reasons":["prefix-denied"]}'
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
dd_expect_line dreamdry-p "admit-would: dreamdry-p ineligible — prefix-denied@$DD_HOST claims=unknown open-runs=unknown" "AC4 prefix-denied beside eligible:true"
dd_expect_rc 3 "AC4 prefix-denied"

DREAM_DRYRUN_WM_BUILD="$DD_T/bin/no-such-wm-build" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
[ "$(head -1 <<<"$DD_OUT")" = "dream-dryrun: host=$DD_HOST wm-build=absent prd-dir=$DD_T/dest" ] && dd_ok "AC4 missing seam path: header wm-build=absent" || dd_fail "AC4 header: $DD_OUT"
dd_expect_line dreamdry-p "admit-would: dreamdry-p unknown — wm-build not found claims=unknown open-runs=unknown" "AC4 missing seam path"
dd_expect_rc 4 "AC4 missing seam path"

# a seam naming a non-executable file is absent too (Technical considerations edge case)
printf 'not a binary\n' > "$DD_T/bin/plain"
DREAM_DRYRUN_WM_BUILD="$DD_T/bin/plain" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
grep -q "wm-build=absent" <<<"$(head -1 <<<"$DD_OUT")" && dd_expect_rc 4 "edge: non-executable seam -> absent" || dd_fail "edge non-executable seam: $DD_OUT"

# R8 default chain with no seam and a PATH/HOME holding no wm-build: absent
( unset DREAM_DRYRUN_WM_BUILD; PATH="/usr/bin:/bin"; dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
  if [ "$(head -1 <<<"$DD_OUT")" = "dream-dryrun: host=$DD_HOST wm-build=absent prd-dir=$DD_T/dest" ] && [ "$DD_RC" -eq 4 ]; then echo "ok   R8 no seam, nothing on PATH/HOME: absent, exit 4"; else echo "FAIL R8 chain absent: rc=$DD_RC $DD_OUT"; exit 1; fi ) || DD_FAILS=$((DD_FAILS + 1))
# R8 default chain finds $HOME/.cargo/bin/wm-build when PATH lacks it (judge's bare bash -c)
mkdir -p "$HOME/.cargo/bin"; cp "$DD_T/bin/wm-build" "$HOME/.cargo/bin/wm-build"
( unset DREAM_DRYRUN_WM_BUILD; PATH="/usr/bin:/bin"; dd_run --prd-dir "$DD_T/dest" --json "$DD_T/drafts/PRD-dreamdry-p.md"
  python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["wm_build_path"]==sys.argv[2] and d["wm_build"]=="0.77.999", d' "$DD_OUT" "$HOME/.cargo/bin/wm-build" \
  && echo "ok   R8 chain resolves \$HOME/.cargo/bin/wm-build under a bare PATH" || { echo "FAIL R8 cargo chain: $DD_OUT"; exit 1; } ) || DD_FAILS=$((DD_FAILS + 1))
# ... and $HOME/.local/bin/wm-build when .cargo/bin has none
rm -f "$HOME/.cargo/bin/wm-build"; mkdir -p "$HOME/.local/bin"; cp "$DD_T/bin/wm-build" "$HOME/.local/bin/wm-build"
( unset DREAM_DRYRUN_WM_BUILD; PATH="/usr/bin:/bin"; dd_run --prd-dir "$DD_T/dest" --json "$DD_T/drafts/PRD-dreamdry-p.md"
  python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["wm_build_path"]==sys.argv[2], d' "$DD_OUT" "$HOME/.local/bin/wm-build" \
  && echo "ok   R8 chain resolves \$HOME/.local/bin/wm-build last" || { echo "FAIL R8 local chain: $DD_OUT"; exit 1; } ) || DD_FAILS=$((DD_FAILS + 1))
rm -f "$HOME/.local/bin/wm-build"

dd_answer dreamdry-p NONE
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
dd_expect_line dreamdry-p "admit-would: dreamdry-p unknown — explain: no tick-would line claims=unknown open-runs=unknown" "AC4 no tick-would line"
dd_expect_rc 4 "AC4 no tick-would line"

dd_answer dreamdry-p "STDERR:wm-build: config parse error at line 3"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
dd_expect_line dreamdry-p "admit-would: dreamdry-p unknown — explain: wm-build: config parse error at line 3 claims=unknown open-runs=unknown" "R1(c) no tick-would line, first stderr line"
dd_expect_rc 4 "R1(c) stderr"
# edge: a hung explain under the OPTIONAL caller-selected diagnostic deadline (no default deadline:
# A1710 timeout amendment; the no-default behaviour is dreamdry_ac04_no_default_explain_deadline.sh)
dd_answer dreamdry-p "SLEEP:30"
s0=$(date +%s)
DREAM_DRYRUN_EXPLAIN_TIMEOUT=1 dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-p.md"
el=$(( $(date +%s) - s0 ))
dd_expect_line dreamdry-p "admit-would: dreamdry-p unknown — explain: diagnostic-timeout 1s claims=unknown open-runs=unknown" "edge hung explain, diagnostic deadline"
dd_expect_rc 4 "edge hung explain"
[ "$el" -lt 15 ] && dd_ok "edge hung explain: returned after ${el}s (no wait on the 30 s child)" || dd_fail "edge hung explain took ${el}s"
sp="$(cat "$FAKE_WB_LOG.sleep-pid" 2>/dev/null)"
if [ -n "$sp" ] && [ ! -d "/proc/$sp" ]; then dd_ok "edge hung explain: the timed-out child (pid $sp) is gone"
elif [ -z "$sp" ]; then dd_fail "edge hung explain: the fake never started"
else dd_fail "edge hung explain: the timed-out child pid $sp is still running: $(cat /proc/$sp/cmdline 2>/dev/null | tr '\0' ' ')"; fi
dd_tmp_empty "AC4"
dd_finish
