#!/usr/bin/env bash
# dreamdry_ac06_lint_composition_never_fetches_live_clone — PRD-dream-dryrun-hook R2 and
# Goals ("The destination corpus is never written") extended to the live clones the
# composed lint reaches, under the fleet LIVE CLONES rule. Independent review "Inherited,
# not exercised": dream-lint.sh runs prd-lint.sh, whose referent check fetches the origin
# of a Live AC's build_into (the same fetch as SC-HIGH-1).
# Positive control: dream-lint.sh run directly (fetch allowed) fetches the clone. The dry
# run over a PRD naming that clone: the clone keeps every file and directory, FETCH_HEAD
# stays absent, origin/main does not move; under strace no `git fetch` exec, no AF_INET or
# AF_INET6 connect, no write under the clone, and the referent check still ran and passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
source "$HERE/fixtures/dream-local-origin.sh"
dd_setup
dlo_make "$DD_T/git" || { dd_fail "fixture: local origin and clone"; dd_finish; }
p="$DD_T/drafts/PRD-dreamdry-clone.md"
dlo_prd "$p" dreamdry-clone

dlo_advance
ctl_before="$(dlo_state)"
env -u PRD_LINT_NO_FETCH DREAM_LINT_WM_BUILD="" PRD_LINT_CACHE="$DD_T/ctl-cache" bash "$DD_REPO/scripts/dream-lint.sh" "$p" >/dev/null 2>&1
ctl_after="$(dlo_state)"
if [[ "$ctl_after" == fetch_head=yes* ]] && [ "${ctl_before#* }" != "${ctl_after#* }" ]; then
  dd_ok "control: dream-lint.sh run directly fetches the clone ($ctl_before -> $ctl_after)"
else dd_fail "control: the fixture never made the lint fetch ($ctl_before -> $ctl_after); this test would not discriminate"; fi

dlo_reclone; dlo_advance
st_before="$(dlo_state)"; snap_before="$(dlo_snapshot)"
if command -v strace >/dev/null 2>&1; then
  tr="$DD_T/strace-nofetch.log"
  dlo_trace "$tr" bash "$DD_SCRIPT" --prd-dir "$DD_T/dest" "$p"
  v="$(dlo_violations "$tr")"
  [ -z "$v" ] && dd_ok "strace: no git fetch exec, no AF_INET/AF_INET6 connect, no write under the clone" || dd_fail "strace violations: $v"
  ex="$(dlo_exercised "$tr")"
  [ -n "$ex" ] && dd_ok "strace: the referent check still read the clone (git rev-parse/cat-file)" || dd_fail "strace: the referent check never ran against the clone"
else
  echo "skip strace half: strace not installed (the mtime and ref checks below still discriminate)"
  bash "$DD_SCRIPT" --prd-dir "$DD_T/dest" "$p" >/dev/null 2>&1
fi
st_after="$(dlo_state)"; snap_after="$(dlo_snapshot)"
[ "$st_before" = "$st_after" ] && [[ "$st_after" == fetch_head=no* ]] && dd_ok "the clone's FETCH_HEAD stays absent and origin/main unmoved ($st_after)" || dd_fail "the clone moved: $st_before -> $st_after"
[ "$snap_before" = "$snap_after" ] && dd_ok "every file and directory in the clone kept its mtime and size" || dd_fail "the clone changed: $(diff <(echo "$snap_before") <(echo "$snap_after") | head -8)"
dd_run --prd-dir "$DD_T/dest" "$p"
dd_expect_line dreamdry-clone "admit-would: dreamdry-clone eligible claims=unknown open-runs=unknown" "the referent is present at the clone's origin/main: lint passes without a fetch"
dd_expect_rc 0 "no-fetch composition"
dd_tmp_empty "no-fetch composition"
dd_finish
