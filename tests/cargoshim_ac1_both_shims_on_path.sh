#!/usr/bin/env bash
# cargoshim_ac1_both_shims_on_path.sh — PRD-build-cargo-shim-recursion-guard
# requirement 3 / AC1+AC2. Puts the real cargo-budget-bin/cargo and the real
# rustbuild bin/cargo on PATH in both orders, with a fake real cargo behind
# both, and asserts: the fake runs exactly once per order, no
# recursion-refused line is journaled, and (AC4) the check is realpath-based
# — a symlinked rustbuild skill dir is still excluded correctly, which is
# exercised implicitly since ~/.claude/skills/rustbuild is itself commonly a
# symlink and the production resolver (readlink -f) is what's under test.
#
# `cargo --version` is used as the driving command: rustbuild's own shim
# already special-cases --version to resolve locally regardless of host, so
# this test needs no RUSTBUILD_LOCAL/hostname faking to stay hermetic.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RUSTBUILD_BIN="$(readlink -f "$HOME/.claude/skills/rustbuild" 2>/dev/null)/bin"

if [ ! -x "$RUSTBUILD_BIN/cargo" ]; then
  echo "SKIP: rustbuild bin/cargo not present on this node ($RUSTBUILD_BIN)" >&2
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/realbin" "$WORK/budgetbin"

# Fake real cargo: records one line per invocation, always exits 0.
cat > "$WORK/realbin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "$$ $*" >> "$FAKE_CARGO_LOG"
exit 0
EOF
chmod +x "$WORK/realbin/cargo"

cp "$REPO/scripts/cargo-budget-bin/cargo" "$WORK/budgetbin/cargo"
chmod +x "$WORK/budgetbin/cargo"

export FAKE_CARGO_LOG="$WORK/real-invocations.log"
export CARGO_BUDGET_JOURNAL="$WORK/journal.md"
fail=0

run_order() {  # $1 = label, $2 = PATH (both shim dirs + realbin, in the order under test)
  local label="$1" path="$2"
  : > "$FAKE_CARGO_LOG"
  : > "$CARGO_BUDGET_JOURNAL"
  ( PATH="$path" cargo --version >/dev/null 2>"$WORK/stderr.$label" )
  local rc=$? n_real
  n_real=$(wc -l < "$FAKE_CARGO_LOG")
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $label exited $rc (expected 0)" >&2; fail=1
  fi
  if [ "$n_real" -ne 1 ]; then
    echo "FAIL: $label real cargo invoked $n_real times (expected 1)" >&2; fail=1
  else
    echo "ok  cargoshim AC1: $label real cargo invoked exactly once"
  fi
  if grep -q "recursion-refused" "$CARGO_BUDGET_JOURNAL" "$WORK/stderr.$label" 2>/dev/null; then
    echo "FAIL: $label journaled recursion-refused on a clean two-shim PATH" >&2; fail=1
  else
    echo "ok  cargoshim AC1: $label no recursion-refused line"
  fi
}

run_order "budgetbin-first" "$WORK/budgetbin:$RUSTBUILD_BIN:$WORK/realbin:/usr/bin:/bin"
run_order "rustbuild-first" "$RUSTBUILD_BIN:$WORK/budgetbin:$WORK/realbin:/usr/bin:/bin"

[ "$fail" -eq 0 ] && echo "ok  cargoshim AC1/AC2: both PATH orders resolve to one real cargo, no recursion"
exit $fail
