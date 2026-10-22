#!/usr/bin/env bash
# dream-lint.sh — /dream hook `dream.lint` (end of Phase 3, every PRD): lint the
# drafted PRD file(s) with every checker the fleet has, before they are persisted.
#
# Read-only. For each file, in order:
#   1. scripts/prd-lint.sh <file>             (this repo; FAIL => nonzero)
#   2. wm-build lint <file>                   (only when wm-build is on PATH; the
#                                              daemon's own contract lint; a
#                                              diagnostic exit => nonzero)
#   3. whole-line byte check: any numbered AC line over 440 bytes is a WARN, a
#      margin under the 500-byte daemon intent-card cap that prd-lint already
#      FAILs (the cap is per AC text; the whole line also carries the number,
#      priority and Live tail, so the margin catches near-misses early).
#
# Usage:
#   dream-lint.sh <PRD file>...
#   dream-lint.sh --selftest
#
# Env:
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
  local rc=0 f n=0 warns=0
  [ "$#" -gt 0 ] || { echo "usage: dream-lint.sh <PRD file>..." >&2; return 2; }
  local wb="${DREAM_LINT_WM_BUILD-}"
  if [ -z "${DREAM_LINT_WM_BUILD+x}" ]; then wb="$(command -v wm-build || true)"; fi
  for f in "$@"; do
    n=$((n+1))
    echo "== $f"
    if [ ! -f "$f" ]; then echo "FAIL dream-lint: no such file: $f"; rc=1; continue; fi
    local out prc
    out="$("$PRD_LINT" "$f" 2>&1)"; prc=$?
    echo "-- prd-lint (exit $prc)"; printf '%s\n' "$out"
    [ "$prc" -eq 0 ] || rc=1
    if [ -n "$wb" ]; then
      local wout wrc
      wout="$($wb lint "$f" 2>&1)"; wrc=$?
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
  cat > "$t/fake-prd-lint" <<'EOS'
#!/usr/bin/env bash
case "$1" in *bad*) echo "1. FAIL fake-id: nope"; exit 1 ;; *) echo OK; exit 0 ;; esac
EOS
  cat > "$t/fake-wm-build" <<'EOS'
#!/usr/bin/env bash
case "$2" in *wmbad*) echo "rule failure"; exit 1 ;; *) echo "live_acs=[] acs=1"; exit 0 ;; esac
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
  total=$((total+1))
  "$0" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then echo "ok: no args -> exit 2"; else echo "FAIL: no args exit=$rc"; fails=$((fails+1)); fi
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
esac
lint_files "$@"
