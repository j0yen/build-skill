#!/usr/bin/env bash
# dream-lint.sh — /dream hook `dream.lint` (end of Phase 3, every PRD): lint the
# drafted PRD file(s) with every checker the fleet has, before they are persisted.
#
# Read-only. For each file, in order:
#   1. scripts/prd-lint.sh <file>             (this repo; FAIL => nonzero)
#   2. wm-build lint [--prd-dir <home>] <file>
#                                             (only when wm-build is on PATH; the
#                                              daemon's own contract lint; a
#                                              diagnostic exit => nonzero; its
#                                              Depends-on lookup reads the PRD
#                                              home's corpus, below)
#   3. whole-line byte check: any numbered AC line over 440 bytes is a WARN, a
#      margin under the 500-byte daemon intent-card cap that prd-lint already
#      FAILs (the cap is per AC text; the whole line also carries the number,
#      priority and Live tail, so the margin catches near-misses early).
#
# Usage:
#   dream-lint.sh [--prd-dir <PRD home>] <PRD file>...
#   dream-lint.sh --selftest
#
# PRD home: --prd-dir <dir> (or --prd-dir=<dir>, anywhere among the files), else
# $DREAM_PRD_DIR, the order dream-dryrun.sh and dream-scorecard.sh read (the /dream
# skill's PRD home is $DREAM_PRD_DIR first). It is passed to wm-build lint as
# --prd-dir, so Depends-on resolves in the corpus the PRD is drafted for. Neither
# given (an empty value counts as not given): no --prd-dir is passed and wm-build
# reads its own Config.prd_dir, as before. A PRD home that is not a directory is a
# usage error (exit 2) when wm-build runs. wm-build refuses a repeated --prd-dir
# (exit 2), so a caller whose DREAM_LINT_WM_BUILD command already names a corpus
# (dream-dryrun.sh's staged-corpus wrapper) sets neither.
#
# Env:
#   DREAM_PRD_DIR         PRD home when --prd-dir is not given (above)
#   DREAM_LINT_PRD_LINT   prd-lint script (default: sibling prd-lint.sh)
#   DREAM_LINT_WM_BUILD   wm-build command (default: `wm-build` from PATH; empty/absent = skipped)
#   DREAM_LINT_MARGIN     WARN byte margin (default 440)
#
# Exit: 0 no FAIL (WARNs allowed) | 1 any FAIL | 2 usage
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_LINT="${DREAM_LINT_PRD_LINT:-$HERE/prd-lint.sh}"
MARGIN="${DREAM_LINT_MARGIN:-440}"

lint_files() {
  local rc=0 f n=0 warns=0 home="" files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prd-dir) [ "$#" -ge 2 ] || { echo "dream-lint: --prd-dir needs a value" >&2; return 2; }; home="$2"; shift 2 ;;
      --prd-dir=*) home="${1#--prd-dir=}"; shift ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [ "${#files[@]}" -gt 0 ] || { echo "usage: dream-lint.sh [--prd-dir <PRD home>] <PRD file>..." >&2; return 2; }
  [ -n "$home" ] || home="${DREAM_PRD_DIR-}"
  local wb="${DREAM_LINT_WM_BUILD-}"
  if [ -z "${DREAM_LINT_WM_BUILD+x}" ]; then wb="$(command -v wm-build || true)"; fi
  if [ -n "$wb" ] && [ -n "$home" ] && [ ! -d "$home" ]; then
    echo "dream-lint: the PRD home is not a directory: $home" >&2; return 2
  fi
  for f in "${files[@]}"; do
    n=$((n+1))
    echo "== $f"
    if [ ! -f "$f" ]; then echo "FAIL dream-lint: no such file: $f"; rc=1; continue; fi
    local out prc
    out="$("$PRD_LINT" "$f" 2>&1)"; prc=$?
    echo "-- prd-lint (exit $prc)"; printf '%s\n' "$out"
    [ "$prc" -eq 0 ] || rc=1
    if [ -n "$wb" ]; then
      local wout wrc
      if [ -n "$home" ]; then wout="$($wb lint --prd-dir "$home" "$f" 2>&1)"; wrc=$?
      else wout="$($wb lint "$f" 2>&1)"; wrc=$?; fi
      echo "-- wm-build lint (exit $wrc)"; printf '%s\n' "$wout"
      [ "$wrc" -eq 0 ] || rc=1
    else
      echo "-- wm-build lint: skipped (wm-build not on PATH)"
    fi
    local over
    over="$(LC_ALL=C awk -v m="$MARGIN" '/^[0-9]+\. / { if (length($0) > m) printf "  WARN ac-line-bytes: line %d is %d bytes (> %d margin; daemon cap 500 per AC text)\n", NR, length($0), m }' "$f")"
    echo "-- ac-line-bytes (margin $MARGIN)"
    if [ -n "$over" ]; then printf '%s\n' "$over"; warns=$((warns+1)); else echo "  ok"; fi
  done
  echo "dream-lint: $n file(s), $([ "$rc" -eq 0 ] && echo "no FAIL" || echo "FAIL"), $warns file(s) with byte WARN"
  return $rc
}

selftest() {
  local t fails=0 total=0 out rc
  t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  unset DREAM_PRD_DIR   # the caller's PRD home must not reach the checks below
  cat > "$t/fake-prd-lint" <<'EOS'
#!/usr/bin/env bash
case "$1" in *bad*) echo "1. FAIL fake-id: nope"; exit 1 ;; *) echo OK; exit 0 ;; esac
EOS
  cat > "$t/fake-wm-build" <<'EOS'
#!/usr/bin/env bash
# argv to $FAKE_WB_ARGS; a repeated --prd-dir refused as wm-build 0.77.112 refuses it (exit 2)
printf '%s\n' "$*" >> "${FAKE_WB_ARGS:-/dev/null}"
n=0; for a in "$@"; do [ "$a" = --prd-dir ] && n=$((n+1)); done
[ "$n" -le 1 ] || { echo "error: the argument '--prd-dir <PRD_DIR>' cannot be used multiple times"; exit 2; }
case "${!#}" in *wmbad*) echo "rule failure"; exit 1 ;; *) echo "live_acs=[] acs=1"; exit 0 ;; esac
EOS
  chmod +x "$t/fake-prd-lint" "$t/fake-wm-build"
  printf -- '- Status: queued\n\n## Acceptance criteria\n\n1. P0 — short.\n' > "$t/PRD-ok.md"
  cp "$t/PRD-ok.md" "$t/PRD-bad.md"; cp "$t/PRD-ok.md" "$t/PRD-wmbad.md"
  printf -- '- Status: queued\n\n## Acceptance criteria\n\n1. P0 — %s.\n' "$(head -c 450 /dev/zero | tr '\0' x)" > "$t/PRD-long.md"
  export DREAM_LINT_PRD_LINT="$t/fake-prd-lint"; PRD_LINT="$DREAM_LINT_PRD_LINT"
  ck() { # $1=label $2=want-rc $3=pattern ; files via global FILES
    total=$((total+1))
    out="$(DREAM_LINT_WM_BUILD="${WB-$t/fake-wm-build}" lint_files "${@:4}" 2>&1)"; rc=$?
    if [ "$rc" -eq "$2" ] && { [ -z "$3" ] || grep -q -- "$3" <<<"$out"; }; then echo "ok: $1"; else echo "FAIL: $1 exit=$rc want $2 pattern '$3' :: $out"; fails=$((fails+1)); fi
  }
  ck "clean file -> 0" 0 "no FAIL" "$t/PRD-ok.md"
  ck "prd-lint FAIL -> 1" 1 "fake-id" "$t/PRD-ok.md" "$t/PRD-bad.md"
  ck "wm-build lint diagnostic -> 1" 1 "rule failure" "$t/PRD-wmbad.md"
  ck "450-byte AC line -> WARN, still 0" 0 "WARN ac-line-bytes" "$t/PRD-long.md"
  ck "missing file -> 1" 1 "no such file" "$t/none.md"
  WB="" ck "no wm-build -> skipped, 0" 0 "wm-build lint: skipped" "$t/PRD-ok.md"
  mkdir "$t/home" "$t/other"
  cka() { # $1=label $2=want-rc $3=want wm-build argv (one line per call) ; options and files via ${@:4}
    total=$((total+1)); : > "$t/args"
    out="$(FAKE_WB_ARGS="$t/args" DREAM_LINT_WM_BUILD="$t/fake-wm-build" lint_files "${@:4}" 2>&1)"; rc=$?
    local got; got="$(cat "$t/args")"
    if [ "$rc" -eq "$2" ] && [ "$got" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 exit=$rc want $2 argv '$got' want '$3' :: $out"; fails=$((fails+1)); fi
  }
  cka "neither -> no --prd-dir (wm-build's own Config.prd_dir)" 0 "lint $t/PRD-ok.md" "$t/PRD-ok.md"
  cka "--prd-dir <dir>, anywhere -> each call carries it" 0 "lint --prd-dir $t/home $t/PRD-ok.md
lint --prd-dir $t/home $t/PRD-long.md" "$t/PRD-ok.md" --prd-dir "$t/home" "$t/PRD-long.md"
  cka "--prd-dir=<dir>" 0 "lint --prd-dir $t/home $t/PRD-ok.md" "--prd-dir=$t/home" "$t/PRD-ok.md"
  DREAM_PRD_DIR="$t/home" cka "DREAM_PRD_DIR -> --prd-dir" 0 "lint --prd-dir $t/home $t/PRD-ok.md" "$t/PRD-ok.md"
  DREAM_PRD_DIR="$t/other" cka "--prd-dir outranks DREAM_PRD_DIR" 0 "lint --prd-dir $t/home $t/PRD-ok.md" --prd-dir "$t/home" "$t/PRD-ok.md"
  DREAM_PRD_DIR="$t/home" cka "an empty --prd-dir counts as not given" 0 "lint --prd-dir $t/home $t/PRD-ok.md" "--prd-dir=" "$t/PRD-ok.md"
  DREAM_PRD_DIR="$t/home" cka "the wm-build verdict still counts with a PRD home" 1 "lint --prd-dir $t/home $t/PRD-wmbad.md" "$t/PRD-wmbad.md"
  cka "a PRD home that is not a directory -> 2, nothing linted" 2 "" --prd-dir "$t/none" "$t/PRD-ok.md"
  DREAM_PRD_DIR="$t/none" cka "DREAM_PRD_DIR not a directory -> 2, nothing linted" 2 "" "$t/PRD-ok.md"
  cka "--prd-dir with no value -> 2" 2 "" "$t/PRD-ok.md" --prd-dir
  cka "--prd-dir and no file -> 2" 2 "" --prd-dir "$t/home"
  total=$((total+1))
  out="$(DREAM_PRD_DIR="$t/none" DREAM_LINT_WM_BUILD="" lint_files "$t/PRD-ok.md" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q "wm-build lint: skipped" <<<"$out"; then echo "ok: no wm-build -> the PRD home is unused, 0"; else echo "FAIL: no wm-build with a missing PRD home exit=$rc :: $out"; fails=$((fails+1)); fi
  total=$((total+1))
  "$t/fake-wm-build" lint --prd-dir a "$t/PRD-ok.md" --prd-dir b >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then echo "ok: control: the fake refuses a repeated --prd-dir"; else echo "FAIL: control: the fake accepted a repeated --prd-dir exit=$rc"; fails=$((fails+1)); fi
  total=$((total+1))
  "$0" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then echo "ok: no args -> exit 2"; else echo "FAIL: no args exit=$rc"; fails=$((fails+1)); fi
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
esac
lint_files "$@"
