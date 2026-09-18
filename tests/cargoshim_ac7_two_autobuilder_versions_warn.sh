#!/usr/bin/env bash
# cargoshim_ac7_two_autobuilder_versions_warn.sh — AC7,
# PRD-build-cargo-shim-recursion-guard requirement 6 (P1).
#
# Given two `autobuilder` binaries on PATH with different --version output
# (evidence: ~/.cargo/bin/autobuilder 0.9.0 vs ~/.local/bin/autobuilder
# 0.9.1), when extend-gate.sh preflights, then one warning line names both
# paths and versions, and the guard never blocks (proceeds past preflight
# to project-root resolution, exit 6 for a dummy repo with no Cargo.toml —
# same "guard didn't fire" proxy as extend_gate_freshness_ac4).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EG="$HERE/../scripts/extend-gate.sh"
FAKE="$HERE/fixtures/extend-gate-fake"

[ -x "$EG" ] || { echo "ac7: $EG not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/eg-abshadow-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

mkfake() {  # $1=dir $2=version
  mkdir -p "$1"
  cat > "$1/autobuilder" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "autobuilder $2"
  exit 0
fi
exit 0
EOF
  chmod +x "$1/autobuilder"
}

mkfake "$T/cargobin" "0.9.0"
mkfake "$T/localbin" "0.9.1"

# No canonical Cargo.toml -> install-freshness guard (the FIRST autobuilder
# on PATH only) skips with a note, never blocks -- isolates this test to
# just the new PATH-shadow preflight.
export HOME="$T/fakehome"
mkdir -p "$HOME"
export PATH="$T/cargobin:$T/localbin:$FAKE:/usr/bin:/bin"
export RUSTBUILD_SCRIPTS="$FAKE"
export EXTEND_GATE_JOURNAL="$T/journal.md"
export BUILD_STATE_DIR="$T/probestate"
export PROBE_JOURNAL_DIR="$T/probe-journal"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

set +e
out="$("$EG" "$REPO" 2>&1)"; rc=$?
set -e

expect "warns naming first path+version"  "grep -q '$T/cargobin/autobuilder (0.9.0)' <<<\"\$out\""
expect "warns naming second path+version" "grep -q '$T/localbin/autobuilder (0.9.1)' <<<\"\$out\""
expect "exactly one warning line"         "[ \"\$(grep -c 'two autobuilder binaries with different versions' <<<\"\$out\")\" -eq 1 ]"
expect "journaled autobuilder-path-shadow" "grep -q 'autobuilder-path-shadow' \"$T/journal.md\""
expect "never blocks (not exit 7)"        "[ \$rc -ne 7 ]"
expect "proceeds past preflight (exit 6, no Cargo.toml in \$REPO)" "[ \$rc -eq 6 ]"

exit $fail
