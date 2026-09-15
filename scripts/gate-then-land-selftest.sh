#!/usr/bin/env bash
# gate-then-land-selftest.sh — PRD-build-gate-before-land requirement 3
# (P0) / AC3, AC5, AC6: the rebase-and-regate loop.
#
#   AC3/scenario A — two consecutive stale bases, then a clean land: exits
#     0, main advances, the sidecar/journal record exactly 2 retries.
#   AC5/scenario B — three consecutive stale bases (== --max-retries):
#     exits 6 `land-retries-exhausted`, all 3 main shas seen are recorded,
#     main is left at whatever the LAST simulated sibling landed (the
#     branch itself never merges).
#   AC6/scenario C — the branch's own gate verdict is `block`: exits 7
#     `land-ungated` on the FIRST attempt, no retry, main untouched.
#
# `extend-gate.sh` is swapped for a tiny fixture stub via
# GATE_THEN_LAND_EXTEND_GATE (gate-then-land.sh's own "overridable so
# tests/ ..." convention) — a real gate is a real 60-90s+ cargo/autobuilder
# producer sequence per attempt; this selftest is about the LOOP
# (retry-count, rebase, exit-code mapping, sidecar/journal), already
# exercised for real by extend-gate-scope-selftest.sh /
# extend-gate-concurrent-selftest.sh elsewhere. `worktree-extend.sh` is
# the REAL script throughout — its land/integrate git mechanics are fast
# and already covered by worktree-extend-gated-land-selftest.sh; this
# selftest's value-add is the orchestration wrapped around it. The stub
# also simulates "a sibling landed first" (the thing that makes
# `integrate --gated-at` return exit 6) as a controlled side effect, since
# nothing else in a single synchronous process can race main between
# gate-then-land.sh's own steps.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GTL="$HERE/gate-then-land.sh"
[ -x "$GTL" ] || { echo "selftest: $GTL not executable" >&2; exit 2; }
for bin in git jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-then-land-selftest.XXXXXX")"
export BUILD_WT_ROOT="$T/build-worktrees"
# Isolation: gate-then-land.sh writes sidecars via manifest-sidecar.sh on
# every retry/block/land outcome — without this override those land in
# the REAL skill state/status/ dir under this selftest's throwaway slugs.
export STATE_DIR="$T/state"
GIT_ID=(-c user.email=test@gtl-selftest.local -c user.name="gtl-selftest")
trap '[ -n "${GTL_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

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
rc=0; [ "$verdict" = block ] && rc=1
jq -n --arg head "$head_sha" --arg tree "$tree_now" --arg scope "$scope" --arg slug "$slug" \
     --arg verdict "$verdict" --argjson rc "$rc" '
  {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: "fake",
   verdict: $verdict, exit_code: $rc,
   new_blocks: (if $verdict == "block" then ["fake-blocker"] else [] end),
   inherited_blocks: [], scope: $scope, slug: $slug}' > "$cache_file"
# Simulated concurrent sibling: consume one unit from the counter file (if
# armed) and commit a throwaway change onto the MAIN repo, so the caller's
# already-captured `--gated-at` goes stale by the time it calls `land`.
if [ -n "${FAKE_GATE_ADVANCE_MAIN_REPO:-}" ] && [ -f "${FAKE_GATE_ADVANCE_COUNTER:-/nonexistent}" ]; then
  remaining="$(cat "$FAKE_GATE_ADVANCE_COUNTER")"
  if [ "$remaining" -gt 0 ]; then
    echo $((remaining - 1)) > "$FAKE_GATE_ADVANCE_COUNTER"
    echo "sibling" >> "$FAKE_GATE_ADVANCE_MAIN_REPO/SIBLING.md"
    git -C "$FAKE_GATE_ADVANCE_MAIN_REPO" -c user.email=sib@sib -c user.name=sib add -A
    git -C "$FAKE_GATE_ADVANCE_MAIN_REPO" -c user.email=sib@sib -c user.name=sib commit -q -m "sibling landed (fake, attempt)"
  fi
fi
exit "$rc"
FAKE
chmod +x "$T/fake-extend-gate.sh"

mk_repo_and_branch() {  # $1=name -> prints "repo wt" on stdout
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
  wt="$("$HERE/worktree-extend.sh" add "$repo" "${name}-slug" 2>/dev/null)"
  printf 'pub fn g() {}\n' >> "$wt/src/lib.rs"
  git -C "$wt" "${GIT_ID[@]}" add -A
  git -C "$wt" "${GIT_ID[@]}" commit -q -m "branch work"
  printf '%s %s\n' "$repo" "$wt"
}

# =========================================================================
# Scenario A (AC3) — 2 stale bases, then a clean land
# =========================================================================
echo "=== Scenario A: 2 stale bases then a clean land ==="
read -r REPO_A WT_A < <(mk_repo_and_branch scenA)
JOURNAL_A="$T/journal-a.md"
echo 2 > "$T/counter-a"
out_a="$T/out-a.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL_A" WORKTREE_EXTEND_JOURNAL="$JOURNAL_A" \
    FAKE_GATE_ADVANCE_MAIN_REPO="$REPO_A" FAKE_GATE_ADVANCE_COUNTER="$T/counter-a" \
    "$GTL" "$REPO_A" scenA-slug minor /dev/null >"$out_a" 2>"$out_a.err"
rc_a=$?
cat "$out_a" "$out_a.err" >&2
expect "AC3: gate-then-land exits 0 (eventually landed)" "[ $rc_a -eq 0 ]"
expect "AC3: stdout printed the landed sha (40 hex chars)" "grep -qE '^[0-9a-f]{40}$' \"$out_a\""
retry_lines_a="$(grep -c "stale-base-retry" "$JOURNAL_A" 2>/dev/null || echo 0)"
expect "AC3: exactly 2 stale-base-retry journal lines" "[ \"$retry_lines_a\" -eq 2 ]"
expect "AC3: exactly 1 'landed' journal line" "[ \"\$(grep -c ' landed ' \"$JOURNAL_A\" 2>/dev/null || echo 0)\" -eq 1 ]"

# =========================================================================
# Scenario B (AC5) — 3 consecutive stale bases == max-retries: blocked
# =========================================================================
echo "=== Scenario B: 3 consecutive stale bases -> land-retries-exhausted ==="
read -r REPO_B WT_B < <(mk_repo_and_branch scenB)
JOURNAL_B="$T/journal-b.md"
echo 3 > "$T/counter-b"
out_b="$T/out-b.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL_B" WORKTREE_EXTEND_JOURNAL="$JOURNAL_B" \
    FAKE_GATE_ADVANCE_MAIN_REPO="$REPO_B" FAKE_GATE_ADVANCE_COUNTER="$T/counter-b" \
    "$GTL" "$REPO_B" scenB-slug minor /dev/null --max-retries 3 >"$out_b" 2>"$out_b.err"
rc_b=$?
cat "$out_b" "$out_b.err" >&2
expect "AC5: gate-then-land exits 6 (land-retries-exhausted)" "[ $rc_b -eq 6 ]"
expect "AC5: stderr names land-retries-exhausted" "grep -q land-retries-exhausted \"$out_b.err\""
exhausted_line="$(grep "land-retries-exhausted" "$JOURNAL_B" 2>/dev/null || true)"
expect "AC5: a land-retries-exhausted journal line exists" "[ -n \"$exhausted_line\" ]"
shas_recorded="$(printf '%s' "$exhausted_line" | grep -oE 'main_shas=[^ ]+' | head -1)"
sha_count="$(awk -F, '{print NF}' <<<"${shas_recorded#main_shas=}")"
expect "AC5: 3 main shas were recorded" "[ -n \"$shas_recorded\" ] && [ \"$sha_count\" -eq 3 ]"
expect "AC5: the branch itself never merged onto main (no 'landed' line)" "! grep -q ' landed ' \"$JOURNAL_B\""

# =========================================================================
# Scenario C (AC6) — gate verdict block: exit 7, no retry, main untouched
# =========================================================================
echo "=== Scenario C: gate verdict block -> land-ungated, no retry ==="
read -r REPO_C WT_C < <(mk_repo_and_branch scenC)
MAIN_BEFORE_C="$(git -C "$REPO_C" rev-parse HEAD)"
JOURNAL_C="$T/journal-c.md"
out_c="$T/out-c.log"
env GATE_THEN_LAND_EXTEND_GATE="$T/fake-extend-gate.sh" \
    GATE_THEN_LAND_JOURNAL="$JOURNAL_C" WORKTREE_EXTEND_JOURNAL="$JOURNAL_C" FAKE_GATE_VERDICT=block \
    "$GTL" "$REPO_C" scenC-slug minor /dev/null >"$out_c" 2>"$out_c.err"
rc_c=$?
cat "$out_c" "$out_c.err" >&2
expect "AC6: gate-then-land exits 7 (land-ungated)" "[ $rc_c -eq 7 ]"
expect "AC6: stderr names the fake blocker" "grep -q fake-blocker \"$out_c.err\""
expect "AC6: only ONE gate attempt was made (no retry on a real block)" \
  "[ \"\$(grep -c 'attempt 1/3' \"$out_c.err\" 2>/dev/null || echo 0)\" -ge 1 ] && ! grep -q 'attempt 2/3' \"$out_c.err\""
expect "AC6: main is byte-for-byte unchanged" "[ \"\$(git -C \"$REPO_C\" rev-parse HEAD)\" = \"$MAIN_BEFORE_C\" ]"
expect "AC6: a gate-block journal line was written" "grep -q gate-block \"$JOURNAL_C\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "gate-then-land-selftest: ALL PASS"
  exit 0
else
  echo "gate-then-land-selftest: assertion(s) FAILED"
  exit 1
fi
