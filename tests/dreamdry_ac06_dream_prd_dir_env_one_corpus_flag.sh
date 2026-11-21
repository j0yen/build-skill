#!/usr/bin/env bash
# dreamdry_ac06_dream_prd_dir_env_one_corpus_flag — PRD-dream-dryrun-hook R2 (the lint and
# `explain` answer about ONE corpus, the destination's staged view) when the destination is
# named by $DREAM_PRD_DIR rather than --prd-dir. dream-lint.sh reads $DREAM_PRD_DIR as its PRD
# home and passes it to wm-build lint as --prd-dir; the real wm-build 0.77.112 refuses a
# repeated --prd-dir (exit 2, read on RedBaron 2026-11-21). The dry run's wrapper already names
# the staged corpus, so the lint call must carry exactly that one --prd-dir.
# Positive control: the fixture's fake wm-build refuses a repeated --prd-dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup

"$DD_T/bin/wm-build" lint "$DD_T/drafts/PRD-x.md" --prd-dir "$DD_T/dest" --prd-dir "$DD_T/tmpd" >/dev/null 2>&1; c=$?
[ "$c" -eq 2 ] && dd_ok "control: the fake wm-build refuses a repeated --prd-dir (exit 2)" \
  || dd_fail "control: the fake accepted a repeated --prd-dir (exit $c); this test would not discriminate"

dd_prd "$DD_T/drafts" dreamdry-envhome
: > "$DD_T/wb.log"
DREAM_PRD_DIR="$DD_T/dest" dd_run "$DD_T/drafts/PRD-dreamdry-envhome.md"
dd_expect_line dreamdry-envhome "admit-would: dreamdry-envhome eligible claims=unknown open-runs=unknown" "DREAM_PRD_DIR names the destination: the lint passes"
dd_expect_rc 0 "DREAM_PRD_DIR destination"
grep -qF "prd-dir=$DD_T/dest" <<<"$DD_OUT" && dd_ok "the header names the destination read from DREAM_PRD_DIR" \
  || dd_fail "the header lacks prd-dir=$DD_T/dest :: $DD_OUT"
ln="$(grep -E '^lint ' "$DD_T/wb.log" | head -1)"
n="$(grep -oF -- '--prd-dir' <<<"$ln" | wc -l)"
[ -n "$ln" ] && [ "$n" -eq 1 ] && dd_ok "the lint call carries one --prd-dir: $ln" \
  || dd_fail "the lint call carries $n --prd-dir: '$ln' :: $(cat "$DD_T/wb.log")"
if grep -qF -- "--prd-dir $DD_T/dest" <<<"$ln"; then dd_fail "the lint read the destination itself, not its staged view: $ln"
else dd_ok "the lint's one corpus is the staged view, not the destination"; fi
dd_tmp_empty "DREAM_PRD_DIR destination"
dd_finish
