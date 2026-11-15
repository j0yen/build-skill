# tests/fixtures/dreamdry-common.sh — shared setup for tests/dreamdry_ac0N_*.sh
# (PRD-dream-dryrun-hook R5). Sourced, never run.
#
# dd_setup builds, under one mktemp directory:
#   $DD_T/home            private HOME (no real ~/.cargo/bin, ~/.local/bin)
#   $DD_T/dest            destination corpus: build-queue/ built-prds/ parked/ visions/
#   $DD_T/drafts          the drafter's home (flat): PRD files + visions/
#   $DD_T/bin/wm-build    fake wm-build reproducing the real 0.77.112 grammar
#   $DD_T/bin/probe       fake URL prober
#   $DD_T/tmpd            TMPDIR for the script (empty again after every run)
# and exports DREAM_DRYRUN_WM_BUILD / DREAM_DRYRUN_URL_PROBE at the fakes.
#
# Canned answers:
#   $DD_T/wb-answers      "<slug>\t<tick-would line | NONE | STDERR:<text>>"; default `tick-would: admit`
#   $DD_T/probe-answers   "<METHOD> <url>\t<printed text>"; default 200
# Call logs: $DD_T/wb.log (one line of argv per call), $DD_T/probe.log.

DD_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD_REPO="$(cd "$DD_TESTS/.." && pwd)"
DD_SCRIPT="$DD_REPO/scripts/dream-dryrun.sh"
DD_FIXTURE="$DD_TESTS/dreamdry_fixture/PRD-dreamdry-fixture.md"
DD_HOST="$(hostname)"
DD_FAILS=0

# The repo's isolation prelude (scripts/lib/isolation.sh selftest_init): BUILD_TEST=1, a
# per-run BUILD_TEST_ROOT, HOME/journal/state redirected, BUILD_TEST_REAL_HOME kept for
# read-only real-clone reads (dream-contract-drift-selftest.sh). A root minted here is
# removed on exit; one inherited from run-selftests.sh is left to it.
DD_OWN_ROOT=0; [ -n "${BUILD_TEST_ROOT:-}" ] || DD_OWN_ROOT=1
# shellcheck source=../../scripts/lib/isolation.sh
source "$DD_REPO/scripts/lib/isolation.sh"
_real_home="${BUILD_TEST_REAL_HOME:-$HOME}"   # outermost real HOME: a nested isolation_apply would re-point it at the runner's fixture HOME
selftest_init || { echo "FAIL isolation prelude (selftest_init) failed"; exit 1; }
export BUILD_TEST_REAL_HOME="$_real_home"
dd_root_cleanup() { [ "$DD_OWN_ROOT" = 1 ] && rm -rf "$BUILD_TEST_ROOT"; return 0; }
trap dd_root_cleanup EXIT

dd_ok()   { echo "ok   $*"; }
dd_fail() { echo "FAIL $*"; DD_FAILS=$((DD_FAILS + 1)); }

dd_setup() {
  DD_T="$(mktemp -d)"
  trap 'chmod -R u+w "$DD_T" 2>/dev/null; rm -rf "$DD_T"; dd_root_cleanup' EXIT
  mkdir -p "$DD_T/home" "$DD_T/dest/build-queue" "$DD_T/dest/built-prds" "$DD_T/dest/parked" \
           "$DD_T/dest/visions" "$DD_T/drafts/visions" "$DD_T/bin" "$DD_T/tmpd"
  cp "$DD_TESTS/dreamdry_fixture/visions/dreamdry-fixture.md" "$DD_T/drafts/visions/"
  cp "$DD_TESTS/dreamdry_fixture/visions/dreamdry-fixture.md" "$DD_T/dest/visions/"
  : > "$DD_T/wb-answers"; : > "$DD_T/probe-answers"; : > "$DD_T/wb.log"; : > "$DD_T/probe.log"
  cat > "$DD_T/bin/wm-build" <<'EOS'
#!/usr/bin/env bash
# fake wm-build: canned answers in the real 0.77.112 grammar (JSON block with
# "eligible": true printed even beside a skip, then check: lines, then tick-would:).
printf '%s\n' "$*" >> "$FAKE_WB_LOG"
case "${1:-}" in
  --version) echo "wm-build ${FAKE_WB_VERSION:-0.77.999}"; exit 0 ;;
  lint)
    f="$2"; s="$(basename "$f" .md)"; s="${s#PRD-}"
    echo "$s: live_acs=[2] acs=2 deferred=[]"; exit 0 ;;
  explain)
    shift; pd=""; sd=""; slug=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --prd-dir) pd="$2"; shift 2 ;; --state-dir) sd="$2"; shift 2 ;; *) slug="$1"; shift ;; esac
    done
    [ -f "$pd/build-queue/PRD-$slug.md" ] || { echo "wm-build: no PRD found for slug \"$slug\"" >&2; exit 1; }
    ans="$(awk -F'\t' -v s="$slug" '$1 == s { print $2 }' "$FAKE_WB_ANSWERS" | tail -1)"
    [ -n "$ans" ] || ans="tick-would: admit"
    case "$ans" in STDERR:*) echo "${ans#STDERR:}" >&2; exit 1 ;; SLEEP:*) echo "$$" > "$FAKE_WB_LOG.sleep-pid"; exec sleep "${ans#SLEEP:}" ;; esac
    printf '{\n  "slug": "%s",\n  "eligible": true,\n  "checks": [\n    {\n      "name": "status",\n      "passed": true,\n      "detail": "status=queued"\n    }\n  ]\n}\n' "$slug"
    echo "last-signature: none"
    echo "config-source: file"
    case "$ans" in
      *skip:prefix-denied*) echo 'check: prefix-denied passed=false {"reasons":["prefix-denied"]}' ;;
      *skip:depends-unresolved:*) d="${ans##*depends-unresolved:}"; d="${d%% *}"; echo "check: depends:$d passed=false {}" ;;
    esac
    [ "$ans" = NONE ] || echo "$ans"
    exit 0 ;;
esac
echo "fake wm-build: unexpected argv: $*" >&2; exit 64
EOS
  cat > "$DD_T/bin/probe" <<'EOS'
#!/usr/bin/env bash
# fake URL prober: `probe <METHOD> <url>` prints the canned status (default 200)
printf '%s %s\n' "$1" "$2" >> "$FAKE_PROBE_LOG"
ans="$(awk -F'\t' -v k="$1 $2" '$1 == k { print $2 }' "$FAKE_PROBE_ANSWERS" | tail -1)"
echo "${ans:-200}"
EOS
  chmod +x "$DD_T/bin/wm-build" "$DD_T/bin/probe"
  export HOME="$DD_T/home" TMPDIR="$DD_T/tmpd"
  export FAKE_WB_LOG="$DD_T/wb.log" FAKE_WB_ANSWERS="$DD_T/wb-answers"
  export FAKE_PROBE_LOG="$DD_T/probe.log" FAKE_PROBE_ANSWERS="$DD_T/probe-answers"
  export DREAM_DRYRUN_WM_BUILD="$DD_T/bin/wm-build" DREAM_DRYRUN_URL_PROBE="$DD_T/bin/probe"
  unset DREAM_PRD_DIR DREAM_LINT_WM_BUILD
}

# dd_prd <dir> <slug> [frontmatter line to add] [AC line to append] — a lint-clean
# copy of the shipped fixture under a new slug (and its own test_prefix).
dd_prd() {
  local dir="$1" slug="$2" fm="${3:-}" ac="${4:-}" tp
  tp="$(printf '%s' "$slug" | tr -cd 'a-z0-9')"
  sed -e "s/^# PRD — dreamdry-fixture:/# PRD — $slug:/" \
      -e "s/^- test_prefix: dreamdryfx$/- test_prefix: $tp/" \
      "$DD_FIXTURE" > "$dir/PRD-$slug.md"
  if [ -n "$fm" ]; then
    python3 -I - "$dir/PRD-$slug.md" "$fm" <<'PY'
import sys
p, line = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read().replace("- Drafted: 2026-11-15\n", "- Drafted: 2026-11-15\n" + line + "\n", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  fi
  [ -z "$ac" ] || printf '%s\n' "$ac" >> "$dir/PRD-$slug.md"
}

dd_answer() { printf '%s\t%s\n' "$1" "$2" >> "$DD_T/wb-answers"; }
dd_probe()  { printf '%s %s\t%s\n' "$1" "$2" "$3" >> "$DD_T/probe-answers"; }

# dd_run <args...> — runs the script; DD_OUT (stdout+stderr), DD_RC
dd_run() {
  DD_OUT="$(bash "$DD_SCRIPT" "$@" 2>&1)"; DD_RC=$?
}

# dd_line <slug> — the admit-would line for a slug
dd_line() { grep -E "^admit-would: $1 " <<<"$DD_OUT" | head -1; }

dd_expect_rc() { # <want> <label>
  if [ "$DD_RC" -eq "$1" ]; then dd_ok "$2: exit $1"; else dd_fail "$2: exit $DD_RC, want $1 :: $DD_OUT"; fi
}
dd_expect_line() { # <slug> <exact line> <label>
  local got; got="$(dd_line "$1")"
  if [ "$got" = "$2" ]; then dd_ok "$3: '$2'"; else dd_fail "$3: got '$got', want '$2' :: $DD_OUT"; fi
}
dd_expect_contains() { # <slug> <substring> <label>
  local got; got="$(dd_line "$1")"
  if [ -n "$got" ] && grep -qF -- "$2" <<<"$got"; then dd_ok "$3: line carries '$2'"; else dd_fail "$3: line '$got' lacks '$2' :: $DD_OUT"; fi
}

# dd_snapshot <dir> — path, mtime (ns) and size of every file under a tree, following symlinks
dd_snapshot() { find -L "$1" -type f -printf '%p %T@ %s\n' 2>/dev/null | sort; }

dd_tmp_empty() { # <label>
  if [ -z "$(ls -A "$DD_T/tmpd")" ]; then dd_ok "$1: temporary directory removed"; else dd_fail "$1: TMPDIR not empty: $(ls -A "$DD_T/tmpd")"; fi
}

dd_finish() {
  if [ "$DD_FAILS" -eq 0 ]; then echo "PASS $(basename "$0")"; exit 0; fi
  echo "FAILED $(basename "$0") ($DD_FAILS)"; exit 1
}
