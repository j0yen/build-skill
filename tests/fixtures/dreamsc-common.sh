# tests/fixtures/dreamsc-common.sh — shared setup for tests/dreamsc_ac0N_*.sh
# (PRD-dream-scorecard-hook R7). Sourced, never run.
#
# sc_setup builds fixture copies of every source under one mktemp directory and
# overrides every source path and both seams, with a private HOME:
#   $SC_T/home                      HOME (no ~/.claude/skills/dream, no ~/.local/state)
#   $SC_T/prds/{build-queue,built-prds,parked,visions,notes}   DREAM_PRD_DIR
#   $SC_T/state/review-log.jsonl    DREAM_REVIEW_LOG
#   $SC_T/state/decisions.jsonl     SKILL_ROUTING_DECISIONS
#   $SC_T/bin/dream-run-note-lint.sh  DREAM_RUN_NOTE_LINT (stub; per-entry answers in $SC_T/lint-answers)
#   $SC_T/sidecar/                  DREAM_PIPELINE_SIDECAR_DIR
#   $SC_T/empty-state               BUILD_STATE_DIR (empty), DREAM_SKILL_DIR -> $SC_T/noskill

SC_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC_REPO="$(cd "$SC_TESTS/.." && pwd)"
SC_SCRIPT="$SC_REPO/scripts/dream-scorecard.sh"
SC_FIXTURE_PRD="$SC_TESTS/dreamdry_fixture/PRD-dreamdry-fixture.md"
SC_FAILS=0

sc_ok()   { echo "ok   $*"; }
sc_fail() { echo "FAIL $*"; SC_FAILS=$((SC_FAILS + 1)); }

sc_setup() {
  SC_T="$(mktemp -d)"
  trap 'chmod -R u+rwX "$SC_T" 2>/dev/null; rm -rf "$SC_T"' EXIT
  mkdir -p "$SC_T/home" "$SC_T/prds/build-queue" "$SC_T/prds/built-prds" "$SC_T/prds/parked" \
           "$SC_T/prds/visions" "$SC_T/prds/notes" "$SC_T/state" "$SC_T/bin" "$SC_T/sidecar" \
           "$SC_T/empty-state" "$SC_T/noskill"
  : > "$SC_T/state/review-log.jsonl"; : > "$SC_T/state/decisions.jsonl"; : > "$SC_T/lint-answers"; : > "$SC_T/lint.log"
  cat > "$SC_T/bin/dream-run-note-lint.sh" <<'EOS'
#!/usr/bin/env bash
# stub run-note lint (sibling PRD dream-run-record R3/R6 contract): exit 0 and 1
# print the JSON object, exit 2 prints none. Answer per entry ts from $SC_LINT_ANSWERS:
#   "<ts>\t<exit>\t<wwhtbt kind>\t<fivewhys kind>"   (default: exit 2)
printf '%s\n' "$*" >> "$SC_LINT_LOG"
ts=""; while [ "$#" -gt 0 ]; do case "$1" in --entry) ts="$2"; shift 2 ;; *) shift ;; esac; done
row="$(awk -F'\t' -v t="$ts" '$1 == t' "$SC_LINT_ANSWERS" | tail -1)"
[ -n "$row" ] || { echo "no entry $ts" >&2; exit 2; }
IFS=$'\t' read -r _ ex wk fk <<<"$row"
[ "$ex" = 2 ] && { echo "unknown entry" >&2; exit 2; }
printf '{"ts": "%s", "exit": %s, "findings": [], "trust": "same-uid", "analysis": {"wwhtbt": {"kind": "%s", "value": null}, "fivewhys": {"kind": "%s", "value": null}}}\n' "$ts" "$ex" "$wk" "$fk"
exit "$ex"
EOS
  chmod +x "$SC_T/bin/dream-run-note-lint.sh"
  export HOME="$SC_T/home"
  export DREAM_PRD_DIR="$SC_T/prds" DREAM_REVIEW_LOG="$SC_T/state/review-log.jsonl"
  export SKILL_ROUTING_DECISIONS="$SC_T/state/decisions.jsonl"
  export DREAM_RUN_NOTE_LINT="$SC_T/bin/dream-run-note-lint.sh" DREAM_PIPELINE_SIDECAR_DIR="$SC_T/sidecar"
  export BUILD_STATE_DIR="$SC_T/empty-state" DREAM_SKILL_DIR="$SC_T/noskill"
  export SC_LINT_ANSWERS="$SC_T/lint-answers" SC_LINT_LOG="$SC_T/lint.log"
  unset BUILD_SKILL_DIR
}

# sc_prd_file <dir> <slug> — a placeholder PRD file (the review filter needs only existence)
sc_prd_file() { printf '# PRD — %s\n' "$2" > "$SC_T/prds/$1/PRD-$2.md"; }

# sc_queued <slug> [frontmatter line] — a lint-clean queued PRD (copy of the dryrun fixture)
sc_queued() {
  local slug="$1" fm="${2:-}" tp; tp="$(printf '%s' "$slug" | tr -cd 'a-z0-9')"
  [ -f "$SC_T/prds/visions/dreamdry-fixture.md" ] || cp "$SC_TESTS/dreamdry_fixture/visions/dreamdry-fixture.md" "$SC_T/prds/visions/"
  sed -e "s/^# PRD — dreamdry-fixture:/# PRD — $slug:/" -e "s/^- test_prefix: dreamdryfx$/- test_prefix: $tp/" \
      "$SC_FIXTURE_PRD" > "$SC_T/prds/build-queue/PRD-$slug.md"
  if [ -n "$fm" ]; then
    python3 -I - "$SC_T/prds/build-queue/PRD-$slug.md" "$fm" <<'PY'
import sys
p, line = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read().replace("- Drafted: 2026-11-15\n", "- Drafted: 2026-11-15\n" + line + "\n", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  fi
}

# sc_review <json object> / sc_decision <json object> / sc_raw <file> <line>
sc_review()   { printf '%s\n' "$1" >> "$SC_T/state/review-log.jsonl"; }
sc_decision() { printf '%s\n' "$1" >> "$SC_T/state/decisions.jsonl"; }
sc_raw()      { printf '%s\n' "$2" >> "$1"; }

# sc_run <args...> — SC_OUT (stdout), SC_ERR (stderr), SC_RC
sc_run() {
  SC_OUT="$(bash "$SC_SCRIPT" "$@" 2>"$SC_T/stderr")"; SC_RC=$?; SC_ERR="$(cat "$SC_T/stderr")"
}

# sc_get <dotted path> — JSON value at that path in $SC_OUT, json-dumped with sorted keys
sc_get() {
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d[k]
print(json.dumps(d, sort_keys=True))' "$SC_OUT" "$1" 2>/dev/null || echo "<missing $1>"
}

sc_expect() { # <dotted path> <json literal> <label>
  local got; got="$(sc_get "$1")"
  if [ "$got" = "$2" ]; then sc_ok "$3: $1 = $2"; else sc_fail "$3: $1 = $got, want $2"; fi
}

sc_expect_rc() { # <want> <label>
  if [ "$SC_RC" -eq "$1" ]; then sc_ok "$2: exit $1"; else sc_fail "$2: exit $SC_RC, want $1 :: $SC_ERR"; fi
}

# sc_writes <args...> — run the script under strace and print every successful
# write-class syscall (open for write/create/truncate, rename, unlink, mkdir,
# truncate, utimensat, link) on any path other than /dev/null. Empty output = wrote nothing.
sc_writes() {
  local tr="$SC_T/strace.$$.log"
  strace -f -qq -e trace=open,openat,creat,rename,renameat,renameat2,unlink,unlinkat,mkdir,mkdirat,truncate,ftruncate,utimensat,link,linkat,symlink,symlinkat -o "$tr" \
    bash "$SC_SCRIPT" "$@" >/dev/null 2>&1
  local w; w="$(grep -vE '= -1 ' "$tr" \
    | grep -E 'O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|creat\(|rename|unlink|mkdir|truncate|utimensat|link\(|linkat\(|symlink' \
    | grep -vE '"/dev/null"' || true)"
  # One allowed exception, reported by name in out/report.md: bash's own here-document
  # temp file (`sh-thd.*` in TMPDIR) that a reused bash+python script (prd-lint.sh) creates
  # for a heredoc larger than a pipe, PROVIDED bash unlinks it again in the same run.
  local p
  for p in $(grep -oE '"[^"]*/sh-thd\.[A-Za-z0-9]+"' <<<"$w" | sort -u | tr -d '"'); do
    if grep -qE "unlink(at)?\(.*\"$p\"" <<<"$w"; then
      w="$(grep -vF "\"$p\"" <<<"$w" || true)"
    fi
  done
  printf '%s' "$w"
  rm -f "$tr"
}

sc_finish() {
  if [ "$SC_FAILS" -eq 0 ]; then echo "PASS $(basename "$0")"; exit 0; fi
  echo "FAILED $(basename "$0") ($SC_FAILS)"; exit 1
}
