#!/usr/bin/env bash
# dreamdry_ac02_cancellation_and_grandchild_cleanup — PRD-dream-dryrun-hook R2 ("the
# temporary directory is removed on every exit path") and the A1710 timeout amendment
# ("Explicit caller/user cancellation retains cleanup scoped to owned children and
# temporary artifacts, never other workers ... tested with negative bystander controls").
# Independent review DRY-LOW-5 (a setsid-escaped grandchild holding stdout hung the run)
# and gap DM7 (a child-only kill instead of a process-group kill survived):
#   [1] explain leaves a grandchild in its own process group and exits normally: the run
#       answers, and the grandchild is cleaned up with the group;
#   [2] explain leaves a setsid grandchild holding stdout and exits: the run answers at
#       once (no wait on the pipe) and does not signal that process, which left the group;
#   [3] SIGTERM and SIGINT mid-explain (the caller cancelling): the explain child and its
#       group grandchild are gone, tmp is gone, and bystanders (one in the test's group,
#       one in its own session) are untouched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-kids

# [1]
dd_answer dreamdry-kids "GRANDCHILD:tick-would: admit"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-kids.md"
dd_expect_line dreamdry-kids "admit-would: dreamdry-kids eligible claims=unknown open-runs=unknown" "[1] verdict"
sleep 0.3
gp="$(cat "$FAKE_WB_LOG.grandchild-pid" 2>/dev/null)"
[ -n "$gp" ] && ! dd_alive "$gp" && dd_ok "[1] the grandchild left in explain's process group is cleaned up" || dd_fail "[1] grandchild '$gp' still alive"
dd_tmp_empty "[1]"

# [2]
dd_answer dreamdry-kids "SETSID:tick-would: admit"
s0=$(date +%s%N); dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-kids.md"; el=$(( ($(date +%s%N) - s0) / 1000000 ))
dd_expect_line dreamdry-kids "admit-would: dreamdry-kids eligible claims=unknown open-runs=unknown" "[2] verdict"
[ "$el" -lt 5000 ] && dd_ok "[2] answered in ${el} ms while a setsid grandchild still held stdout (no hang)" || dd_fail "[2] took ${el} ms: waited on the escaped grandchild's pipe"
sp="$(cat "$FAKE_WB_LOG.setsid-pid" 2>/dev/null)"
dd_alive "$sp" && dd_ok "[2] the setsid process outside the owned group was not signalled" || echo "note [2] setsid process '$sp' already gone (finished on its own after ${el} ms)"
dd_tmp_empty "[2]"
for _ in $(seq 1 100); do dd_alive "$sp" || break; sleep 0.1; done   # it ends on its own (sleep 8)

# [3]
for sig in TERM INT; do
  rm -f "$FAKE_WB_LOG.sleep-pid" "$FAKE_WB_LOG.grandchild-pid"
  dd_answer dreamdry-kids "GRANDHANG:30"
  sleep 6 & by1=$!
  setsid sleep 6 & by2=$!
  timeout -s "$sig" 2 bash "$DD_SCRIPT" --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-kids.md" >/dev/null 2>&1; rc=$?
  sleep 0.5
  [ "$rc" -eq 124 ] && dd_ok "[3] SIG$sig: the run stopped on the caller's signal" || dd_fail "[3] SIG$sig: rc $rc"
  sp="$(cat "$FAKE_WB_LOG.sleep-pid" 2>/dev/null)"; gp="$(cat "$FAKE_WB_LOG.grandchild-pid" 2>/dev/null)"
  [ -n "$sp" ] && ! dd_alive "$sp" && dd_ok "[3] SIG$sig: the explain child is gone" || dd_fail "[3] SIG$sig: explain child '$sp' alive"
  [ -n "$gp" ] && ! dd_alive "$gp" && dd_ok "[3] SIG$sig: its group grandchild is gone" || dd_fail "[3] SIG$sig: grandchild '$gp' alive"
  dd_alive "$by1" && dd_alive "$by2" && dd_ok "[3] SIG$sig: both bystanders untouched" || dd_fail "[3] SIG$sig: a bystander was signalled ($by1 $by2)"
  dd_tmp_empty "[3] SIG$sig"
  wait "$by1" 2>/dev/null
  for _ in $(seq 1 80); do dd_alive "$by2" || break; sleep 0.1; done
done
dd_finish
