#!/usr/bin/env bash
# verified-completed.sh — Phase 5 archive-gate check #5 per
# PRD-build-deferred-acs.md, extended by PRD-build-archive-autopair.md to
# DERIVE AC-to-test pairing from the repo instead of requiring the caller
# to assert it. Classifies every AC in a PRD as PAIRED, DEFERRED, or
# MISSING (or PAIRED-FAILING under --verify-run), and exits non-zero when
# any AC is MISSING or PAIRED-FAILING.
#
# Usage:
#   verified-completed.sh <PRD-path> [--derive|--no-derive] [--verify-run]
#       [--paired N,N,...] [--format text|json|table]
#       [--doctor] [--paired-with N=<evidence>]... [--reasons-json '{...}']
#
# Inputs:
#   <PRD-path>             absolute or relative path to a PRD-*.md file.
#   --derive               Derive AC->test pairing from the repo (see
#                          "Derivation" below). This is the DEFAULT when
#                          --paired is absent. When --paired IS given,
#                          derivation is off by default (exact legacy
#                          behavior) unless --derive is also passed —
#                          in that combined mode, --paired only ADDS
#                          coverage for ACs the derivation didn't find
#                          (labeled `asserted`); it never overrides or
#                          removes a derived pairing.
#   --no-derive            Force legacy (non-derived) behavior even when
#                          --paired is absent. Rarely needed.
#   --paired N,N,...       comma-separated list of AC numbers that the
#                          caller asserts are paired with a passing
#                          test. See --derive above for how this composes
#                          with derivation.
#   --verify-run           For each AC paired to a real file (not an
#                          `asserted` pairing), run just that test
#                          (`cargo test --test <stem> [<fn>]` for .rs,
#                          `python3 -m pytest <path>[::<fn>]` for .py).
#                          A non-zero exit marks the AC PAIRED-FAILING
#                          (still shown as such in all formats) and the
#                          script exits non-zero, so a stale test file
#                          cannot pair silently. P1 (AC7).
#   --format text|json|table  output format (default: text).
#   --doctor               human-readable per-AC audit (AC6/§6 of the
#                          PRD). Each line is `AC<N>: <STATUS><pad> —
#                          <evidence or reason>`. STATUS is one of
#                          PAIRED, DEFERRED, MISSING; padded to width 8
#                          so the em-dashes align. Evidence comes from
#                          --paired-with, else the derived path (if any),
#                          else `(no test)`; reason comes from
#                          --reasons-json or scan-prds' deferred_ac_
#                          reasons; missing evidence shows `(no test)`
#                          and missing reason shows `(no reason given)`.
#                          Implies --format=text; ignored under json/table.
#   --paired-with N=<evi>  repeatable: maps AC number N to a free-form
#                          evidence string for --doctor. Splits on the
#                          first `=` so evidence may contain `=`. Does
#                          NOT promote an AC to PAIRED on its own —
#                          --paired/derivation is still the authoritative
#                          classifier.
#   --reasons-json '{...}' optional: override the `deferred_ac_reasons`
#                          map from scan-prds.sh (which currently
#                          stubs to `{}`). Same shape as the matching
#                          flag in archive-trailer.sh.
#
# Derivation (--derive):
#   1. Resolve the build repo: the PRD's `build_into:` frontmatter, else
#      $MANIFEST's (default state/manifest.json) `output_repo_path` for
#      this slug, else `~/wintermute/<slug>`. If nothing resolves to an
#      existing directory, every AC derives to MISSING (no crash).
#   2. Resolve candidate test-file prefixes: the PRD's `test_prefix:`
#      frontmatter (bare scalar or `[a, b]` list — scan-prds.sh parses
#      it), else ONE slug-derived candidate: strip the repo's basename
#      (crate name) + `-` from the slug if present, split the remainder
#      on `-`, and take the last token — UNLESS that token is a generic,
#      non-discriminating collective word (currently just `tools`, since
#      several sibling extend PRDs on the same crate end `-tools`), in
#      which case take the second-to-last token instead. Examples:
#      `mcphost-rest-tools` (crate `mcphost`) -> `rest`; `mcphost-code-
#      tools` -> `code`; `ac-judge-pluggable-backend` (crate `ac-judge`)
#      -> `backend`. This is a fallback guess, not a naming authority —
#      a PRD whose real convention doesn't match its slug (e.g. rest-
#      tools' tests are actually `http_ac*`) MUST declare `test_prefix:`
#      to be found; see build-contract.md.
#   3. For each AC 1..N, try rules in this order, first match wins (the
#      `rule` column names which one fired):
#        a. `prefix:<p>`  — `tests/<p>_ac<N>_*.rs` or `_ac<NN>_*.rs` (and
#           `.py`), for each candidate prefix `<p>` in order. Tried BEFORE
#           the bare rule below — deliberately, and NOT the literal order
#           the PRD prose lists them in. Rationale: on a shared crate,
#           tests/ can hold a bare `ac01_*.rs`..`ac19_*.rs` series that
#           belongs to a DIFFERENT PRD entirely (mcphost's base PRD, for
#           instance). If the bare rule were tried first, an extend PRD
#           whose own tests are `http_ac01_*.rs`..`http_ac13_*.rs` would
#           false-positive-pair AC1 to the unrelated bare `ac01_*.rs`
#           file. Trying the more specific (prefixed) rule first is the
#           whole point of this PRD's TL;DR ("a per-PRD prefix for shared
#           crates") and is what AC1 (mcphost-rest-tools, `http_` prefix)
#           requires in practice.
#        b. `bare`        — `tests/ac<N>_*.rs` / `ac<NN>_*.rs` (and .py).
#        c. `acceptance_ac` — `tests/acceptance_ac<N>.rs` (and .py).
#        d. `mocks`       — `tests/mocks/ac<N>.rs` (and .py).
#        e. `fn-scan`     — a `#[test]` Rust fn whose name starts with
#           `ac<N>_` or `ac0<N>_`, or a `def test_ac<N>_...` / `def
#           test_ac_<N>_...` (both separator styles observed in the
#           fleet), anywhere under tests/. Last resort, whole-tree scan.
#   4. `deferred_acs` is read only in the contract's list form (scan-
#      prds.sh). A prose value is reported as `deferred_acs: unparsed —
#      use [N, N]` (once, on stdout) and treated as none — the ACs that
#      would have been deferred fall through to MISSING instead of being
#      silently swallowed.
#
# No-match / cross-PRD-collision guards (PRD-build-verified-completed-no-
# match-mispair, closing two false-PASS defects hand-caught 2026-09-06):
#   5. A DECLARED `test_prefix:` (non-empty frontmatter, as opposed to the
#      slug-derived GUESS used when the PRD has none) is treated as an
#      author assertion of this PRD's own naming convention. If rule (a)
#      finds no match under any declared prefix, the AC is MISSING —
#      rules (b)-(e) never run for that PRD. A guessed prefix keeps the
#      old fallback behavior (no author signal to trust instead). Without
#      this, a declared-but-wrong-or-absent prefix silently fell through
#      to `bare`/`fn-scan` and could pair to a different PRD's tests
#      sharing the same crate's tests/ directory (observed: mcphost-ci-
#      sandbox-coverage's declared `ci_sandbox` prefix had zero matches
#      and `bare`-paired all 7 ACs to the unrelated base PRD's ac01-07).
#   6. `bare` and `fn-scan` matches are scoped against sibling PRDs in the
#      same repo (any other PRD, built or queued, whose `build_into`
#      resolves to this repo) that themselves DECLARE a `test_prefix`: if
#      the matched file's basename fits `<sibling-prefix>_ac<N>[_...].{rs,
#      py}` for a prefix that isn't one of this PRD's own candidates, that
#      file is disqualified as THIS PRD's pairing — it is surfaced as
#      classification `ac-number-collision` (naming the file and the
#      other PRD, in text/table/json/doctor output) instead of a silent
#      pair or a silent MISSING (observed: `fn-scan` paired mcphost-
#      harness-judge-calibration's AC6 to mcphost-harness-live-gold's own
#      `live_gold_ac6_*` file purely because both happened to number an
#      unrelated requirement "6"). `ac-number-collision` counts as a
#      failure for exit-code purposes, same as MISSING.
#
# Behavior (unchanged from prior versions):
#   1. Counts ACs by scanning the PRD's `## Acceptance` (or
#      `## Acceptance criteria` / `## Acceptance tests`) section for
#      lines like `^N. `.
#   2. Resolves `deferred_acs` (and, under --doctor, `deferred_ac_
#      reasons`) via scan-prds.sh, scoped to the PRD's parent directory.
#   3. For each AC 1..N: PAIRED if N is derived-paired or in --paired;
#      otherwise DEFERRED if N ∈ deferred_acs; otherwise MISSING.
#   4. Emits classifications on stdout. On any MISSING (or, under
#      --verify-run, PAIRED-FAILING) AC, also emits `AC<N>: not paired
#      (and not declared deferred)` / `AC<N>: PAIRED-FAILING` lines on
#      stderr and exits 1. Exit 0 when every AC is PAIRED or DEFERRED
#      (and, under --verify-run, no PAIRED test actually failed).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-prds.sh"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
MANIFEST="${MANIFEST:-$SKILL_DIR/state/manifest.json}"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"

usage() {
  sed -n '2,121p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

prd=""
paired_csv=""
format=text
doctor=false
reasons_json=""
derive_mode=auto   # auto | on | off
verify_run=false
declare -a paired_with_kv=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paired) paired_csv="${2:-}"; shift 2 ;;
    --paired=*) paired_csv="${1#--paired=}"; shift ;;
    --derive) derive_mode=on; shift ;;
    --no-derive) derive_mode=off; shift ;;
    --verify-run) verify_run=true; shift ;;
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#--format=}"; shift ;;
    --doctor) doctor=true; shift ;;
    --paired-with) paired_with_kv+=("${2:-}"); shift 2 ;;
    --paired-with=*) paired_with_kv+=("${1#--paired-with=}"); shift ;;
    --reasons-json) reasons_json="${2:-}"; shift 2 ;;
    --reasons-json=*) reasons_json="${1#--reasons-json=}"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "verified-completed: unknown flag $1" >&2; exit 2 ;;
    *) prd="$1"; shift ;;
  esac
done

[ -n "$prd" ] || { echo "verified-completed: PRD path required" >&2; exit 2; }
[ -r "$prd" ] || { echo "verified-completed: $prd not readable" >&2; exit 2; }
[ -x "$SCAN" ] || { echo "verified-completed: $SCAN not executable" >&2; exit 2; }
[ -x "$JQ" ] || { echo "verified-completed: jq not at $JQ" >&2; exit 2; }
case "$format" in text|json|table) ;; *) echo "verified-completed: bad --format $format" >&2; exit 2 ;; esac

# --derive defaults to on when --paired is absent (requirement 1); when
# --paired IS given, default is legacy (off) unless --derive is explicit.
if [ "$derive_mode" = auto ]; then
  if [ -n "$paired_csv" ]; then derive_mode=off; else derive_mode=on; fi
fi

base="$(basename "$prd")"
slug="${base#PRD-}"; slug="${slug%.md}"
prd_dir="$(cd "$(dirname "$prd")" && pwd)"

# scan-prds.sh emits deferred_acs, deferred_acs_unparsed, test_prefix,
# and build_into (see iter-1 + PRD-build-archive-autopair AC1-3).
json="$(PRD_DIR="$prd_dir" "$SCAN")" || {
  echo "verified-completed: scan-prds.sh failed" >&2; exit 2; }
deferred="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .deferred_acs // []' <<<"$json")"
[ -n "$deferred" ] || deferred="[]"
deferred_unparsed="$("$JQ" -r --arg s "$slug" '.[] | select(.slug==$s) | .deferred_acs_unparsed // false' <<<"$json")"
[ -n "$deferred_unparsed" ] || deferred_unparsed="false"

if [ "$doctor" = true ]; then
  if [ -n "$reasons_json" ]; then
    reasons="$reasons_json"
  else
    reasons="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .deferred_ac_reasons // {}' <<<"$json")"
    [ -n "$reasons" ] || reasons="{}"
  fi
fi

# Count ACs by scanning the Acceptance heading.
num_acs="$(awk '
  # Match `## Acceptance...` or `## N. Acceptance...` (any trailing words).
  /^##[[:space:]]+([[:digit:]]+\.[[:space:]]+)?Acceptance/ { in_block=1; next }
  /^##[[:space:]]/ && in_block            { in_block=0 }
  in_block && /^[[:digit:]]+\.[[:space:]]/ { n++ }
  END { print n+0 }
' "$prd")"

if [ "$num_acs" -le 0 ]; then
  echo "verified-completed: no ACs found in $prd" >&2; exit 2
fi

declare -A is_paired is_deferred reason_for paired_evidence
declare -A derived_rule derived_path is_failing
declare -A fnscan_path
declare -A collision_rule collision_path collision_owner_slug

# ---- --derive: resolve repo + prefix candidates, classify each AC -----
resolve_repo() {
  local build_into manifest_repo
  build_into="$("$JQ" -r --arg s "$slug" '.[] | select(.slug==$s) | .build_into // empty' <<<"$json")"
  if [ -n "$build_into" ] && [ -d "$build_into" ]; then printf '%s\n' "$build_into"; return; fi
  if [ -r "$MANIFEST" ]; then
    manifest_repo="$("$JQ" -r --arg s "$slug" '.prds[]? | select(.slug==$s) | .output_repo_path // empty' "$MANIFEST" 2>/dev/null)"
    if [ -n "$manifest_repo" ] && [ -d "$manifest_repo" ]; then printf '%s\n' "$manifest_repo"; return; fi
  fi
  printf '%s\n' "$HOME/wintermute/$slug"
}

derive_prefix_candidates() {
  local tp n crate rest last ntoks
  tp="$("$JQ" -c --arg s "$slug" '.[] | select(.slug==$s) | .test_prefix // []' <<<"$json")"
  n="$("$JQ" 'length' <<<"$tp" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    "$JQ" -r '.[]' <<<"$tp"
    return
  fi
  # Slug-derived fallback (see header comment "Derivation" step 2).
  crate="$(basename "$repo")"
  rest="$slug"
  case "$slug" in
    "$crate"-*) rest="${slug#"$crate"-}" ;;
  esac
  [ -n "$rest" ] || return 0
  IFS='-' read -ra toks <<<"$rest"
  ntoks="${#toks[@]}"
  [ "$ntoks" -gt 0 ] || return 0
  last="${toks[$((ntoks-1))]}"
  case "$last" in
    tools)
      if [ "$ntoks" -ge 2 ]; then printf '%s\n' "${toks[$((ntoks-2))]}"; fi
      ;;
    *) printf '%s\n' "$last" ;;
  esac
}

# collision_owner <relpath> <n> — does <relpath>'s basename fit a SIBLING
# PRD's own DECLARED test_prefix naming convention for AC<n> (see header
# guard 6)? Prints the owning sibling's slug and returns 0 if so; prints
# nothing and returns 1 otherwise. A sibling prefix that's also one of
# THIS PRD's own prefix_candidates is never a collision (that's just this
# PRD legitimately using the same convention).
collision_owner() {
  local relpath="$1" n="$2" padded="" base p numform mine mp
  [ "$n" -lt 10 ] && padded="0$n"
  base="$(basename "$relpath")"
  for p in "${!sib_prefix_owner[@]}"; do
    [ -n "$p" ] || continue
    mine=0
    for mp in "${prefix_candidates[@]:-}"; do
      [ "$mp" = "$p" ] && { mine=1; break; }
    done
    [ "$mine" = 1 ] && continue
    for numform in "$n" "$padded"; do
      [ -n "$numform" ] || continue
      case "$base" in
        "${p}_ac${numform}_"*.rs|"${p}_ac${numform}_"*.py|"${p}_ac${numform}.rs"|"${p}_ac${numform}.py")
          printf '%s\n' "${sib_prefix_owner[$p]}"
          return 0
          ;;
      esac
    done
  done
  return 1
}

# find_collision <n> — is there ANY file in tests/ that fits a SIBLING
# PRD's own declared test_prefix convention for AC<n>? Unlike
# collision_owner (which validates a file THIS PRD's own rules already
# matched), this actively searches — used when this PRD's own declared
# prefix found nothing at all, to tell "genuinely no test exists yet"
# apart from "the test exists, but under a different PRD's number-sharing
# convention" (see header guard 6; this is what closes the judge-
# calibration/live-gold AC6 collision, where the declared-prefix-zero-
# match short-circuit below would otherwise report a bare MISSING and
# never even look at fn-scan's index). Prints "<owner-slug>\t<relpath>"
# and returns 0 on a hit; nothing and returns 1 otherwise.
find_collision() {
  local n="$1" padded="" p numform matches f mine mp
  [ "$n" -lt 10 ] && padded="0$n"
  shopt -s nullglob
  for p in "${!sib_prefix_owner[@]}"; do
    [ -n "$p" ] || continue
    mine=0
    for mp in "${prefix_candidates[@]:-}"; do
      [ "$mp" = "$p" ] && { mine=1; break; }
    done
    [ "$mine" = 1 ] && continue
    for numform in "$n" "$padded"; do
      [ -n "$numform" ] || continue
      matches=( "$repo/tests/${p}_ac${numform}_"*.rs "$repo/tests/${p}_ac${numform}_"*.py )
      if [ "${#matches[@]}" -eq 0 ]; then
        [ -f "$repo/tests/${p}_ac${numform}.rs" ] && matches=( "$repo/tests/${p}_ac${numform}.rs" )
      fi
      if [ "${#matches[@]}" -eq 0 ]; then
        [ -f "$repo/tests/${p}_ac${numform}.py" ] && matches=( "$repo/tests/${p}_ac${numform}.py" )
      fi
      if [ "${#matches[@]}" -gt 0 ]; then
        f="${matches[0]#"$repo"/}"
        shopt -u nullglob
        printf '%s\t%s\n' "${sib_prefix_owner[$p]}" "$f"
        return 0
      fi
    done
  done
  shopt -u nullglob
  return 1
}

classify_ac() {
  local n="$1" padded="" repo_tests="$repo/tests" f p numform matches ext other
  [ "$n" -lt 10 ] && padded="0$n"
  if [ ! -d "$repo_tests" ]; then printf 'MISSING|||\n'; return; fi

  shopt -s nullglob
  # a. prefix rule — tried first; see header "Derivation" step 3a.
  for p in "${prefix_candidates[@]}"; do
    [ -n "$p" ] || continue
    for numform in "$n" "$padded"; do
      [ -n "$numform" ] || continue
      # Two shapes observed in the fleet: `<p>_ac<N>_<description>.rs`
      # (mcphost: http_ac01_secret_redaction.rs) and bare `<p>_ac<N>.rs`
      # with no trailing description (ac-judge: backend_ac1.rs). The two
      # globbed (wildcard) forms are nullglob-safe; the two exact
      # (no-wildcard) forms are checked with `-f` since nullglob only
      # elides patterns that contain glob metacharacters and would leave
      # a literal nonexistent path in the array untouched otherwise.
      matches=( "$repo_tests/${p}_ac${numform}_"*.rs "$repo_tests/${p}_ac${numform}_"*.py )
      if [ "${#matches[@]}" -eq 0 ]; then
        [ -f "$repo_tests/${p}_ac${numform}.rs" ] && matches=( "$repo_tests/${p}_ac${numform}.rs" )
      fi
      if [ "${#matches[@]}" -eq 0 ]; then
        [ -f "$repo_tests/${p}_ac${numform}.py" ] && matches=( "$repo_tests/${p}_ac${numform}.py" )
      fi
      if [ "${#matches[@]}" -gt 0 ]; then
        f="${matches[0]#"$repo"/}"
        shopt -u nullglob
        printf 'PAIRED|prefix:%s|%s|\n' "$p" "$f"
        return
      fi
    done
  done
  # A DECLARED test_prefix with no match under it is MISSING, full stop —
  # never falls through to (b)-(e). See header guard 5. A GUESSED prefix
  # (declared_prefix=0) still falls through, matching prior behavior. One
  # exception: check find_collision first, so a real file that exists
  # only under a SIBLING PRD's own declared prefix is reported as a
  # collision, not a bare MISSING (header guard 6 / bug #2).
  if [ "${declared_prefix:-0}" = 1 ]; then
    shopt -u nullglob
    if hit="$(find_collision "$n")"; then
      other="${hit%%$'\t'*}"; f="${hit#*$'\t'}"
      printf 'COLLISION|declared-prefix-no-match|%s|%s\n' "$f" "$other"
      return
    fi
    printf 'MISSING|||\n'
    return
  fi
  # b. bare ac<N> — SKIPPED when this PRD has a working (guessed) prefix
  # (see prefix_rule_active, set by a pre-pass before this function is
  # called per-AC). Rationale: on a shared crate, a PRD that pairs MOST of
  # its ACs via `<prefix>_ac<N>` (e.g. python_ac01..14) but has a few
  # deferred/leftover ACs the prefix rule didn't cover (e.g. 15, 16) must
  # NOT let those leftovers fall through to the bare rule — tests/ac15_
  # *.rs / ac16_*.rs almost certainly belong to a DIFFERENT PRD on the
  # same crate (mcphost's own base numbering), and matching them would
  # silently un-defer an AC the PRD explicitly declared has no real test
  # (observed live: PRD-mcphost-code-tools AC15/16, deferred, would
  # false-pair to tests/ac15_call_timeout.rs / ac16_request_body_too_
  # large.rs without this guard).
  if [ "${prefix_rule_active:-0}" != 1 ]; then
  for numform in "$n" "$padded"; do
    [ -n "$numform" ] || continue
    matches=( "$repo_tests/ac${numform}_"*.rs "$repo_tests/ac${numform}_"*.py )
    if [ "${#matches[@]}" -eq 0 ]; then
      [ -f "$repo_tests/ac${numform}.rs" ] && matches=( "$repo_tests/ac${numform}.rs" )
    fi
    if [ "${#matches[@]}" -eq 0 ]; then
      [ -f "$repo_tests/ac${numform}.py" ] && matches=( "$repo_tests/ac${numform}.py" )
    fi
    if [ "${#matches[@]}" -gt 0 ]; then
      f="${matches[0]#"$repo"/}"
      if other="$(collision_owner "$f" "$n")"; then
        shopt -u nullglob
        printf 'COLLISION|bare|%s|%s\n' "$f" "$other"
        return
      fi
      shopt -u nullglob
      printf 'PAIRED|bare|%s|\n' "$f"
      return
    fi
  done
  fi
  shopt -u nullglob
  # c. acceptance_ac<N>
  for ext in rs py; do
    f="$repo_tests/acceptance_ac${n}.${ext}"
    if [ -f "$f" ]; then printf 'PAIRED|acceptance_ac|%s|\n' "${f#"$repo"/}"; return; fi
  done
  # d. mocks/ac<N>
  for ext in rs py; do
    f="$repo_tests/mocks/ac${n}.${ext}"
    if [ -f "$f" ]; then printf 'PAIRED|mocks|%s|\n' "${f#"$repo"/}"; return; fi
  done
  # e. fn-scan — last resort. Looked up from a whole-tree index built ONCE
  # (see build_fnscan_index below), not re-grepped per AC: re-scanning the
  # full tests/ tree per AC blew the "<2s for 100 files" NFR once several
  # ACs all fell through to this rule. Scoped against sibling PRDs' own
  # declared prefixes (header guard 6) before being accepted as PAIRED.
  if [ -n "${fnscan_path[$n]:-}" ]; then
    f="${fnscan_path[$n]%%::*}"
    if other="$(collision_owner "$f" "$n")"; then
      printf 'COLLISION|fn-scan|%s|%s\n' "${fnscan_path[$n]}" "$other"
      return
    fi
    printf 'PAIRED|fn-scan|%s|\n' "${fnscan_path[$n]}"
    return
  fi
  printf 'MISSING|||\n'
}

# One-time whole-tree scan for rule (e), building n -> "relpath::fnname".
# A single `grep -rno` pass over tests/ instead of two greps per AC (one
# `-rl` to find the file, one `-m1` to pull the matching line) — that
# quadratic-ish cost (num_acs Ă— tree size) was the dominant cost when many
# ACs fall through every earlier rule; see PRD-build-archive-autopair NFR
# ("derivation completes in under 2s for a crate with 100 test files").
build_fnscan_index() {
  local repo_tests="$repo/tests"
  [ -d "$repo_tests" ] || return 0
  local ffile flineno match ident digits num
  while IFS=: read -r ffile flineno match; do
    ident="$(printf '%s' "$match" | grep -oE 'ac_?0?[0-9]+_[A-Za-z0-9_]*' | head -n1)"
    [ -n "$ident" ] || continue
    digits="$(printf '%s' "$ident" | grep -oE '[0-9]+' | head -n1)"
    [ -n "$digits" ] || continue
    num=$((10#$digits))
    [ -n "${fnscan_path[$num]:-}" ] && continue   # first match wins
    fnscan_path[$num]="${ffile#"$repo"/}::$ident"
  done < <(grep -rnoIE '(fn[[:space:]]+ac0?[0-9]+_[A-Za-z0-9_]*)|(def[[:space:]]+test_ac_?0?[0-9]+_[A-Za-z0-9_]*)' "$repo_tests" 2>/dev/null)
}

repo=""
if [ "$derive_mode" = on ]; then
  repo="$(resolve_repo)"
  declare -a prefix_candidates=()
  while IFS= read -r line; do
    [ -n "$line" ] && prefix_candidates+=("$line")
  done < <(derive_prefix_candidates)
  # prefix_rule_active: does ANY candidate prefix have ANY `<p>_ac*` file
  # in this repo's tests/? If so, this PRD genuinely uses the prefixed
  # convention, and the bare rule (b) is disabled for ALL its ACs — see
  # the long comment at rule (b) in classify_ac for why.
  prefix_rule_active=0
  if [ -d "$repo/tests" ] && [ "${#prefix_candidates[@]}" -gt 0 ]; then
    shopt -s nullglob
    for p in "${prefix_candidates[@]}"; do
      [ -n "$p" ] || continue
      any=( "$repo/tests/${p}_ac"*.rs "$repo/tests/${p}_ac"*.py )
      if [ "${#any[@]}" -gt 0 ]; then prefix_rule_active=1; break; fi
    done
    shopt -u nullglob
  fi
  # declared_prefix: did THIS PRD's own frontmatter declare test_prefix at
  # all (vs. prefix_candidates being a slug-derived GUESS)? See header
  # guard 5 — a declared prefix disables the (b)-(e) fallback entirely.
  declared_prefix=0
  own_tp_n="$("$JQ" -r --arg s "$slug" '.[] | select(.slug==$s) | (.test_prefix // [] | length)' <<<"$json" 2>/dev/null)"
  case "${own_tp_n:-}" in ''|*[!0-9]*) own_tp_n=0 ;; esac
  [ "$own_tp_n" -gt 0 ] && declared_prefix=1
  # sib_prefix_owner: prefix -> owning sibling slug, for every OTHER PRD
  # (built or queued) whose build_into resolves to this same repo and
  # which itself declares a test_prefix. See header guard 6.
  declare -A sib_prefix_owner=()
  while IFS=$'\t' read -r p s; do
    [ -n "$p" ] || continue
    [ -n "${sib_prefix_owner[$p]:-}" ] || sib_prefix_owner["$p"]="$s"
  done < <("$JQ" -r --arg s "$slug" --arg r "$repo" '
      .[] | select(.slug != $s) | select((.build_into // "") == $r) |
      .slug as $sl | (.test_prefix // [])[] | "\(.)\t\($sl)"
    ' <<<"$json" 2>/dev/null)
  build_fnscan_index
  for ((i=1; i<=num_acs; i++)); do
    IFS='|' read -r cls rule path other <<<"$(classify_ac "$i")"
    if [ "$cls" = PAIRED ]; then
      is_paired[$i]=1
      derived_rule[$i]="$rule"
      derived_path[$i]="$path"
    elif [ "$cls" = COLLISION ]; then
      collision_rule[$i]="$rule"
      collision_path[$i]="$path"
      collision_owner_slug[$i]="$other"
    fi
  done
fi

if [ -n "$paired_csv" ]; then
  IFS=',' read -ra paired_arr <<<"$paired_csv"
  for n in "${paired_arr[@]}"; do
    n="${n//[[:space:]]/}"
    case "$n" in
      ''|*[!0-9]*) continue ;;
      *)
        if [ -z "${is_paired[$n]:-}" ]; then
          is_paired[$n]=1
          derived_rule[$n]="asserted"
          derived_path[$n]=""
        fi
        ;;
    esac
  done
fi

while IFS= read -r n; do
  case "$n" in
    ''|*[!0-9]*) continue ;;
    *) is_deferred[$n]=1 ;;
  esac
done < <("$JQ" -r '.[]?' <<<"$deferred")

# ---- --verify-run: re-run each real (non-asserted) paired test --------
if [ "$verify_run" = true ]; then
  [ -n "$repo" ] || repo="$(resolve_repo)"
  for ((i=1; i<=num_acs; i++)); do
    [ -n "${is_paired[$i]:-}" ] || continue
    p="${derived_path[$i]:-}"
    [ -n "$p" ] || continue
    filepart="${p%%::*}"
    funcpart=""
    case "$p" in *::*) funcpart="${p#*::}" ;; esac
    rc=0
    case "$filepart" in
      *.rs)
        stem="$(basename "$filepart" .rs)"
        if [ -n "$funcpart" ]; then
          ( cd "$repo" && cargo test --test "$stem" "$funcpart" ) >/dev/null 2>&1 || rc=$?
        else
          ( cd "$repo" && cargo test --test "$stem" ) >/dev/null 2>&1 || rc=$?
        fi
        ;;
      *.py)
        if [ -n "$funcpart" ]; then
          ( cd "$repo" && python3 -m pytest "${filepart}::${funcpart}" -q ) >/dev/null 2>&1 || rc=$?
        else
          ( cd "$repo" && python3 -m pytest "$filepart" -q ) >/dev/null 2>&1 || rc=$?
        fi
        ;;
      *) rc=0 ;;
    esac
    [ "$rc" -ne 0 ] && is_failing[$i]=1
  done
fi

if [ "$doctor" = true ]; then
  for kv in "${paired_with_kv[@]+"${paired_with_kv[@]}"}"; do
    case "$kv" in
      *=*)
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
          ''|*[!0-9]*) continue ;;
          *) paired_evidence[$k]="$v" ;;
        esac
        ;;
    esac
  done
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    reason_for[$k]="$v"
  done < <("$JQ" -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"${reasons:-{\}}" 2>/dev/null)
fi

missing=()
failing=()
collisions=()
results=()
for ((i=1; i<=num_acs; i++)); do
  if [ -n "${is_paired[$i]:-}" ]; then
    if [ -n "${is_failing[$i]:-}" ]; then
      cls=PAIRED-FAILING
      failing+=("$i")
    else
      cls=PAIRED
    fi
  elif [ -n "${is_deferred[$i]:-}" ]; then
    cls=DEFERRED
  elif [ -n "${collision_owner_slug[$i]:-}" ]; then
    cls=ac-number-collision
    collisions+=("$i")
  else
    cls=MISSING
    missing+=("$i")
  fi
  results+=("$i $cls")
done

if [ "$deferred_unparsed" = true ]; then
  echo "deferred_acs: unparsed — use [N, N]"
fi

if [ "$format" = json ]; then
  payload="$(printf '%s\n' "${results[@]}" \
    | "$JQ" -Rn --arg slug "$slug" --argjson num "$num_acs" \
        --argjson unparsed "$deferred_unparsed" \
        '[inputs | split(" ") | {ac:(.[0]|tonumber), status:.[1]}]
         | {slug:$slug, num_acs:$num, classifications:.,
            missing:[.[]|select(.status=="MISSING")|.ac],
            collisions:[.[]|select(.status=="ac-number-collision")|.ac],
            deferred_acs_unparsed:$unparsed}')"
  # Splice in rule/path (+ collision detail) per AC (derive mode only;
  # empty/null for legacy or non-collision ACs).
  for ((i=1; i<=num_acs; i++)); do
    rule="${derived_rule[$i]:-}"
    path="${derived_path[$i]:-}"
    crule="${collision_rule[$i]:-}"
    cpath="${collision_path[$i]:-}"
    cowner="${collision_owner_slug[$i]:-}"
    payload="$("$JQ" -c --argjson i "$i" --arg rule "$rule" --arg path "$path" \
      --arg crule "$crule" --arg cpath "$cpath" --arg cowner "$cowner" \
      '.classifications |= map(if .ac == $i then . + {
          rule: (if $rule=="" then null else $rule end),
          path: (if $path=="" then null else $path end),
          collision: (if $cowner=="" then null else {other_prd:$cowner, path:$cpath, rule:$crule} end)
        } else . end)' \
      <<<"$payload")"
  done
  printf '%s\n' "$payload"
elif [ "$format" = table ]; then
  printf '%s\t%s\t%s\t%s\t%s\n' AC RULE PATH CLASSIFICATION OTHER_PRD
  for line in "${results[@]}"; do
    n="${line%% *}"; cls="${line#* }"
    rule="${derived_rule[$n]:-}"; [ -n "$rule" ] || rule="${collision_rule[$n]:-}"; [ -n "$rule" ] || rule="-"
    path="${derived_path[$n]:-}"; [ -n "$path" ] || path="${collision_path[$n]:-}"; [ -n "$path" ] || path="-"
    other="${collision_owner_slug[$n]:-}"; [ -n "$other" ] || other="-"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$rule" "$path" "$cls" "$other"
  done
elif [ "$doctor" = true ]; then
  # Padded width = 8 (DEFERRED is widest). Right-pad with spaces so the
  # em-dash column aligns across statuses. Example:
  #   AC1: DEFERRED — wake-to-event latency requires real mic
  #   AC2: PAIRED   — tests/cli.rs::greet_within_15s
  for line in "${results[@]}"; do
    n="${line%% *}"; cls="${line#* }"
    case "$cls" in
      PAIRED|PAIRED-FAILING)
        evi="${paired_evidence[$n]:-}"
        [ -n "$evi" ] || evi="${derived_path[$n]:-}"
        [ -n "$evi" ] || evi="(no test)"
        printf 'AC%s: %-8s — %s\n' "$n" "$cls" "$evi"
        ;;
      DEFERRED)
        r="${reason_for[$n]:-}"
        [ -n "$r" ] || r="(no reason given)"
        printf 'AC%s: %-8s — %s\n' "$n" "$cls" "$r"
        ;;
      ac-number-collision)
        printf 'AC%s: %-8s — matched %s, which belongs to PRD %s\n' "$n" "$cls" \
          "${collision_path[$n]:-(unknown)}" "${collision_owner_slug[$n]:-(unknown)}"
        ;;
      MISSING)
        printf 'AC%s: %-8s — %s\n' "$n" "$cls" "(not paired, not deferred)"
        ;;
    esac
  done
else
  for line in "${results[@]}"; do
    n="${line%% *}"; cls="${line#* }"
    if [ "$cls" = "ac-number-collision" ]; then
      echo "AC$n: $cls (matched ${collision_path[$n]:-?}, which belongs to PRD ${collision_owner_slug[$n]:-?})"
    else
      echo "AC$n: $cls"
    fi
  done
fi

if [ "${#missing[@]}" -gt 0 ] || [ "${#failing[@]}" -gt 0 ] || [ "${#collisions[@]}" -gt 0 ]; then
  for n in "${missing[@]}"; do
    echo "AC$n: not paired (and not declared deferred)" >&2
  done
  for n in "${failing[@]}"; do
    echo "AC$n: PAIRED-FAILING (test ${derived_path[$n]:-} failed under --verify-run)" >&2
  done
  for n in "${collisions[@]}"; do
    echo "AC$n: ac-number-collision (matched ${collision_path[$n]:-} via ${collision_rule[$n]:-}, which belongs to PRD ${collision_owner_slug[$n]:-})" >&2
  done
  exit 1
fi
exit 0
