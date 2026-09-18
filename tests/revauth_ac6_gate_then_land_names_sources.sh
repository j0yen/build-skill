#!/usr/bin/env bash
# tests/revauth_ac6_gate_then_land_names_sources.sh — PRD-build-reviewer-
# agent-auth-contract AC6 (test_prefix revauth). Same modeling convention
# tests/gateinfra_ac4to5_gate_then_land_retry.sh already uses:
# extend-gate.sh is swapped for a tiny fixture stub via
# GATE_THEN_LAND_EXTEND_GATE so this test is about gate-then-land.sh's OWN
# exhaustion/decision logic reading a phase="reviewer-agent:auth-missing"
# incomplete verdict — not a real producer sequence. gate-then-land.sh
# itself is UNCHANGED by this PRD (R6 is satisfied because its existing
# decision-question text already interpolates the infra note verbatim);
# this proves that claim rather than assuming it.
#
#   AC6 — a gate run that hits auth-missing, processed by gate-then-
#         land.sh: the journal shows `gate-incomplete attempt=N
#         infra=reviewer-agent:auth-missing`, and on the third consecutive
#         one, the decision opened names the auth sources checked.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GTL="$HERE/../scripts/gate-then-land.sh"
[ -x "$GTL" ] || { echo "selftest: $GTL not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/revauth-ac6.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
export BUILD_STATE_DIR="$T/state"
export STATE_DIR="$T/state"
GIT_ID=(-c user.email=test@revauth-selftest.local -c user.name="revauth-selftest")
trap '[ -n "${REVAUTH_KEEP:-}" ] || rm -rf "$T"' EXIT

SOURCES_CSV="env,environment.d:/home/fixture/.config/environment.d/90-claude-oauth.conf,systemctl"
INFRA_NOTE="reviewer-agent — no token from any of: ${SOURCES_CSV}"

cat > "$T/fake-extend-gate.sh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
wt="\$1"; shift
mode="gate"; head_sha=""; scope=""; slug=""; project_root=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --head) head_sha="\$2"; shift 2 ;;
    --scope) scope="\$2"; shift 2 ;;
    --slug) slug="\$2"; shift 2 ;;
    --project-root) project_root="\$2"; shift 2 ;;
    --print-verdict-path) mode="path"; shift ;;
    *) shift ;;
  esac
done
root="\$wt"; [ -n "\$project_root" ] && root="\$wt/\$project_root"
cache_file="\$root/target/autobuilder/last-verdict.json"
if [ "\$mode" = path ]; then
  echo "\$cache_file"
  exit 0
fi
mkdir -p "\$(dirname "\$cache_file")"
tree_now="\$(git -C "\$wt" rev-parse HEAD^{tree})"
jq -n --arg head "\$head_sha" --arg tree "\$tree_now" --arg scope "\$scope" --arg slug "\$slug" \\
     --arg infra_note "$INFRA_NOTE" '
  {head_sha: \$head, head: \$head, tree_sha: \$tree, script_sha256: "fake",
   verdict: "incomplete", exit_code: 9,
   new_blocks: [], inherited_blocks: [], scope: \$scope, slug: \$slug,
   infra_notes: ["reviewer-agent:auth-missing — " + \$infra_note]}' > "\$cache_file"
exit 9
FAKE
chmod +x "$T/fake-extend-gate.sh"

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

echo "=== AC6: three consecutive auth-missing incompletes at the same head -> escalation names the sources ==="
read -r REPO WT < <(mk_repo_and_branch scenF)
JOURNAL="$T/journal.md"
DECISIONS_LOG="$T/decisions.log"
: > "$DECISIONS_LOG"
run_it() {
  env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
      GATE_THEN_LAND_JOURNAL="$JOURNAL" WORKTREE_EXTEND_JOURNAL="$JOURNAL" \
      GATE_INFRA_MAX_ATTEMPTS=3 \
      GATE_THEN_LAND_DECISIONS="$T/fake-decisions.sh" FAKE_DECISIONS_LOG="$DECISIONS_LOG" \
      "$GTL" "$REPO" scenF-slug minor /dev/null
}
out1="$(run_it 2>&1)"; rc1=$?
out2="$(run_it 2>&1)"; rc2=$?
out3="$(run_it 2>&1)"; rc3=$?

expect "AC6: attempts 1 and 2 both exit 13 (retryable)" "[ $rc1 -eq 13 ] && [ $rc2 -eq 13 ]"
expect "AC6: attempt 3 exits 14 (attempts-exhausted)" "[ $rc3 -eq 14 ]"
expect "AC6: journal shows gate-incomplete attempt=N infra=reviewer-agent:auth-missing" \
  "grep -q 'gate-incomplete attempt=1 infra=reviewer-agent:auth-missing' '$JOURNAL' && \
   grep -q 'gate-incomplete attempt=2 infra=reviewer-agent:auth-missing' '$JOURNAL'"
expect "AC6: exactly one decision question was opened" "[ \"\$(sort -u '$DECISIONS_LOG' | wc -l)\" -eq 1 ]"
expect "AC6: the opened decision names the auth sources checked" \
  "grep -qF '$SOURCES_CSV' '$DECISIONS_LOG'"
expect "AC6: the opened decision names the auth-missing phase" \
  "grep -q 'reviewer-agent:auth-missing' '$DECISIONS_LOG'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "revauth_ac6_gate_then_land_names_sources: ALL PASS"
else
  echo "revauth_ac6_gate_then_land_names_sources: FAILED" >&2
fi
exit "$fail"
