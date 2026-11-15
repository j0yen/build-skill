#!/usr/bin/env bash
# dreamsc_ac07 — PRD-dream-scorecard-hook AC7 (+ R4 seam discovery). Three log entries and
# DREAM_RUN_NOTE_LINT naming a stub exiting 0 with JSON, 1 with JSON, then 2:
# with_run_record 2, lint_fail 1, no_record 1, analysis counts two objects,
# sources.run_note_lint is the stub. Seam unset, no lint on PATH, DREAM_SKILL_DIR empty:
# runs.analysis na:no-run-record-lint and sources.run_note_lint absent. Then each discovery
# default resolves a stub (PATH, DREAM_SKILL_DIR, ~/.claude/skills/dream), and a
# non-executable seam reads na with the attempted path in sources.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
log="$SC_T/prds/notes/dream-log.md"
cat > "$log" <<'LOG'
# Dream log

## 2026-10-01T10:00:00Z  /dream  vision-old
State: old=drafted

## 2026-11-10T10:00:00Z  /dream  vision-a
State: a=drafted

## 2026-11-11T10:00:00Z  note  not a run

## 2026-11-11T11:00:00-0800  /dream  vision-b (addendum)
State: b=drafted

## 2026-11-12  /dream  vision-c
State: c=drafted
LOG
printf '2026-11-10T10:00:00Z\t0\tran\tinline\n2026-11-11T11:00:00-0800\t1\treused\tskipped\n2026-11-12\t2\t-\t-\n' > "$SC_LINT_ANSWERS"
sc_run --json --since 2026-11-01
sc_expect_rc 0 "AC7"
sc_expect metrics.runs.entries.value 3 "AC7"
sc_expect metrics.runs.with_run_record.value 2 "AC7"
sc_expect metrics.runs.lint_fail.value 1 "AC7"
sc_expect metrics.runs.no_record.value 1 "AC7"
sc_expect metrics.runs.analysis.value '{"inline": 1, "ran": 1, "reused": 1, "skipped": 1}' "AC7 (two objects, two kinds each)"
sc_expect sources.run_note_lint "\"$DREAM_RUN_NOTE_LINT\"" "AC7"
sc_expect sources.dream_log "\"$log\"" "AC7"
want_calls="$log --entry 2026-11-10T10:00:00Z --json --prd-dir $SC_T/prds
$log --entry 2026-11-11T11:00:00-0800 --json --prd-dir $SC_T/prds
$log --entry 2026-11-12 --json --prd-dir $SC_T/prds"
[ "$(cat "$SC_LINT_LOG")" = "$want_calls" ] && sc_ok "AC7 the lint was called once per in-window /dream entry, run-record R3 argv" || sc_fail "AC7 lint calls: $(cat "$SC_LINT_LOG")"

stub="$DREAM_RUN_NOTE_LINT"
( unset DREAM_RUN_NOTE_LINT; export PATH="/usr/bin:/bin" DREAM_SKILL_DIR=""; sc_run --json --since 2026-11-01
  [ "$(sc_get metrics.runs.analysis.value)" = '"na:no-run-record-lint"' ] && [ "$(sc_get sources.run_note_lint)" = '"absent"' ] \
    && [ "$(sc_get metrics.runs.entries.value)" = 3 ] \
    && echo "ok   AC7 seam unset, no lint on PATH, DREAM_SKILL_DIR empty: na:no-run-record-lint, sources absent, entries still counted" \
    || { echo "FAIL AC7 unset: $(sc_get metrics.runs) $(sc_get sources)"; exit 1; } ) || SC_FAILS=$((SC_FAILS + 1))

mkdir -p "$SC_T/pathbin" "$SC_T/skilldir/scripts" "$SC_T/home/.claude/skills" "$SC_T/kit/dream/scripts"
cp "$stub" "$SC_T/skilldir/scripts/dream-run-note-lint.sh"
cp "$stub" "$SC_T/kit/dream/scripts/dream-run-note-lint.sh"
ln -s "$SC_T/kit/dream" "$SC_T/home/.claude/skills/dream"
( unset DREAM_RUN_NOTE_LINT; export PATH="/usr/bin:/bin" DREAM_SKILL_DIR=""; sc_run --json --since 2026-11-01
  [ "$(sc_get sources.run_note_lint)" = "\"$SC_T/kit/dream/scripts/dream-run-note-lint.sh\"" ] && [ "$(sc_get metrics.runs.with_run_record.value)" = 2 ] \
    && echo "ok   R4 default: readlink -f ~/.claude/skills/dream resolves the lint (metric counted, not na)" || { echo "FAIL R4 skills symlink: $(sc_get sources)"; exit 1; } ) || SC_FAILS=$((SC_FAILS + 1))
( unset DREAM_RUN_NOTE_LINT; export PATH="/usr/bin:/bin" DREAM_SKILL_DIR="$SC_T/skilldir"; sc_run --json --since 2026-11-01
  [ "$(sc_get sources.run_note_lint)" = "\"$SC_T/skilldir/scripts/dream-run-note-lint.sh\"" ] && [ "$(sc_get metrics.runs.lint_fail.value)" = 1 ] \
    && echo "ok   R4 default: \$DREAM_SKILL_DIR/scripts resolves the lint" || { echo "FAIL R4 DREAM_SKILL_DIR: $(sc_get sources)"; exit 1; } ) || SC_FAILS=$((SC_FAILS + 1))
cp "$stub" "$SC_T/pathbin/dream-run-note-lint.sh"
( unset DREAM_RUN_NOTE_LINT; export PATH="$SC_T/pathbin:/usr/bin:/bin" DREAM_SKILL_DIR="$SC_T/skilldir"; sc_run --json --since 2026-11-01
  [ "$(sc_get sources.run_note_lint)" = "\"$SC_T/pathbin/dream-run-note-lint.sh\"" ] \
    && echo "ok   R4 default: command -v on PATH wins over DREAM_SKILL_DIR" || { echo "FAIL R4 PATH: $(sc_get sources)"; exit 1; } ) || SC_FAILS=$((SC_FAILS + 1))
printf '#!/bin/sh\nexit 0\n' > "$SC_T/plain-lint.sh"   # not executable
( export DREAM_RUN_NOTE_LINT="$SC_T/plain-lint.sh" PATH="$SC_T/pathbin:/usr/bin:/bin"; sc_run --json --since 2026-11-01
  [ "$(sc_get metrics.runs.with_run_record.value)" = '"na:no-run-record-lint"' ] && [ "$(sc_get sources.run_note_lint)" = '"absent"' ] \
    && [ "$(sc_get sources.run_note_lint_attempted)" = "[\"$SC_T/plain-lint.sh\"]" ] \
    && echo "ok   edge: a seam naming a non-executable file reads na:no-run-record-lint, attempted path in sources" || { echo "FAIL edge non-executable: $(sc_get sources)"; exit 1; } ) || SC_FAILS=$((SC_FAILS + 1))
sc_finish
