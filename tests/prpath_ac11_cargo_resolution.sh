#!/usr/bin/env bash
# tests/prpath_ac11_cargo_resolution.sh — PRD-build-main-push-gate-pr-path
# AC11. Given the check subprocess is invoked with a PATH lacking
# ~/.cargo/bin but ~/.cargo/bin/cargo present, main-push-gate.sh resolves
# it and the check runs (real cargo, real crate — same fixture AC1/AC2
# use); given cargo is absent everywhere (PATH stripped AND $CARGO points
# nowhere), it refuses with `main-push refused reason=cargo-not-found`
# and never a bare rc=127. Reuses tests/fixtures/mainpush-common.sh's real
# git+cargo fixture (PRD-build-main-push-gate) rather than a second
# hand-rolled one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac11.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

command -v cargo >/dev/null 2>&1 || { echo "prpath_ac11: cargo not on PATH in this environment — skipping (nothing to prove)"; exit 0; }
real_cargo_dir="$(dirname "$(command -v cargo)")"

# PATH with the real cargo's directory removed -- reproduces "a
# non-interactive shell whose PATH never sourced ~/.cargo/bin" without
# needing a fake HOME (this box's own cargo already lives at the exact
# default this guard resolves, $HOME/.cargo/bin/cargo).
stripped_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vF "$real_cargo_dir" | paste -sd: -)"

work="$(mainpush_mkfixture "$ROOT")"
gated="$(git -C "$work" rev-parse HEAD)"
matching="$(mainpush_matching_commit "$work")"

# --- case A: cargo missing from PATH, present at the default location --
# $CARGO is set explicitly here (rather than relying on the bare
# ${CARGO:-$HOME/.cargo/bin/cargo} default) so this case is not coupled to
# $HOME -- run-selftests.sh's isolation wrapper redirects HOME under a
# throwaway root for every test it runs (by design, PRD-build-test-
# isolation-by-default), which would otherwise hide this box's real
# ~/.cargo/bin from the very fallback this case means to exercise. The
# guard itself checks $CARGO first, so this is the same code path a real
# ~/.cargo/bin/cargo would take when $HOME is genuinely unset/wrong.
out_a="$(env PATH="$stripped_path" CARGO="$real_cargo_dir/cargo" bash "$MAINPUSH_GATE" "$work" --gated "$gated" --head "$matching" 2>&1)"
rc_a=$?
mainpush_expect "AC11 A: gate still finds cargo and runs the check (exit 0)" '[ "$rc_a" -eq 0 ]'
mainpush_expect "AC11 A: no bare rc=127" '! printf "%s" "$out_a" | grep -q "127"'
journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
mainpush_expect "AC11 A: journal has an ok line, not cargo-not-found" \
  'grep -q "main-push  ok" "$journal_file" && ! grep -q "cargo-not-found" "$journal_file"'

# --- case B: cargo absent everywhere (stripped PATH, $CARGO unresolvable) -
: > "$journal_file"
out_b="$(env PATH="$stripped_path" CARGO=/nonexistent/cargo-not-here bash "$MAINPUSH_GATE" "$work" --gated "$gated" --head "$matching" 2>&1)"
rc_b=$?
mainpush_expect "AC11 B: refuses (exit 4), never a bare rc=127" '[ "$rc_b" -eq 4 ]'
mainpush_expect "AC11 B: names the reason" 'printf "%s" "$out_b" | grep -q "main-push refused reason=cargo-not-found"'
mainpush_expect "AC11 B: journal names cargo-not-found" 'grep -q "reason=cargo-not-found" "$journal_file"'

exit "$mainpush_fail"
