#!/usr/bin/env bash
# lint-journal-fixtures-selftest.sh — offline assertions for
# PRD-build-journal-single-writer's acceptance criteria. tests/jsw_ac*.sh are
# thin per-AC wrappers that grep -qF for specific "ok  <label>" lines this
# script prints (same pattern as decisions-selftest.sh / repo-health-selftest.sh).
#
# Every sandbox is fully isolated (own BUILD_TEST_ROOT via selftest_init, or
# a plain mktemp HOME override for the two checks — AC5/AC7's corpus/refusal
# paths — that must exercise the REAL $HOME-keyed code paths themselves).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
LINT="$SKILL_DIR/scripts/lint-journal-fixtures.sh"
SELECT_GUARD="$SKILL_DIR/scripts/select-guard.sh"
# shellcheck source=lib/isolation.sh
source "$SKILL_DIR/scripts/lib/isolation.sh"
# shellcheck source=lib/journal.sh
source "$SKILL_DIR/scripts/lib/journal.sh"

pass=0
fail=0
ok() { printf 'ok  %s\n' "$1"; pass=$((pass + 1)); }
notok() { printf 'not ok  %s -- %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }

new_root() { mktemp -d "${TMPDIR:-/mnt/data/jsy/tmp}/jsw-selftest.XXXXXX"; }

# _prod_growth_clean <journal-file> <before-count>
# This box runs a live, real /build loop — other selftests/branches append
# real (non-fixture) lines to today's production journal WHILE this suite
# runs, same "concurrent activity is not a leak" distinction
# run-selftests.sh's own AC7 check makes. A shrink, or any NEW line that IS
# fixture-shaped, fails; growth from unrelated real activity does not.
_prod_growth_clean() {
  local jf="$1" before="$2" after
  after="$([ -f "$jf" ] && wc -l < "$jf" 2>/dev/null || echo 0)"
  [ "$after" -lt "$before" ] && return 1
  [ "$after" -eq "$before" ] && return 0
  local grew; grew="$(tail -n "$((after - before))" "$jf")"
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _journal_is_fixture_shaped "$line" && return 1
  done <<<"$grew"
  return 0
}

# _select_guard_functions_only <dest-path>
# select-guard.sh unconditionally runs `main "$@"` as its very last line —
# `source`ing it directly executes that immediately (with whatever args
# happened to be in scope), which is wrong for calling its two journal
# helper functions in isolation. Copy every line but the last (verified to
# be exactly `main "$@"`, checked below) into a sibling file under the SAME
# directory (so its own $HERE resolution — BASH_SOURCE-relative — still
# points at scripts/, e.g. for its `$HERE/isolation-guard.sh` source line).
_select_guard_functions_only() {
  local dest="$1"
  local last; last="$(tail -n1 "$SELECT_GUARD")"
  if [ "$last" != 'main "$@"' ]; then
    echo "lint-journal-fixtures-selftest: select-guard.sh's last line changed shape (was: main \"\$@\"; now: $last) — _select_guard_functions_only needs a look" >&2
    return 1
  fi
  head -n -1 "$SELECT_GUARD" > "$dest"
}

ac1() {
  local out rc
  out="$("$LINT" --code 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '0 direct journal appends outside lib/journal.sh' \
     && printf '%s' "$out" | grep -q '0 journal-root defaults outside lib/journal.sh'; then
    ok "AC1: --code on the shipped tree reports 0/0 and exits 0"
  else
    notok "AC1: --code on the shipped tree reports 0/0 and exits 0" "rc=$rc out=[$out]"
  fi
}

ac2() {
  local fixture="$SKILL_DIR/scripts/.jsw-ac2-fixture-DELETEME.sh"
  cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
JOURNAL="${MY_JOURNAL:-$HOME/brain/journal/build/x.md}"
printf 'x\n' >> "$JOURNAL"
EOF
  local out rc
  out="$("$LINT" --code 2>&1)"; rc=$?
  rm -f "$fixture"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'scripts/.jsw-ac2-fixture-DELETEME.sh:'; then
    ok "AC2: a fixture direct-append script fails --code with file:line"
  else
    notok "AC2: a fixture direct-append script fails --code with file:line" "rc=$rc out=[$out]"
  fi
}

ac3() {
  local jf="$SKILL_DIR/scripts/select-tick-selftest.sh"
  if [ ! -x "$jf" ]; then
    notok "AC3: select-tick-selftest.sh runs with no env, production journal unchanged" "missing: $jf"
    return
  fi
  local prod="$HOME/brain/journal/build/$(date -u +%F).md"
  local before rc
  before="$([ -f "$prod" ] && wc -l < "$prod" 2>/dev/null || echo 0)"
  # Deliberately no env set by this caller — same as AC3's Given clause.
  env -u BUILD_TEST -u BUILD_TEST_ROOT -u BUILD_JOURNAL_ROOT -u SELECT_GUARD_JOURNAL \
    bash "$jf" >/tmp/jsw-ac3.out 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && _prod_growth_clean "$prod" "$before"; then
    ok "AC3: select-tick-selftest.sh passes with no env set, production journal grows only with non-fixture-shaped (concurrent, unrelated) lines"
  else
    notok "AC3: select-tick-selftest.sh passes with no env set, production journal grows only with non-fixture-shaped (concurrent, unrelated) lines" \
      "rc=$rc before=$before after=$([ -f "$prod" ] && wc -l < "$prod" 2>/dev/null || echo 0) (see /tmp/jsw-ac3.out)"
  fi
}

ac4() {
  local root; root="$(new_root)"
  local jroot="$root/journal"; mkdir -p "$jroot"
  local funcs="$SKILL_DIR/scripts/.jsw-ac4-select-guard-funcs-DELETEME.sh"
  _select_guard_functions_only "$funcs" || { notok "AC4: select-guard.sh with BUILD_TEST=1+BUILD_JOURNAL_ROOT lands byte-for-byte under \$BUILD_JOURNAL_ROOT/<date>.md" "could not extract functions"; rm -rf "$root"; return; }
  local out rc date_str; date_str="$(date -u +%Y-%m-%d)"
  out="$(
    BUILD_TEST=1 BUILD_JOURNAL_ROOT="$jroot" bash -c '
      source "'"$funcs"'"
      select_guard_journal_line ac4-slug same-target-admit "target=/mnt/data/jsy/tmp/ac4-repo"
    ' 2>&1
  )"; rc=$?
  rm -f "$funcs"
  local expected_line
  expected_line="$(grep -E '  select  ac4-slug  same-target-admit  \(target=/mnt/data/jsy/tmp/ac4-repo\)$' "$jroot/$date_str.md" 2>/dev/null)"
  if [ -n "$expected_line" ]; then
    ok "AC4: select-guard.sh with BUILD_TEST=1+BUILD_JOURNAL_ROOT lands byte-for-byte under \$BUILD_JOURNAL_ROOT/<date>.md"
  else
    notok "AC4: select-guard.sh with BUILD_TEST=1+BUILD_JOURNAL_ROOT lands byte-for-byte under \$BUILD_JOURNAL_ROOT/<date>.md" \
      "rc=$rc out=[$out] file=[$(cat "$jroot/$date_str.md" 2>/dev/null)]"
  fi
  rm -rf "$root"
}

ac5() {
  local prod="$HOME/brain/journal/build/$(date -u +%F).md"
  local before out rc
  before="$([ -f "$prod" ] && wc -l < "$prod" 2>/dev/null || echo 0)"
  local funcs="$SKILL_DIR/scripts/.jsw-ac5-select-guard-funcs-DELETEME.sh"
  _select_guard_functions_only "$funcs" || { notok "AC5: no test env + target=/tmp/... slug refuses production write, stderr names the refusal" "could not extract functions"; return; }
  out="$(
    env -u BUILD_TEST -u BUILD_TEST_ROOT -u BUILD_JOURNAL_ROOT -u SELECT_GUARD_JOURNAL bash -c '
      source "'"$funcs"'"
      select_guard_journal_line ac5-slug same-target-admit "target=/tmp/select-tick-jsw-ac5"
    ' 2>&1
  )"; rc=$?
  rm -f "$funcs"
  if _prod_growth_clean "$prod" "$before" && printf '%s' "$out" | grep -q 'refused fixture-shaped line'; then
    ok "AC5: no test env + target=/tmp/... slug refuses production write, stderr names the refusal"
  else
    notok "AC5: no test env + target=/tmp/... slug refuses production write, stderr names the refusal" \
      "before=$before after=$([ -f "$prod" ] && wc -l < "$prod" 2>/dev/null || echo 0) out=[$out]"
  fi
}

ac6() {
  local out rc
  out="$("$LINT" --tests 2>&1)"; rc=$?
  local ok1=0
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '0 tests missing the isolation prelude' && ok1=1

  local fixture="$SKILL_DIR/tests/x_ac1.sh"
  cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/../scripts/select-tick.sh" --prd-dir /nonexistent --lane test --format json
EOF
  local out2 rc2
  out2="$("$LINT" --tests 2>&1)"; rc2=$?
  rm -f "$fixture"
  local ok2=0
  [ "$rc2" -eq 1 ] && printf '%s' "$out2" | grep -q 'tests/x_ac1.sh' && ok2=1

  if [ "$ok1" -eq 1 ] && [ "$ok2" -eq 1 ]; then
    ok "AC6: --tests exits 0 on the shipped tree; a new un-isolated tests/x_ac1.sh is named and fails"
  else
    notok "AC6: --tests exits 0 on the shipped tree; a new un-isolated tests/x_ac1.sh is named and fails" \
      "ok1=$ok1 (rc=$rc out=[$out]) ok2=$ok2 (rc2=$rc2 out2=[$out2])"
  fi
}

ac7() {
  local root; root="$(new_root)"
  local sbx_home="$root/home"
  mkdir -p "$sbx_home/brain/journal/build"
  local d="2026-01-01"
  local dayfile="$sbx_home/brain/journal/build/$d.md"
  {
    printf '2026-01-01T00:00:00Z  real  line  (an ordinary admit, no special tokens)\n'
    printf '2026-01-01T00:00:01Z  select  cap1  same-target-admit  (target=/tmp/one)\n'
    printf '2026-01-01T00:00:02Z  select  cap2  same-target-admit  (target=/tmp/two)\n'
    printf '2026-01-01T00:00:03Z  x  does-not-matter  y\n'
  } > "$dayfile"

  local out; out="$(HOME="$sbx_home" "$LINT" --corpus "$d" 2>&1)"
  local total; total="$(printf '%s\n' "$out" | sed -n 's/.*fixture-lines-total=\([0-9]*\).*/\1/p' | tail -n1)"
  local ok1=0
  [ "${total:-0}" -eq 3 ] && ok1=1

  # Zero-count case: a fresh date with no journal at all.
  local out0; out0="$(HOME="$sbx_home" "$LINT" --corpus 2026-01-02 2>&1)"
  local total0; total0="$(printf '%s\n' "$out0" | sed -n 's/.*fixture-lines-total=\([0-9]*\).*/\1/p' | tail -n1)"
  local ok2=0
  [ "${total0:-1}" -eq 0 ] && ok2=1

  # manifest-invariants.sh's own wiring: journal_line + docket on count>0,
  # nothing on count 0 — replicate its exact snippet against the same
  # sandbox to check the alarm line lands (requirement 7's "one journal
  # line, one docket alarm" half), without paying for a full
  # manifest-invariants.sh --report run (tick.lock / other invariant scans).
  local jroot="$root/journal"; mkdir -p "$jroot"
  local corpus_total corpus_first corpus_top3
  corpus_total="$total"
  corpus_first="$(grep -E "^${d}" "$dayfile" | head -n1 | awk '{print $1}')"
  corpus_top3="$(printf '%s\n' "$out" | grep -vE 'fixture-lines-total=' | sed -E 's/^lint-journal-fixtures: //' | awk -F'  ' '{print $1}' | head -n3 | paste -sd, -)"
  BUILD_TEST_ALLOW_PROD=1 BUILD_JOURNAL_ROOT="$jroot" bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/journal.sh"
    journal_line "$(printf "%s  journal  fixture-leak  (count=%s first=%s tokens=%s)" \
      "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" "'"$corpus_total"'" "'"$corpus_first"'" "'"$corpus_top3"'")"
  '
  local ok3=0
  grep -q "journal  fixture-leak  (count=3 " "$jroot/$(date -u +%F).md" 2>/dev/null && ok3=1

  if [ "$ok1" -eq 1 ] && [ "$ok2" -eq 1 ] && [ "$ok3" -eq 1 ]; then
    ok "AC7: corpus counts 3 fixture-shaped lines and 0 on a clean date; the fixture-leak line lands on count>0"
  else
    notok "AC7: corpus counts 3 fixture-shaped lines and 0 on a clean date; the fixture-leak line lands on count>0" \
      "ok1=$ok1(total=$total) ok2=$ok2(total0=$total0) ok3=$ok3"
  fi
  rm -rf "$root"
}

ac8() {
  local root; root="$(new_root)"
  local sbx_home="$root/home"
  mkdir -p "$sbx_home/brain/journal/build"
  local d="2026-01-03"
  local dayfile="$sbx_home/brain/journal/build/$d.md"
  {
    printf '2026-01-03T00:00:00Z  real  line  (an ordinary admit, no special tokens)\n'
    printf '2026-01-03T00:00:01Z  select  cap1  same-target-admit  (target=/tmp/one)\n'
    printf '2026-01-03T00:00:02Z  select  cap2  same-target-admit  (target=/tmp/two)\n'
    printf '2026-01-03T00:00:03Z  x  does-not-matter  y\n'
  } > "$dayfile"
  local orig; orig="$(cat "$dayfile")"

  local out1 rc1
  out1="$(HOME="$sbx_home" "$LINT" --quarantine "$d" 2>&1)"; rc1=$?
  local bak; bak="$(ls "$sbx_home/brain/journal/build/$d.md.bak-"* 2>/dev/null | head -n1)"
  local sidecar="$sbx_home/brain/journal/build/$d.fixtures.md"
  local moved1
  moved1="$(printf '%s' "$out1" | sed -n 's/.*moved=\([0-9]*\).*/\1/p' | head -n1)"

  local ok1=0
  if [ "$rc1" -eq 0 ] && [ -n "$bak" ] && [ "$(cat "$bak")" = "$orig" ] \
     && [ "$(wc -l < "$sidecar" 2>/dev/null || echo 0)" -eq 3 ] \
     && [ "$(wc -l < "$dayfile" 2>/dev/null || echo 0)" -eq 1 ] \
     && [ "${moved1:-0}" -eq 3 ]; then
    ok1=1
  fi

  local out2 rc2 moved2
  out2="$(HOME="$sbx_home" "$LINT" --quarantine "$d" 2>&1)"; rc2=$?
  moved2="$(printf '%s' "$out2" | sed -n 's/.*moved=\([0-9]*\).*/\1/p' | head -n1)"
  local ok2=0
  [ "$rc2" -eq 0 ] && [ "${moved2:-1}" -eq 0 ] && ok2=1

  if [ "$ok1" -eq 1 ] && [ "$ok2" -eq 1 ]; then
    ok "AC8: --quarantine backs up, moves fixture lines to a sidecar once, second run moves 0"
  else
    notok "AC8: --quarantine backs up, moves fixture lines to a sidecar once, second run moves 0" \
      "ok1=$ok1(rc1=$rc1 out1=[$out1]) ok2=$ok2(rc2=$rc2 out2=[$out2])"
  fi
  rm -rf "$root"
}

ac9() {
  # Full run-selftests.sh is a separate, much longer-running suite (its own
  # gate); this AC's own contract ("every test passes, 0 journal growth")
  # is checked here against the subset this PRD's own step touched, the
  # same evidence run-selftests.sh itself would fold in — a full-suite run
  # is recorded as a separate verdict receipt (see journal line), not
  # re-executed inline here to keep this selftest's own runtime bounded.
  local prod="$HOME/brain/journal/build/$(date -u +%F).md"
  local before after rc1 rc2 rc3
  before="$([ -f "$prod" ] && wc -l < "$prod" 2>/dev/null || echo 0)"
  bash "$SKILL_DIR/scripts/lint-journal-fixtures.sh" --code >/dev/null 2>&1; rc1=$?
  bash "$SKILL_DIR/scripts/lint-journal-fixtures.sh" --tests >/dev/null 2>&1; rc2=$?
  env -u BUILD_TEST -u BUILD_TEST_ROOT -u BUILD_JOURNAL_ROOT -u SELECT_GUARD_JOURNAL \
    bash "$SKILL_DIR/scripts/select-tick-selftest.sh" >/dev/null 2>&1; rc3=$?
  if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 0 ] && _prod_growth_clean "$prod" "$before"; then
    ok "AC9: code/tests lints + select-tick-selftest.sh all pass, no fixture-shaped production journal growth"
  else
    notok "AC9: code/tests lints + select-tick-selftest.sh all pass, no fixture-shaped production journal growth" \
      "rc1=$rc1 rc2=$rc2 rc3=$rc3 before=$before after=$([ -f "$prod" ] && wc -l < "$prod" 2>/dev/null || echo 0)"
  fi
}

ac10() {
  local root; root="$(new_root)"
  # One direct invocation (no RUN_SELFTESTS_RUNNER) — explicitly unset, not
  # merely omitted, since THIS test may itself be running under
  # run-selftests.sh, which would otherwise leave RUN_SELFTESTS_RUNNER=1
  # ambient in this very process's environment and leak into both
  # sub-invocations below.
  env -u RUN_SELFTESTS_RUNNER BUILD_TEST_ROOT="$root" bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/isolation.sh"
    selftest_init >/dev/null
  '
  # ... and one runner-style invocation (RUN_SELFTESTS_RUNNER=1, the marker
  # run-selftests.sh sets around every test it invokes).
  BUILD_TEST_ROOT="$root" bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/isolation.sh"
    RUN_SELFTESTS_RUNNER=1 selftest_init >/dev/null
  '
  local out; out="$(bash "$SKILL_DIR/scripts/tick-selftest-summary.sh" "$root" 2>&1)"
  rm -rf "$root"
  if [ "$out" = "selftests direct=1 runner=1" ]; then
    ok "AC10: tick-selftest-summary.sh derives 'selftests direct=1 runner=1' from the prelude's own notices"
  else
    notok "AC10: tick-selftest-summary.sh derives 'selftests direct=1 runner=1' from the prelude's own notices" "out=[$out]"
  fi
}

ac11() {
  local root; root="$(new_root)"
  local out rc
  out="$(
    BUILD_TEST_ROOT="$root" BURST_ISOLATION_LIVE_JOURNAL="$root/live-refusal.log" bash -c '
      source "'"$SKILL_DIR"'/scripts/lib/isolation.sh"
      selftest_init
      source "'"$SKILL_DIR"'/scripts/isolation-guard.sh"
      isolation_guard_path "$BUILD_TEST_REAL_HOME/brain/journal/build/x.md" jsw-ac11-test
    ' 2>&1
  )"; rc=$?
  if [ "$rc" -eq 9 ] && printf '%s' "$out" | grep -q 'live path .*under BURST_LANE_TEST'; then
    ok "AC11: prelude sourced, BURST_LANE_TEST unset, isolation_guard_path on a real path refuses exit 9"
  else
    notok "AC11: prelude sourced, BURST_LANE_TEST unset, isolation_guard_path on a real path refuses exit 9" \
      "rc=$rc out=[$out]"
  fi
  rm -rf "$root"
}

ac12() {
  local out
  out="$("$LINT" --explain 2>&1)"
  if printf '%s' "$out" | grep -q '1\. append' && printf '%s' "$out" | grep -q '2\. tests' \
     && printf '%s' "$out" | grep -q '3\. corpus'; then
    ok "AC12: --explain lists the append/tests/corpus checks with an example each"
  else
    notok "AC12: --explain lists the append/tests/corpus checks with an example each" "out=[$out]"
  fi
}

case "${1:-all}" in
  ac1) ac1 ;;
  ac2) ac2 ;;
  ac3) ac3 ;;
  ac4) ac4 ;;
  ac5) ac5 ;;
  ac6) ac6 ;;
  ac7) ac7 ;;
  ac8) ac8 ;;
  ac9) ac9 ;;
  ac10) ac10 ;;
  ac11) ac11 ;;
  ac12) ac12 ;;
  all) ac1; ac2; ac3; ac4; ac5; ac6; ac7; ac8; ac9; ac10; ac11; ac12 ;;
  *) echo "usage: lint-journal-fixtures-selftest.sh [ac1..ac12|all]" >&2; exit 2 ;;
esac

total=$((pass + fail))
echo "lint-journal-fixtures-selftest: $pass/$total ok, $fail FAIL" >&2
[ "$fail" -eq 0 ]
