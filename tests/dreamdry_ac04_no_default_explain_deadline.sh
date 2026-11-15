#!/usr/bin/env bash
# dreamdry_ac04_no_default_explain_deadline — the A1710 implementation acceptance amendment
# (hooks/timeout-amendment.md; parent PRD-dream-dryrun-hook SHA256 3a0c56c4…): the fixed
# 10 s explain timeout is replaced by NO default deadline (independent review DRY-HIGH-1:
# a healthy real explain took 7.8–11.6 s and the default failed AC8 5 of 5 times).
#   - a controlled slow healthy explain (11 s, past the old 10 s default) completes with its
#     REAL verdict, with the variable unset and with it set but empty;
#   - the lint and the --version read carry no default deadline either (static);
#   - the optional caller-selected diagnostic DREAM_DRYRUN_EXPLAIN_TIMEOUT is opt-in, and
#     when it fires the verdict is UNKNOWN (`explain: diagnostic-timeout <n>s`), never a
#     refusal or eligibility; only the child's own process group is cleaned up;
#   - a malformed diagnostic value is a usage error (exit 2), never a silent default.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-slow
unset DREAM_DRYRUN_EXPLAIN_TIMEOUT

dd_answer dreamdry-slow "SLOW:11:tick-would: admit"
s0=$(date +%s); dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-slow.md"; el=$(( $(date +%s) - s0 ))
dd_expect_line dreamdry-slow "admit-would: dreamdry-slow eligible claims=unknown open-runs=unknown" "amendment: an 11 s healthy explain completes with its real verdict (variable unset)"
dd_expect_rc 0 "amendment: unset"
[ "$el" -ge 11 ] && dd_ok "amendment: the run waited for explain (${el}s)" || dd_fail "amendment: returned after ${el}s, before the 11 s explain finished"

dd_answer dreamdry-slow 'SLOW:11:tick-would: skip:prefix-denied {"reasons":["prefix-denied"]}'
DREAM_DRYRUN_EXPLAIN_TIMEOUT="" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-slow.md"
dd_expect_line dreamdry-slow "admit-would: dreamdry-slow ineligible — prefix-denied@$DD_HOST claims=unknown open-runs=unknown" "amendment: set-but-empty is the default too: the real prefix-denied verdict"
dd_expect_rc 3 "amendment: set-but-empty"

body="$(sed -n "/^exec python3 -I - \"\$SELF\" \"\$@\" <<'PY'$/,/^PY$/p" "$DD_SCRIPT")"
grep -qE '\bor 10\b|EXPLAIN_TIMEOUT[^\n]*10' <<<"$body" && dd_fail "static: a 10 s explain default remains" || dd_ok "static: no 10 s explain default"
lint_call="$(grep -E 'run\(\["bash", DREAM_LINT' <<<"$body")"
ver_call="$(grep -E 'run\(\[wb, "--version"\]' <<<"$body")"
if [ -n "$lint_call" ] && [ -n "$ver_call" ] && ! grep -qE 'timeout|, [0-9]+[,)]' <<<"$lint_call$ver_call"; then
  dd_ok "static: the lint and --version calls carry no deadline"
else dd_fail "static: lint/--version deadline: '$lint_call' '$ver_call'"; fi

# the optional explicit diagnostic: opt-in, UNKNOWN, owned group only
dd_answer dreamdry-slow "GRANDHANG:30"
sleep 5 & bystander=$!
s0=$(date +%s)
DREAM_DRYRUN_EXPLAIN_TIMEOUT=1 dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-slow.md"
el=$(( $(date +%s) - s0 ))
dd_expect_line dreamdry-slow "admit-would: dreamdry-slow unknown — explain: diagnostic-timeout 1s claims=unknown open-runs=unknown" "diagnostic: fires as unknown"
dd_expect_rc 4 "diagnostic"
[ "$el" -lt 10 ] && dd_ok "diagnostic: returned after ${el}s" || dd_fail "diagnostic: took ${el}s"
sleep 0.3
sp="$(cat "$FAKE_WB_LOG.sleep-pid" 2>/dev/null)"; gp="$(cat "$FAKE_WB_LOG.grandchild-pid" 2>/dev/null)"
[ -n "$sp" ] && ! dd_alive "$sp" && dd_ok "diagnostic: the explain child is gone" || dd_fail "diagnostic: explain child '$sp' still alive"
[ -n "$gp" ] && ! dd_alive "$gp" && dd_ok "diagnostic: its grandchild in the same process group is gone" || dd_fail "diagnostic: grandchild '$gp' still alive"
dd_alive "$bystander" && dd_ok "diagnostic: a bystander process outside the group is untouched" || dd_fail "diagnostic: the bystander was signalled"
wait "$bystander" 2>/dev/null

for bad in abc 0 -1 nan inf 1e999; do
  DREAM_DRYRUN_EXPLAIN_TIMEOUT="$bad" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-slow.md"
  [ "$DD_RC" -eq 2 ] && grep -q 'DREAM_DRYRUN_EXPLAIN_TIMEOUT' <<<"$DD_OUT" && dd_ok "diagnostic: '$bad' is a usage error (exit 2)" || dd_fail "diagnostic '$bad': rc=$DD_RC $DD_OUT"
done
dd_tmp_empty "no default deadline"
dd_finish
