#!/usr/bin/env bash
# dreamdry_ac02 — PRD-dream-dryrun-hook AC2. A fake answering `tick-would: admit`,
# a prober answering 200, one lint-clean PRD with no URL: the header names the host
# and the fake's --version, then `admit-would: <slug> eligible claims=unknown
# open-runs=unknown`, exit 0. Also: explain and wm-build lint read the STAGED corpus.
set -uo pipefail
source "$(dirname "$0")/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-a
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md"
want_hdr="dream-dryrun: host=$DD_HOST wm-build=0.77.999 prd-dir=$DD_T/dest"
hdr="$(head -1 <<<"$DD_OUT")"
[ "$hdr" = "$want_hdr" ] && dd_ok "AC2 header: '$hdr'" || dd_fail "AC2 header: got '$hdr', want '$want_hdr'"
[ "$(sed -n 2p <<<"$DD_OUT")" = "admit-would: dreamdry-a eligible claims=unknown open-runs=unknown" ] \
  && dd_ok "AC2 line 2 is the eligible verdict" || dd_fail "AC2 line 2: $DD_OUT"
[ "$(wc -l <<<"$DD_OUT")" -eq 2 ] && dd_ok "AC2 exactly two lines" || dd_fail "AC2 line count: $DD_OUT"
dd_expect_rc 0 "AC2"
ex="$(grep '^explain' "$DD_T/wb.log")"
if grep -q -- "--prd-dir $DD_T/tmpd/" <<<"$ex" && grep -q -- "--state-dir $DD_T/tmpd/.*/state dreamdry-a" <<<"$ex"; then
  dd_ok "AC2 explain read the staged corpus and its empty state dir: $ex"
else dd_fail "AC2 explain argv: $ex"; fi
li="$(grep '^lint' "$DD_T/wb.log")"
if grep -q -- "lint $DD_T/tmpd/.*/build-queue/PRD-dreamdry-a.md --prd-dir $DD_T/tmpd/" <<<"$li"; then
  dd_ok "AC2 wm-build lint ran on the staged copy with --prd-dir <tmp>"
else dd_fail "AC2 wm-build lint argv: $li"; fi
[ ! -s "$DD_T/probe.log" ] && dd_ok "AC2 no URL, prober not called" || dd_fail "AC2 prober called: $(cat "$DD_T/probe.log")"
dd_run --prd-dir "$DD_T/dest" --json "$DD_T/drafts/PRD-dreamdry-a.md"
if python3 -I -c '
import json, sys
d = json.loads(sys.argv[1]); f = d["files"][0]
assert set(d) >= {"host", "wm_build", "wm_build_path", "prd_dir", "files"}, d
assert d["wm_build"] == "0.77.999" and d["wm_build_path"] == sys.argv[2], d
assert f["slug"] == "dreamdry-a" and f["verdict"] == "eligible", f
assert set(f) >= {"slug", "verdict", "reasons", "lint", "explain", "urls", "unknown"}, f
assert f["lint"]["exit"] == 0 and f["explain"]["tick_would"] == "admit", f
' "$DD_OUT" "$DD_T/bin/wm-build"; then dd_ok "R6 --json object carries the named keys"; else dd_fail "R6 --json: $DD_OUT"; fi
dd_expect_rc 0 "R6 --json"
dd_tmp_empty "AC2"

# R3 / edge cases: usage, a destination that is not a directory, an unreadable file
dd_run --prd-dir "$DD_T/dest"
dd_expect_rc 2 "R3 no files: usage"
dd_run --prd-dir "$DD_T/no-such-dir" "$DD_T/drafts/PRD-dreamdry-a.md"
dd_expect_rc 1 "edge destination not a directory"
grep -q "not a directory: $DD_T/no-such-dir" <<<"$DD_OUT" && dd_ok "edge destination not a directory: named" || dd_fail "edge destination message: $DD_OUT"
if [ "$(id -u)" -ne 0 ]; then
  dd_prd "$DD_T/drafts" dreamdry-locked; chmod 000 "$DD_T/drafts/PRD-dreamdry-locked.md"
  dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md" "$DD_T/drafts/PRD-dreamdry-locked.md"
  dd_expect_line dreamdry-locked "admit-would: dreamdry-locked unknown — cannot read claims=unknown open-runs=unknown" "edge unreadable file"
  dd_expect_line dreamdry-a "admit-would: dreamdry-a eligible claims=unknown open-runs=unknown" "edge unreadable file: the other file still answered"
  dd_expect_rc 4 "edge unreadable file"
  chmod 644 "$DD_T/drafts/PRD-dreamdry-locked.md"
fi
# R2: the temporary directory goes on a signal too (SIGTERM via coreutils timeout, mid-explain)
dd_answer dreamdry-a "SLEEP:30"
timeout -s TERM 2 bash "$DD_SCRIPT" --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md" >/dev/null 2>&1
sleep 0.5
dd_tmp_empty "R2 SIGTERM mid-explain"
sp="$(cat "$FAKE_WB_LOG.sleep-pid" 2>/dev/null)"
[ -n "$sp" ] && [ ! -d "/proc/$sp" ] && dd_ok "R2 SIGTERM mid-explain: its explain child was reaped" || dd_fail "R2 SIGTERM: child pid '$sp' state: $(ls -d /proc/$sp 2>&1)"
dd_finish
