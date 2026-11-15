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
dd_finish
