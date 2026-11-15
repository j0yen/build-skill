#!/usr/bin/env bash
# dreamsc_ac04_reused_prd_lint_never_fetches_live_clone — PRD-dream-scorecard-hook Goals
# ("The command writes nothing"), Technical considerations edge cases ("no network is
# used") and R7, through the reused prd-lint (independent review SC-HIGH-1).
# A queued PRD whose build_into is a local clone with a file:// origin, and whose Live
# evidence names a repo path, makes prd-lint run its referent check against that clone.
# Positive control: prd-lint run directly, fetch allowed, fetches the clone (FETCH_HEAD
# written, origin/main moves), so the fixture reaches the fetch. The scorecard over the
# same corpus: the clone keeps every file and directory (mtime, size), FETCH_HEAD stays
# absent, origin/main does not move; under strace no `git fetch` is exec'd, no AF_INET or
# AF_INET6 socket connects, no write-class syscall lands under the clone, and the referent
# check still ran (git rev-parse/cat-file in the clone) and passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
source "$HERE/fixtures/dream-local-origin.sh"
sc_setup
dlo_make "$SC_T/git" || { sc_fail "fixture: local origin and clone"; sc_finish; }
[ -f "$SC_T/prds/visions/dreamdry-fixture.md" ] || cp "$SC_TESTS/dreamdry_fixture/visions/dreamdry-fixture.md" "$SC_T/prds/visions/"
q="$SC_T/prds/build-queue/PRD-sc-fetchy.md"
dlo_prd "$q" sc-fetchy

# positive control: the reused prd-lint, run directly with its fetch allowed, fetches the clone
dlo_advance
ctl_before="$(dlo_state)"
env -u PRD_LINT_NO_FETCH PRD_LINT_CACHE="$SC_T/ctl-cache" bash "$SC_REPO/scripts/prd-lint.sh" "$SC_T/prds/build-queue" --format pass-fail >/dev/null 2>&1
ctl_after="$(dlo_state)"
if [[ "$ctl_after" == fetch_head=yes* ]] && [ "${ctl_before#* }" != "${ctl_after#* }" ]; then
  sc_ok "control: prd-lint run directly fetches the clone ($ctl_before -> $ctl_after); the fixture reaches the referent fetch"
else sc_fail "control: the fixture never made prd-lint fetch ($ctl_before -> $ctl_after); this test would not discriminate"; fi

# the scorecard over a fresh clone that is one commit behind its origin
dlo_reclone; dlo_advance
st_before="$(dlo_state)"; snap_before="$(dlo_snapshot)"
if command -v strace >/dev/null 2>&1; then
  tr="$SC_T/strace-nofetch.log"
  dlo_trace "$tr" bash "$SC_SCRIPT" --json --since 2026-11-01
  v="$(dlo_violations "$tr")"
  [ -z "$v" ] && sc_ok "strace: no git fetch exec, no AF_INET/AF_INET6 connect, no write under the clone" || sc_fail "strace violations: $v"
  ex="$(dlo_exercised "$tr")"
  [ -n "$ex" ] && sc_ok "strace: the referent check still read the clone (git rev-parse/cat-file)" || sc_fail "strace: the referent check never ran against the clone"
  grep -E 'connect\(' "$tr" | grep -vE 'AF_UNIX|AF_NETLINK' | head -3 | sed 's/^/     non-unix connect: /'
else
  echo "skip strace half: strace not installed (the mtime and ref checks below still discriminate)"
  bash "$SC_SCRIPT" --json --since 2026-11-01 >/dev/null 2>&1
fi
st_after="$(dlo_state)"; snap_after="$(dlo_snapshot)"
[ "$st_before" = "$st_after" ] && [[ "$st_after" == fetch_head=no* ]] && sc_ok "the clone's FETCH_HEAD stays absent and origin/main unmoved ($st_after)" || sc_fail "the clone moved: $st_before -> $st_after"
[ "$snap_before" = "$snap_after" ] && sc_ok "every file and directory in the clone kept its mtime and size" || sc_fail "the clone changed: $(diff <(echo "$snap_before") <(echo "$snap_after") | head -8)"

sc_run --json --since 2026-11-01
sc_expect_rc 0 "SC-HIGH-1"
sc_expect metrics.corpus.queued.value 1 "SC-HIGH-1"
sc_expect metrics.corpus.queued_lint_fail_by_id.value '{}' "SC-HIGH-1 referent present at the clone's origin/main: lint passes without a fetch"
sc_home_untouched "R7"
sc_finish
