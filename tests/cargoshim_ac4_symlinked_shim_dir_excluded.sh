#!/usr/bin/env bash
# cargoshim_ac4_symlinked_shim_dir_excluded.sh — PRD-build-cargo-shim-recursion-guard
# requirement 2 / AC4: "Given ~/.claude/skills/rustbuild is a symlink, when the
# resolver walks PATH, then the symlink target's bin dir is excluded (compared by
# realpath) and the real cargo is chosen."
#
# cargoshim_ac1 cannot prove this: it resolves RUSTBUILD_BIN with `readlink -f`
# before putting it on PATH, so the resolver only ever sees canonical paths and a
# resolver that compared raw $PATH strings against SHIM_DIRS would pass it too.
# This test puts *symlinked* shim dirs on PATH — pointing at the same targets
# under different names — so it fails unless each PATH entry is canonicalised
# (`cd "$dir" && pwd -P`) before being matched against the shim set.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/realbin" "$WORK/real-budgetbin" "$WORK/links"

# Fake real cargo: records one line per invocation, always exits 0.
cat > "$WORK/realbin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "$$ $*" >> "$FAKE_CARGO_LOG"
exit 0
EOF
chmod +x "$WORK/realbin/cargo"

# A stand-in for cargo-budget-bin, reached through a symlinked dir name. The
# shim resolves its own dir with `pwd -P`, so $HERE is the canonical
# $WORK/real-budgetbin even when invoked via $WORK/links/budget-alias.
cp "$REPO/scripts/cargo-budget-bin/cargo" "$WORK/real-budgetbin/cargo"
chmod +x "$WORK/real-budgetbin/cargo"
ln -s "$WORK/real-budgetbin" "$WORK/links/budget-alias"

export FAKE_CARGO_LOG="$WORK/real-invocations.log"
export CARGO_BUDGET_JOURNAL="$WORK/journal.md"
fail=0

assert_one_real() {  # $1 = label, $2 = PATH under test
  local label="$1" path="$2" rc n_real
  : > "$FAKE_CARGO_LOG"
  : > "$CARGO_BUDGET_JOURNAL"
  ( PATH="$path" cargo --version >/dev/null 2>"$WORK/stderr.$label" )
  rc=$?
  n_real=$(wc -l < "$FAKE_CARGO_LOG")
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $label exited $rc (expected 0)" >&2
    sed -n '1,5p' "$WORK/stderr.$label" >&2
    fail=1
  fi
  if [ "$n_real" -ne 1 ]; then
    echo "FAIL: $label real cargo invoked $n_real times (expected exactly 1)" >&2
    fail=1
  else
    echo "ok  cargoshim AC4: $label real cargo invoked exactly once"
  fi
  if grep -q "recursion-refused" "$CARGO_BUDGET_JOURNAL" "$WORK/stderr.$label" 2>/dev/null; then
    echo "FAIL: $label journaled recursion-refused on a symlinked-but-sane PATH" >&2
    fail=1
  fi
}

# Case 1 — the shim's OWN dir reached under a symlinked name, ahead of the real
# cargo. A raw-string resolver does not recognise $WORK/links/budget-alias as
# $HERE, walks into it, and re-execs itself until the depth guard trips (exit 9)
# or the fake cargo is never reached; the realpath resolver skips it.
assert_one_real "self-dir-via-symlink" \
  "$WORK/real-budgetbin:$WORK/links/budget-alias:$WORK/realbin:/usr/bin:/bin"

# Case 2 — rustbuild's bin dir reached through the skill symlink itself. This is
# the literal AC4 wording: ~/.claude/skills/rustbuild is a symlink on this node,
# so the UNRESOLVED path is what a real gate's PATH carries (branch-contract §3
# prepends "$HOME/.claude/skills/rustbuild/bin" verbatim, never readlink -f'd).
RB_LINK="$HOME/.claude/skills/rustbuild"
if [ -L "$RB_LINK" ] && [ -x "$RB_LINK/bin/cargo" ]; then
  RB_REAL="$(readlink -f "$RB_LINK")/bin"
  if [ "$RB_LINK/bin" = "$RB_REAL" ]; then
    echo "SKIP: rustbuild path is not actually indirected; case 2 is vacuous" >&2
  else
    assert_one_real "rustbuild-bin-via-skill-symlink" \
      "$WORK/real-budgetbin:$RB_LINK/bin:$WORK/realbin:/usr/bin:/bin"
  fi
else
  echo "SKIP: $RB_LINK is not a symlink to an installed rustbuild on this node" >&2
fi

[ "$fail" -eq 0 ] && echo "ok  cargoshim AC4: symlinked shim dirs on PATH are excluded by realpath"
exit $fail
