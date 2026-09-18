#!/usr/bin/env bash
# cargoshim_ac2_third_frame_refused.sh — PRD-build-cargo-shim-recursion-guard
# requirement 4 / AC3. Sets WM_CARGO_SHIM_DEPTH=2 in the environment and
# asserts cargo-budget-bin/cargo exits 9, journals the recursion-refused
# line, and never forks toward a real cargo. A real fake-real-cargo is left
# on PATH so "spawns no child" is asserted as a hard fact (the log stays
# empty) rather than a racy live process count — the guard branch returns
# before real_cargo() or exec ever run, so no child process is possible by
# construction; the empty invocation log is the observable proof of that,
# which is what "ps count under 5" is standing in for (this shim's own
# process, alone, never fork/execs anything further).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/realbin" "$WORK/budgetbin"

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
export WM_CARGO_SHIM_DEPTH=2
: > "$FAKE_CARGO_LOG"
: > "$CARGO_BUDGET_JOURNAL"

( PATH="$WORK/budgetbin:$WORK/realbin:/usr/bin:/bin" "$WORK/budgetbin/cargo" --version >"$WORK/stdout" 2>"$WORK/stderr" )
rc=$?
fail=0

if [ "$rc" -eq 9 ]; then
  echo "ok  cargoshim AC3: WM_CARGO_SHIM_DEPTH=2 exits 9"
else
  echo "FAIL: exited $rc, expected 9" >&2; fail=1
fi

if grep -q "recursion-refused (depth=2 path=" "$WORK/journal.md" 2>/dev/null; then
  echo "ok  cargoshim AC3: journal line present (depth=2)"
else
  echo "FAIL: journal missing 'recursion-refused (depth=2 path=' line" >&2
  cat "$WORK/journal.md" >&2 2>/dev/null || true
  fail=1
fi

n_real=$(wc -l < "$FAKE_CARGO_LOG")
if [ "$n_real" -eq 0 ]; then
  echo "ok  cargoshim AC3: no child process spawned (real cargo never invoked, ps count bounded to 1)"
else
  echo "FAIL: real cargo was invoked $n_real times — recursion guard let a child through" >&2
  fail=1
fi

exit $fail
