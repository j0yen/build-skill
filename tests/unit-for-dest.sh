#!/usr/bin/env bash
# tests/unit-for-dest.sh — shell tests for scripts/unit-for-dest.sh
# Coverage:
#   AC2 (PRD-vigil-build-restart-wiring): wm_unit_for_dest resolves a dest to
#       its backing unit name, and echoes empty for a dest no unit ExecStart=s.
#
# Uses a temp fixture unit dir; does NOT require a real systemd.
# Run: bash tests/unit-for-dest.sh

set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/unit-for-dest.sh"
[ -x "$SCRIPT" ] || { printf 'SKIP: %s not executable\n' "$SCRIPT"; exit 0; }

# ── Fixture setup ────────────────────────────────────────────────────────────
TMPDIR_UNITS="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_UNITS"; }
trap cleanup EXIT

# Unit A: ExecStart uses %h specifier, matches /home/user/.local/bin/foobard
cat > "$TMPDIR_UNITS/foobard.service" <<'EOF'
[Unit]
Description=Foo Daemon
[Service]
ExecStart=%h/.local/bin/foobard start
EOF

# Unit B: ExecStart uses absolute path, matches $HOME/.local/bin/bard
cat > "$TMPDIR_UNITS/bard.service" <<EOF
[Unit]
Description=Bar Daemon
[Service]
ExecStart=$HOME/.local/bin/bard serve --port 1234
EOF

# Unit C: ExecStart matches a binary in a different location — should NOT match
# a dest in ~/.local/bin
cat > "$TMPDIR_UNITS/cargo-thing.service" <<EOF
[Unit]
Description=Cargo Thing
[Service]
ExecStart=$HOME/.cargo/bin/cargo-thing run
EOF

# ── Tests ────────────────────────────────────────────────────────────────────

# T1: %h-expanded dest returns unit name
result="$(WM_UNIT_DIR="$TMPDIR_UNITS" bash "$SCRIPT" "$HOME/.local/bin/foobard")"
if [ "$result" = "foobard.service" ]; then
  ok "T1: %h-expanded ExecStart resolves to unit name"
else
  fail "T1: %h-expanded" "got '$result', want 'foobard.service'"
fi

# T2: Absolute path ExecStart dest returns unit name
result="$(WM_UNIT_DIR="$TMPDIR_UNITS" bash "$SCRIPT" "$HOME/.local/bin/bard")"
if [ "$result" = "bard.service" ]; then
  ok "T2: absolute-path ExecStart resolves to unit name"
else
  fail "T2: absolute-path" "got '$result', want 'bard.service'"
fi

# T3: Dest that no unit ExecStart=s returns empty string
result="$(WM_UNIT_DIR="$TMPDIR_UNITS" bash "$SCRIPT" "$HOME/.local/bin/nonexistent-cli")"
if [ -z "$result" ]; then
  ok "T3: unmatched dest returns empty"
else
  fail "T3: unmatched dest" "got '$result', want empty"
fi

# T4: Binary in a different bin dir (cargo) does NOT match a ~/.local/bin dest
result="$(WM_UNIT_DIR="$TMPDIR_UNITS" bash "$SCRIPT" "$HOME/.local/bin/cargo-thing")"
if [ -z "$result" ]; then
  ok "T4: cargo-bin unit does not match ~/.local/bin path"
else
  fail "T4: cargo-bin collision" "got '$result', want empty"
fi

# T5: Empty unit dir returns empty
EMPTY_DIR="$(mktemp -d)"
result="$(WM_UNIT_DIR="$EMPTY_DIR" bash "$SCRIPT" "$HOME/.local/bin/anything" 2>/dev/null)"
rm -rf "$EMPTY_DIR"
if [ -z "$result" ]; then
  ok "T5: empty unit dir returns empty"
else
  fail "T5: empty dir" "got '$result', want empty"
fi

# T6: Direct invocation from the real unit dir matches live agorabus
if [ -d "$HOME/.config/systemd/user" ]; then
  result="$(bash "$SCRIPT" "$HOME/.local/bin/agorabus" 2>/dev/null)"
  if [ "$result" = "agorabus.service" ]; then
    ok "T6: live unit dir resolves agorabus to agorabus.service"
  else
    # agorabus.service might not be present; treat as skip, not fail
    printf 'skip T6: agorabus.service not found in live dir (got "%s")\n' "$result"
  fi
else
  printf 'skip T6: no ~/.config/systemd/user dir\n'
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
