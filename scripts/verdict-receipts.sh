#!/usr/bin/env bash
# verdict-receipts.sh — evidence contract for status-changing /build verdicts
# (PRD-build-verdict-receipts).
#
# Two consequential verdicts went out on one-shot, unverified observations
# on 2026-09-05/06: a "bisected regression" with no bisect ever run (the
# flake was green on re-run), and a "RedBaron unreachable" block from one
# unretried SSH probe while the host answered minutes before and after.
# This script is the deterministic half of the fix (the prose half lives
# in SKILL.md's Dispatch section) — belt and braces, since prose alone
# already failed twice.
#
# Reserved words, and what a receipt must prove before the word is used
# in a journal verdict line or a PRD `Blocked:` frontmatter value:
#   bisected      >=1 receipt whose command mentions `bisect` and whose
#                 output tail names a commit (a 7-40 hex token).
#   reproducible  >=2 receipts, both a nonzero exit, sharing a line of
#                 output (same failure, not two different ones).
#   flaky-infra   >=2 receipts (a red run + a later green/hang run) —
#                 not reserved in the sense of blocking anything, but a
#                 flaky-infra verdict with <2 records is just as
#                 unearned as a bare "reproducible" and is checked the
#                 same way.
#   unreachable / "ssh timeout"   (Blocked: values and block-ish journal
#                 lines only, never general prose) >=2 receipts of kind
#                 `probe` with started-at timestamps >=60s apart, PLUS
#                 >=1 receipt of kind `crosscheck` (a second target or a
#                 non-network sanity probe) — a sandboxed shell cannot
#                 brand a healthy host unreachable off a single probe.
#
# Receipt reference syntax on a line: one `receipt: <path>` token per
# receipt (comma-separate multiple `receipt: <path>` occurrences, one
# label per path — do not put several paths after a single label). A
# receipt file is one small self-describing text
# file (see `record` below): command, started-at, exit, hostname, and
# an output-tail section. Default receipts dir:
#   ~/brain/journal/build/receipts/<date>-<slug>-<kind>.txt
# overridable via $BUILD_RECEIPTS_DIR (tests use this).
#
# Usage:
#   verdict-receipts.sh record <kind> <slug> [--timeout <secs>] -- <cmd...>
#       Runs <cmd>, writes a receipt, prints its path on stdout.
#       If --timeout fires (exit 124), the receipt is written with
#       kind forced to `hang` regardless of the requested <kind> (a
#       timed-out re-run is a valid second record for reproducibility).
#   verdict-receipts.sh scan <journal-file|prd-file>
#       Scans the file for reserved-word claims and their receipts.
#       Exits 0 if every claim found is fully receipted (or none were
#       made), nonzero (= count of bad claims) otherwise, listing each
#       bad line on stdout as `FAIL <file>:<n> [<word>] <reason>`.
#   verdict-receipts.sh postflight <journal-file>
#       Same scan, but never fails the caller: on any bad claim it
#       appends one flag line to the SAME journal file naming the
#       claims, then always exits 0. Creates the receipts dir if it is
#       missing rather than treating that as an error.
#   verdict-receipts.sh summary <date>            # date = YYYY-MM-DD
#       Prints one table of that day's journal verdicts with receipt
#       status, for /self-review to journal.
#
# Exit codes: 0 ok | 1 usage | N (scan only) = number of bad claims.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_DIR="${BUILD_RECEIPTS_DIR:-$HOME/brain/journal/build/receipts}"

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_of() { date -u -d "$1" +%s 2>/dev/null; }

# ---------------------------------------------------------------------
# record <kind> <slug> [--timeout <secs>] -- <cmd...>
# ---------------------------------------------------------------------
cmd_record() {
  local kind="${1:-}" slug="${2:-}"; shift 2 2>/dev/null || true
  local timeout_secs=""
  while [ "${1:-}" != "--" ] && [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout_secs="$2"; shift 2 ;;
      *) echo "record: unexpected arg '$1' (want --timeout N or --)" >&2; return 1 ;;
    esac
  done
  [ "${1:-}" = "--" ] && shift
  if [ -z "$kind" ] || [ -z "$slug" ] || [ $# -eq 0 ]; then
    echo "usage: verdict-receipts.sh record <kind> <slug> [--timeout <secs>] -- <cmd...>" >&2
    return 1
  fi
  mkdir -p "$RECEIPTS_DIR" || { echo "record: cannot create $RECEIPTS_DIR" >&2; return 1; }

  local started; started="$(utc_now)"
  local out; out="$(mktemp)"
  local rc
  if [ -n "$timeout_secs" ]; then
    timeout "$timeout_secs" "$@" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      kind="hang"
    fi
  else
    "$@" >"$out" 2>&1
    rc=$?
  fi

  local date_part; date_part="$(date -u +%Y-%m-%d)"
  local dest="$RECEIPTS_DIR/${date_part}-${slug}-${kind}.txt"
  # never silently collide two receipts of the same kind in one day
  if [ -e "$dest" ]; then
    dest="$RECEIPTS_DIR/${date_part}-${slug}-${kind}-$(date -u +%H%M%S).txt"
  fi
  {
    printf 'command: %s\n' "$*"
    printf 'started-at: %s\n' "$started"
    printf 'exit: %s\n' "$rc"
    printf 'hostname: %s\n' "$(hostname)"
    printf 'output-tail:\n'
    tail -n 40 "$out"
  } > "$dest"
  rm -f "$out"
  echo "$dest"
  return 0
}

# ---------------------------------------------------------------------
# helpers for scan
# ---------------------------------------------------------------------

# Extract every path following a `receipt:` token on a line into the
# global array RECEIPT_PATHS. Convention: one `receipt:` label per path
# (`receipt: p1, receipt: p2`, comma optional) — each occurrence is
# found in turn by the outer loop, so paths are never ambiguous with a
# label word.
extract_receipts() {
  local line="$1"
  RECEIPT_PATHS=()
  local rest="$line"
  while [[ "$rest" == *receipt:* ]]; do
    rest="${rest#*receipt:}"
    # skip leading spaces
    rest="${rest#"${rest%%[![:space:]]*}"}"
    # take up to next whitespace or comma, then trim trailing punctuation
    # a journal `(...)` wrapper or sentence leaves on the last path in a list
    local tok="${rest%%[[:space:],]*}"
    while [[ "$tok" == *')' || "$tok" == *'.' ]]; do
      tok="${tok%?}"
    done
    [ -n "$tok" ] && RECEIPT_PATHS+=("$tok")
    rest="${rest#"$tok"}"
  done
}

receipt_kind_of() { # <path> -> kind, from <date>-<slug>-<kind>[-<disambig>].txt
  local base; base="$(basename "$1" .txt)"
  local last="${base##*-}"
  # a same-day/same-kind collision gets a purely-numeric disambiguating
  # suffix (record's own HHMMSS, or a fixture's manual "-2"); skip past
  # it so the kind itself is still recovered.
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    base="${base%-*}"
    last="${base##*-}"
  fi
  echo "$last"
}

# check_bisected <line> -> 0 pass / 1 fail; sets FAIL_REASON
check_bisected() {
  local line="$1"
  extract_receipts "$line"
  if [ "${#RECEIPT_PATHS[@]}" -lt 1 ]; then
    FAIL_REASON="missing receipt: bisected requires a bisect-log receipt (git bisect log naming the guilty commit), none referenced"
    return 1
  fi
  local p
  for p in "${RECEIPT_PATHS[@]}"; do
    [ -f "$p" ] || continue
    if grep -qi 'bisect' "$p" && grep -Eoq '[0-9a-f]{7,40}' "$p"; then
      return 0
    fi
  done
  FAIL_REASON="malformed receipt: bisected — no referenced receipt has a 'bisect' command and a commit hash in its output tail"
  return 1
}

check_reproducible() {
  local line="$1"
  extract_receipts "$line"
  if [ "${#RECEIPT_PATHS[@]}" -lt 2 ]; then
    FAIL_REASON="missing receipt: reproducible requires >=2 recorded runs, ${#RECEIPT_PATHS[@]} referenced"
    return 1
  fi
  local exits=() tails=()
  local p
  for p in "${RECEIPT_PATHS[@]}"; do
    if [ ! -f "$p" ]; then
      FAIL_REASON="malformed receipt: reproducible — referenced receipt '$p' does not exist"
      return 1
    fi
    exits+=("$(grep -m1 '^exit:' "$p" | awk '{print $2}')")
    tails+=("$(sed -n '/^output-tail:/,$p' "$p" | tail -n +2)")
  done
  local nonzero=0
  for e in "${exits[@]}"; do
    [ "$e" != "0" ] && [ -n "$e" ] && nonzero=$((nonzero+1))
  done
  if [ "$nonzero" -lt 2 ]; then
    FAIL_REASON="malformed receipt: reproducible — fewer than 2 referenced receipts recorded a nonzero exit"
    return 1
  fi
  # require some shared line of output between the first two receipts
  # (same failure, not two unrelated ones)
  local shared=0 l
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    if grep -qF -- "$l" <<<"${tails[1]}"; then shared=1; break; fi
  done <<<"${tails[0]}"
  if [ "$shared" -eq 0 ]; then
    FAIL_REASON="malformed receipt: reproducible — referenced receipts share no output line (looks like two different failures)"
    return 1
  fi
  return 0
}

check_flaky_infra() {
  local line="$1"
  extract_receipts "$line"
  if [ "${#RECEIPT_PATHS[@]}" -lt 2 ]; then
    FAIL_REASON="missing receipt: flaky-infra requires the red run + the re-run, ${#RECEIPT_PATHS[@]} referenced"
    return 1
  fi
  local p
  for p in "${RECEIPT_PATHS[@]}"; do
    [ -f "$p" ] || { FAIL_REASON="malformed receipt: flaky-infra — referenced receipt '$p' does not exist"; return 1; }
  done
  return 0
}

check_unreachable() {
  local line="$1"
  extract_receipts "$line"
  local probes=() crosschecks=()
  local p kind
  for p in "${RECEIPT_PATHS[@]}"; do
    if [ ! -f "$p" ]; then
      FAIL_REASON="malformed receipt: unreachable — referenced receipt '$p' does not exist"
      return 1
    fi
    kind="$(receipt_kind_of "$p")"
    case "$kind" in
      probe) probes+=("$p") ;;
      crosscheck) crosschecks+=("$p") ;;
    esac
  done
  if [ "${#probes[@]}" -lt 2 ]; then
    FAIL_REASON="missing receipt: unreachable requires >=2 probe receipts >=60s apart, ${#probes[@]} referenced"
    return 1
  fi
  if [ "${#crosschecks[@]}" -lt 1 ]; then
    FAIL_REASON="missing receipt: unreachable requires >=1 crosscheck receipt (second target or non-network sanity probe), 0 referenced"
    return 1
  fi
  local t1 t2
  t1="$(grep -m1 '^started-at:' "${probes[0]}" | awk '{print $2}')"
  t2="$(grep -m1 '^started-at:' "${probes[1]}" | awk '{print $2}')"
  local e1 e2; e1="$(epoch_of "$t1")"; e2="$(epoch_of "$t2")"
  if [ -z "$e1" ] || [ -z "$e2" ]; then
    FAIL_REASON="malformed receipt: unreachable — probe started-at timestamps unparseable"
    return 1
  fi
  local diff=$(( e2 > e1 ? e2 - e1 : e1 - e2 ))
  if [ "$diff" -lt 60 ]; then
    FAIL_REASON="malformed receipt: unreachable — probes only ${diff}s apart, need >=60s"
    return 1
  fi
  return 0
}

# scan_line <file> <line_no> <line> -> appends to global BAD_LINES on failure
scan_line() {
  local file="$1" n="$2" line="$3"
  if grep -qiE '\bbisected\b' <<<"$line"; then
    if ! check_bisected "$line"; then
      BAD_LINES+=("FAIL $file:$n [bisected] $FAIL_REASON")
    fi
  fi
  if grep -qiE '\breproducible\b' <<<"$line"; then
    if ! check_reproducible "$line"; then
      BAD_LINES+=("FAIL $file:$n [reproducible] $FAIL_REASON")
    fi
  fi
  if grep -qiE '\bflaky-infra\b' <<<"$line"; then
    if ! check_flaky_infra "$line"; then
      BAD_LINES+=("FAIL $file:$n [flaky-infra] $FAIL_REASON")
    fi
  fi
  if grep -qiE '\bunreachable\b|\bssh timeout\b' <<<"$line"; then
    if ! check_unreachable "$line"; then
      BAD_LINES+=("FAIL $file:$n [unreachable] $FAIL_REASON")
    fi
  fi
}

# ---------------------------------------------------------------------
# scan <file>
# ---------------------------------------------------------------------
cmd_scan() {
  local file="${1:-}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "scan: file not found: $file" >&2
    return 1
  fi
  mkdir -p "$RECEIPTS_DIR" 2>/dev/null || true

  BAD_LINES=()
  local scanned=0
  local base; base="$(basename "$file")"
  if [[ "$base" == PRD-* ]]; then
    # PRD file: only frontmatter Blocked: values are in scope, never body prose.
    local n=0 line
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n+1))
      if [[ "$line" =~ ^-?[[:space:]]*Blocked:[[:space:]]*(.*)$ ]]; then
        scanned=$((scanned+1))
        scan_line "$file" "$n" "$line"
      fi
    done < "$file"
  else
    # journal file: every non-empty, non-comment line is a verdict line.
    local n=0 line
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n+1))
      [ -z "$line" ] && continue
      [[ "$line" == \#* ]] && continue
      scanned=$((scanned+1))
      scan_line "$file" "$n" "$line"
    done < "$file"
  fi

  if [ "${#BAD_LINES[@]}" -eq 0 ]; then
    echo "PASS $file ($scanned line(s) scanned, 0 issues)"
    return 0
  fi
  local b
  for b in "${BAD_LINES[@]}"; do echo "$b"; done
  echo "FAIL $file: ${#BAD_LINES[@]} unreceipted claim(s) of $scanned line(s) scanned"
  return "${#BAD_LINES[@]}"
}

# ---------------------------------------------------------------------
# postflight <journal-file> — never fails the tick; flags in place.
# ---------------------------------------------------------------------
cmd_postflight() {
  local file="${1:-}"
  if [ -z "$file" ]; then
    echo "usage: verdict-receipts.sh postflight <journal-file>" >&2
    return 0
  fi
  mkdir -p "$RECEIPTS_DIR" 2>/dev/null || true
  if [ ! -f "$file" ]; then
    return 0
  fi
  local out rc
  out="$(cmd_scan "$file")"
  rc=$?
  if [ "$rc" -gt 0 ]; then
    {
      printf '%s  verdict-receipts  postflight-flag  %d unreceipted verdict(s)  (' "$(utc_now)" "$rc"
      printf '%s' "$out" | grep '^FAIL ' | grep -v ' unreceipted claim' | tr '\n' ';' | sed 's/;$//'
      printf ')\n'
    } >> "$file"
  fi
  return 0
}

# ---------------------------------------------------------------------
# summary <date>
# ---------------------------------------------------------------------
cmd_summary() {
  local date="${1:-}"
  local journal="${BUILD_JOURNAL_DIR:-$HOME/brain/journal/build}/${date}.md"
  if [ ! -f "$journal" ]; then
    echo "summary: no journal for $date at $journal"
    return 1
  fi
  printf '%-20s %-30s %-14s %-24s %s\n' "TIME" "SLUG" "ACTION" "OUTCOME" "RECEIPT-STATUS"
  local n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    local ts slug action outcome
    ts="$(awk '{print $1}' <<<"$line")"
    slug="$(awk '{print $2}' <<<"$line")"
    action="$(awk '{print $3}' <<<"$line")"
    outcome="$(awk '{print $4}' <<<"$line")"
    local status="ok"
    if grep -qiE '\bbisected\b|\breproducible\b|\bflaky-infra\b|\bunreachable\b|\bssh timeout\b' <<<"$line"; then
      BAD_LINES=()
      scan_line "$journal" "$n" "$line"
      if [ "${#BAD_LINES[@]}" -gt 0 ]; then status="missing-or-malformed"; else status="receipted"; fi
    else
      status="none-needed"
    fi
    printf '%-20s %-30s %-14s %-24s %s\n' "$ts" "$slug" "$action" "$outcome" "$status"
  done < "$journal"
  return 0
}

# ---------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    record)      cmd_record "$@" ;;
    scan)        cmd_scan "$@" ;;
    postflight)  cmd_postflight "$@" ;;
    summary)     cmd_summary "$@" ;;
    *)
      echo "usage: verdict-receipts.sh {record|scan|postflight|summary} ..." >&2
      return 1
      ;;
  esac
}

main "$@"
