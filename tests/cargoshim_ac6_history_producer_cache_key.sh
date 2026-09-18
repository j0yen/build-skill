#!/usr/bin/env bash
# cargoshim_ac6_history_producer_cache_key.sh — PRD-build-cargo-shim-
# recursion-guard P1 requirement 5 (AC6): the verdict cache normally keys
# on tree_sha alone (gate-verdict-tree-cache-selftest.sh AC7a-d), but a
# CACHED run whose phases actually ran rollback-plan or ci-checks (history-
# dependent producers) must also match head_sha — a content-preserving
# reword (same tree, new head) re-runs the whole gate instead of replaying
# a stale block. Operator design sign-off 2026-09-18T12:50Z (PRD iter_log):
# whole-gate key, not per-producer partial replay.
#
#   AC6a — cached phases include rollback-plan (ran, not skip); tree
#          matches current tree but head_sha does not (reword) -> MISS,
#          never reports (cached).
#   AC6b — same but ci-checks instead of rollback-plan -> MISS.
#   AC6c — cached phases have neither producer (or both `skip`); tree
#          matches, head_sha does not (reword) -> HIT, same as today's
#          tree-only key (unchanged behavior for tree-scoped producers).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/../scripts/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }
for bin in git jq sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || { echo "selftest: $bin not on \$PATH, cannot run" >&2; exit 2; }
done

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/cargoshim-ac6-selftest.XXXXXX")"
GIT_ID=(-c user.email=test@cargoshim-ac6-selftest.local -c user.name="cargoshim-ac6-selftest")
JOURNAL="$T/journal.md"
export EXTEND_GATE_JOURNAL="$JOURNAL"
trap '[ -n "${CARGOSHIM_AC6_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

SELF_HASH="$(sha256sum "$EXTEND_GATE" | awk '{print $1}')"

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "cargoshim-ac6-fixture"
version = "0.1.0"
edition = "2021"
license = "MIT"

[dependencies]
EOF
mkdir -p "$REPO/src"
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$REPO/src/lib.rs"
printf '/target\n/.cargo\n/Cargo.lock\n' > "$REPO/.gitignore"
( cd "$REPO" && cargo generate-lockfile >/dev/null 2>&1 ) || true
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -q -m "initial message"
HEAD1="$(git -C "$REPO" rev-parse HEAD)"
TREE1="$(git -C "$REPO" rev-parse "HEAD^{tree}")"

# Reword: identical tree, new head.
git -C "$REPO" "${GIT_ID[@]}" commit -q --amend -m "reworded message"
HEAD2="$(git -C "$REPO" rev-parse HEAD)"
TREE2="$(git -C "$REPO" rev-parse "HEAD^{tree}")"
expect "setup: reword kept the same tree" "[ \"$TREE1\" = \"$TREE2\" ]"
expect "setup: reword changed head" "[ \"$HEAD1\" != \"$HEAD2\" ]"

CACHE_FILE="$REPO/target/autobuilder/last-verdict.json"
mkdir -p "$(dirname "$CACHE_FILE")"

write_cache() {  # $1=phases json
  jq -n --arg head "$HEAD1" --arg tree "$TREE1" --arg hash "$SELF_HASH" --argjson phases "$1" '
    {head_sha: $head, head: $head, tree_sha: $tree, script_sha256: $hash,
     verdict: "pass", exit_code: 0, new_blocks: [], inherited_blocks: [],
     cargo_route: {intended: "local", burst: 0, local: 0, passthrough: 0, host: "local"},
     blocks: [], attribution: {in_scope: 0, inherited: 0}, phases: $phases, wall_s: 1,
     scope: "main", slug: ""}' > "$CACHE_FILE"
}

run_gate() {  # $1=output file
  env PATH="$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
    timeout -k 3 20 "$EXTEND_GATE" "$REPO" --head "$HEAD2" >"$1" 2>&1 || true
}

echo "=== AC6a: cached rollback-plan ran, reworded head -> MISS ==="
write_cache '{"rollback-plan": "4"}'
out_a="$T/gate-a.out"
run_gate "$out_a"
expect "AC6a: reworded head never reports (cached)" "! grep -q '(cached)' \"$out_a\""

echo "=== AC6b: cached ci-checks ran, reworded head -> MISS ==="
write_cache '{"ci-checks": "2"}'
out_b="$T/gate-b.out"
run_gate "$out_b"
expect "AC6b: reworded head never reports (cached)" "! grep -q '(cached)' \"$out_b\""

echo "=== AC6c: neither history producer ran, reworded head -> HIT (tree-only key unchanged) ==="
write_cache '{"risk-gate": "1", "rollback-plan": "skip", "ci-checks": "skip"}'
out_c="$T/gate-c.out"
run_gate "$out_c"
expect "AC6c: reworded head still reports (cached) when no history producer ran" "grep -q '(cached)' \"$out_c\""

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "cargoshim_ac6: ALL PASS"
  exit 0
else
  echo "cargoshim_ac6: assertion(s) FAILED"
  exit 1
fi
