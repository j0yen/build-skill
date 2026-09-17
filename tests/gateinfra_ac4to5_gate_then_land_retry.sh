#!/usr/bin/env bash
# tests/gateinfra_ac4to5_gate_then_land_retry.sh — PRD-build-gate-infra-
# outcome AC4/AC5 (test_prefix gateinfra). Same modeling convention
# gate-then-land-selftest.sh already uses: extend-gate.sh is swapped for a
# tiny fixture stub via GATE_THEN_LAND_EXTEND_GATE so this test is about
# gate-then-land.sh's OWN retry/escalation logic (attempt counter keyed by
# head, sidecar/journal shape, decisions.sh idempotency), not a real
# producer sequence.
#
#   AC4 — a single `incomplete` (extend-gate.sh exit 9) at a fresh head:
#         gate-then-land.sh exits 13, journals `gate-incomplete attempt=1
#         infra=<phase>`, writes sidecar `last_error=gate-infra:<phase>:
#         <note>`, no `gate-block` line; branch kept, main untouched.
#   AC5 — GATE_INFRA_MAX_ATTEMPTS=3 (fixture) and three consecutive
#         `incomplete` results at the SAME head: the third exits 14,
#         opens exactly one decisions.sh row (idempotent — a 4th call at
#         the same head/phase/note is a no-op, never a second row), and
#         the state file's attempts resets when the head changes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GTL="$HERE/../scripts/gate-then-land.sh"
[ -x "$GTL" ] || { echo "selftest: $GTL not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac4to5.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
# gate-then-land.sh's own STATE_DIR local is derived from BUILD_STATE_DIR
# (`STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"`) — that reassignment
# clobbers a merely-exported bare STATE_DIR inherited from this shell
# before manifest-sidecar.sh (a child process) ever sees it, so
# BUILD_STATE_DIR is the knob that actually isolates the sidecar/GATE_INFRA
# state files from the real skill state/ this coordinator is using.
export BUILD_STATE_DIR="$T/state"
export STATE_DIR="$T/state"
GIT_ID=(-c user.email=test@gateinfra-selftest.local -c user.name="gateinfra-selftest")
trap '[ -n "${GATEINFRA_KEEP:-}" ] || rm -rf "$T"' EXIT

# Fake extend-gate.sh: honors FAKE_GATE_VERDICT=incomplete (rc 9), writing
# an infra_notes array onto the verdict file so gate-then-land.sh's own
# `jq -r '.infra_notes[0]'` read has something real to parse — same shape
# extend-gate.sh's own R2 cache write produces.
cat > "$T/fake-extend-gate.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
wt="$1"; shift
mode="gate"; head_sha=""; scope=""; slug=""; project_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head_sha="$2"; shift 2 ;;
    --scope) scope="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --project-root) project_root="$2"; shift 2 ;;
    --print-verdict-path) mode="path"; shift ;;
    *) shift ;;
  esac
done
root="$wt"; [ -n "$project_root" ] && root="$wt/$project_root"
cache_file="$root/target/autobuilder/last-verdict.json"
if [ "$mode" = path ]; then
  echo "$cache_file"
  exit 0
fi
mkdir -p "$(dirname "$cache_file")"
tree_now="$(git -C "$wt" rev-parse HEAD^{tree})"
verdict="${FAKE_GATE_VERDICT:-pass}"
rc=0
[ "$verdict" = block ] && rc=1
[ "$verdict" = incomplete ] && rc=9
jq -n --arg head "$head_sha" --arg tree "$tree_now" --arg scope "$scope" --arg slug "$slug" \
     --arg verdict "$verdict" --argjson rc "$rc" \
     --arg infra_note "${FAKE_GATE_INFRA_NOTE:-reviewer-agent — claude -p subagent invocation failed}" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: "fake",
   verdict: $verdict, exit_code: $rc,
   new_blocks: (if $verdict == "block" then ["fake-blocker"] else [] end),
   inherited_blocks: [], scope: $scope, slug: $slug,
   infra_notes: (if $verdict == "incomplete" then [$infra_note] else [] end)}' > "$cache_file"
exit "$rc"
FAKE
chmod +x "$T/fake-extend-gate.sh"

# Fake decisions.sh: records each `open` call's question to a log file and
# is idempotent by question text — the SAME idempotency contract the real
# decisions.sh documents (id = hash of the question), so a repeat `open`
# for the same question is a no-op, never a second row.
cat > "$T/fake-decisions.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
LOG="${FAKE_DECISIONS_LOG:?}"
case "${1:-}" in
  open)
    q="$2"
    id="$(printf '%s' "$q" | cksum | cut -d' ' -f1)"
    if ! grep -qF "$q" "$LOG" 2>/dev/null; then
      echo "$q" >> "$LOG"
    fi
    echo "$id"
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$T/fake-decisions.sh"

mk_repo_and_branch() {
  local name="$1"
  local repo="$T/$name" wt
  mkdir -p "$repo/src"
  git -C "$repo" init -q -b main
  printf '/target\n/.cargo\n' > "$repo/.gitignore"
  printf 'pub fn f() {}\n' > "$repo/src/lib.rs"
  cat > "$repo/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
EOF
  git -C "$repo" "${GIT_ID[@]}" add -A
  git -C "$repo" "${GIT_ID[@]}" commit -q -m init
  wt="$("$HERE/../scripts/worktree-extend.sh" add "$repo" "${name}-slug" 2>/dev/null)"
  printf 'pub fn g() {}\n' >> "$wt/src/lib.rs"
  git -C "$wt" "${GIT_ID[@]}" add -A
  git -C "$wt" "${GIT_ID[@]}" commit -q -m "branch work"
  printf '%s %s\n' "$repo" "$wt"
}

echo "=== AC4: single incomplete at a fresh head -> exit 13, retryable ==="
read -r REPO_D WT_D < <(mk_repo_and_branch scenD)
MAIN_BEFORE_D="$(git -C "$REPO_D" rev-parse HEAD)"
JOURNAL_D="$T/journal-d.md"
out_d="$T/out-d.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL_D" WORKTREE_EXTEND_JOURNAL="$JOURNAL_D" \
    FAKE_GATE_VERDICT=incomplete GATE_INFRA_MAX_ATTEMPTS=3 \
    "$GTL" "$REPO_D" scenD-slug minor /dev/null >"$out_d" 2>"$out_d.err"
rc_d=$?
cat "$out_d" "$out_d.err" >&2
expect "AC4: gate-then-land exits 13 (gate-incomplete)" "[ $rc_d -eq 13 ]"
expect "AC4: journal has gate-incomplete attempt=1" "grep -q 'gate-incomplete attempt=1' '$JOURNAL_D'"
expect "AC4: journal names infra=reviewer-agent" "grep -q 'infra=reviewer-agent' '$JOURNAL_D'"
expect "AC4: no gate-block line was written" "! grep -q 'gate-block' '$JOURNAL_D'"
expect "AC4: main is byte-for-byte unchanged" "[ \"\$(git -C \"$REPO_D\" rev-parse HEAD)\" = \"$MAIN_BEFORE_D\" ]"
expect "AC4: sidecar carries a gate-infra last_error" \
  "grep -rq 'gate-infra:reviewer-agent' \"$STATE_DIR/status/scenD-slug.json\" 2>/dev/null"

echo "=== AC5: GATE_INFRA_MAX_ATTEMPTS=3, three incompletes at the SAME head -> escalate ==="
read -r REPO_E WT_E < <(mk_repo_and_branch scenE)
JOURNAL_E="$T/journal-e.md"
DECISIONS_LOG="$T/decisions-e.log"
: > "$DECISIONS_LOG"
run_e() {
  env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
      GATE_THEN_LAND_JOURNAL="$JOURNAL_E" WORKTREE_EXTEND_JOURNAL="$JOURNAL_E" \
      FAKE_GATE_VERDICT=incomplete GATE_INFRA_MAX_ATTEMPTS=3 \
      GATE_THEN_LAND_DECISIONS="$T/fake-decisions.sh" FAKE_DECISIONS_LOG="$DECISIONS_LOG" \
      "$GTL" "$REPO_E" scenE-slug minor /dev/null
}
out_e1="$(run_e 2>&1)"; rc_e1=$?
out_e2="$(run_e 2>&1)"; rc_e2=$?
out_e3="$(run_e 2>&1)"; rc_e3=$?
out_e4="$(run_e 2>&1)"; rc_e4=$?
expect "AC5: attempts 1 and 2 both exit 13 (retryable)" "[ $rc_e1 -eq 13 ] && [ $rc_e2 -eq 13 ]"
expect "AC5: attempt 3 exits 14 (attempts-exhausted)" "[ $rc_e3 -eq 14 ]"
expect "AC5: attempt 3's journal line carries attempts=3" "grep -q 'gate-infra-attempts-exhausted attempts=3' '$JOURNAL_E'"
expect "AC5: exactly ONE decision question was opened (idempotent)" \
  "[ \"\$(sort -u '$DECISIONS_LOG' | wc -l)\" -eq 1 ]"
expect "AC5: a 4th call at the SAME head still exits 14, not a 4th real attempt (no new decision row)" \
  "[ $rc_e4 -eq 14 ] && [ \"\$(sort -u '$DECISIONS_LOG' | wc -l)\" -eq 1 ]"

echo "=== AC5b: a NEW commit at the head resets the attempts counter ==="
git -C "$WT_E" "${GIT_ID[@]}" commit --allow-empty -q -m "new head, resets the infra counter"
out_e5="$(run_e 2>&1)"; rc_e5=$?
expect "AC5b: a fresh head starts back at attempt=1 (exit 13, not 14)" "[ $rc_e5 -eq 13 ]"
expect "AC5b: journal shows attempt=1 for the new head" "grep -c 'gate-incomplete attempt=1' '$JOURNAL_E' | grep -q '^2$'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac4to5: ALL PASS"
else
  echo "gateinfra_ac4to5: assertion(s) FAILED"
fi
exit "$fail"
