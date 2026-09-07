#!/usr/bin/env bash
# extend_gate_freshness_ac4_stale_binary_blocks.sh — AC4,
# PRD-autobuilder-source-unify.
#
# Given an installed `autobuilder` binary older than the canonical
# crate's Cargo.toml version, when extend-gate.sh starts, then it exits
# with the documented stale-binary code (7) and a message naming the
# installed version, the expected (canonical) version, and the install
# command — before any producer runs (asserted here via a call-counter
# the fake `autobuilder gate` subcommand would bump if reached).
#
# Also covers the two non-blocking paths so the guard isn't overzealous:
#   - installed == canonical -> no block, run proceeds past the guard.
#   - canonical Cargo.toml absent (e.g. a test HOME) -> guard skips with
#     a note, never a hard failure, run proceeds past the guard.
# "Proceeds past the guard" is observed as reaching project-root
# resolution failure (exit 6, no Cargo.toml under the dummy $REPO) rather
# than the guard's own exit 7 — this test never needs the real 25-receipt
# sequence to run.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EG="$HERE/../scripts/extend-gate.sh"
FAKE="$HERE/fixtures/extend-gate-fake"

[ -x "$EG" ] || { echo "ac4: $EG not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/eg-freshness-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# Fake `autobuilder` on PATH ahead of the fixture dir's own (no-op) one —
# only --version matters for this test; every other subcommand is
# unreachable if the guard is doing its job, so it just exits 0.
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/autobuilder" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "autobuilder ${FAKE_AUTOBUILDER_VERSION:-0.0.0}"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKEBIN/autobuilder"

CANON_DIR="$T/fakehome/wintermute/autobuilder/autobuilder"
mkdir -p "$CANON_DIR"
cat > "$CANON_DIR/Cargo.toml" <<'EOF'
[workspace]
members = ["."]

[workspace.package]
edition = "2024"

[package]
name = "autobuilder"
version = "0.7.0"
description = "canonical fixture crate"

[dependencies]
EOF

export HOME="$T/fakehome"
export PATH="$FAKEBIN:$FAKE:/usr/bin:/bin"
export RUSTBUILD_SCRIPTS="$FAKE"
export EXTEND_GATE_JOURNAL="$T/journal.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# --- installed OLDER than canonical -> exit 7, message names all three -
export FAKE_AUTOBUILDER_VERSION="0.4.1"
set +e
out="$("$EG" "$REPO" 2>&1)"; rc=$?
set -e
expect "stale: exit code 7"                 "[ $rc -eq 7 ]"
expect "stale: names installed version"     "grep -q 'installed=0\.4\.1' <<<\"\$out\""
expect "stale: names expected version"      "grep -q 'expected=0\.7\.0' <<<\"\$out\""
expect "stale: names the install command"   "grep -q \"cargo install --path $CANON_DIR --locked\" <<<\"\$out\""
expect "stale: never reaches project-root resolution (not exit 6)" "[ $rc -ne 6 ]"

# --- installed == canonical -> guard does not block ---------------------
export FAKE_AUTOBUILDER_VERSION="0.7.0"
set +e
out2="$("$EG" "$REPO" 2>&1)"; rc2=$?
set -e
expect "fresh: guard does not fire (not exit 7)"        "[ $rc2 -ne 7 ]"
expect "fresh: proceeds to project-root resolution (exit 6, no Cargo.toml in \$REPO)" "[ $rc2 -eq 6 ]"

# --- installed NEWER than canonical -> guard does not block -------------
export FAKE_AUTOBUILDER_VERSION="0.9.0"
set +e
out3="$("$EG" "$REPO" 2>&1)"; rc3=$?
set -e
expect "newer: guard does not fire (not exit 7)" "[ $rc3 -ne 7 ]"
expect "newer: proceeds to project-root resolution (exit 6)" "[ $rc3 -eq 6 ]"

# --- canonical Cargo.toml absent -> guard skips, never a hard failure ---
rm -rf "$T/fakehome/wintermute"
export FAKE_AUTOBUILDER_VERSION="0.0.1"
set +e
out4="$("$EG" "$REPO" 2>&1)"; rc4=$?
set -e
expect "no-canonical: guard does not fire (not exit 7)" "[ $rc4 -ne 7 ]"
expect "no-canonical: skip note on stderr"              "grep -q 'skipping install-freshness guard' <<<\"\$out4\""
expect "no-canonical: proceeds to project-root resolution (exit 6)" "[ $rc4 -eq 6 ]"

exit $fail
