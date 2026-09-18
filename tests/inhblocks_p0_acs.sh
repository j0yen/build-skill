#!/usr/bin/env bash
# inhblocks_p0_acs.sh — PRD-build-inherited-blocks-delta-pass, P0 ACs 1-5.
#
# Exercises the scripts most of this PRD's Engineering target touches
# directly (gate-delta.sh, gate-attribution.sh via extend-gate.sh's own
# fail-closed fix, archive-trailer.sh, gate-debt.sh) without needing a
# real `autobuilder` binary or cargo — the same "drive the script in
# isolation with a hand-built fixture" style tests/gate_delta_ac*.sh
# already uses, one file per requirement instead of per-AC so a single
# `bash tests/inhblocks_p0_acs.sh` covers the whole delta-verdict path.
#
# AC6 (Live, real mcphost branch gate) and AC8 (--main-health end-to-end
# through the full producer pipeline) are not exercised here — both need
# a real repo + autobuilder run this offline fixture can't fake cheaply;
# AC8's guarantee is structural instead (extend-gate.sh only ever passes
# --attribution to gate-delta.sh when `$scope = branch`, and
# --main-health/--pinned-landing are only valid with --scope main per
# this script's own arg-parse `die` checks, so a --main-health run can
# never reach the attribution verdict path at all).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE_DELTA="$HERE/../scripts/gate-delta.sh"
GATE_DEBT="$HERE/../scripts/gate-debt.sh"
ARCHIVE_TRAILER="$HERE/../scripts/archive-trailer.sh"
PRD_LINT="$HERE/../scripts/prd-lint.sh"
export PRD_LINT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/inhblocks-p0.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q "$T/repo"
git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# --- AC1: two blocks both scope=inherited -> delta-pass, exit 0 --------
cat > "$T/attr1.json" <<'EOF'
{"blocks":[{"receipt":"a","scope":"inherited"},{"receipt":"b","scope":"inherited"}],"in_scope":0,"inherited":2}
EOF
out1="$("$GATE_DELTA" verdict "$T/repo" /dev/null 0 --attribution "$T/attr1.json")"; rc1=$?
expect "AC1: exit 0"                 "[ $rc1 -eq 0 ]"
expect "AC1: verdict=delta-pass"     "grep -q '^verdict=delta-pass\$' <<<\"\$out1\""
expect "AC1: baseline=attribution"   "grep -q '^baseline=attribution\$' <<<\"\$out1\""
expect "AC1: both named inherited"   "grep -q '^inherited_blocks=a,b\$' <<<\"\$out1\""

# --- AC2: one in-scope + three inherited -> block, in-scope named -------
cat > "$T/attr2.json" <<'EOF'
{"blocks":[{"receipt":"x","scope":"in-scope"},{"receipt":"a","scope":"inherited"},{"receipt":"b","scope":"inherited"},{"receipt":"c","scope":"inherited"}],"in_scope":1,"inherited":3}
EOF
out2="$("$GATE_DELTA" verdict "$T/repo" /dev/null 1 --attribution "$T/attr2.json")"; rc2=$?
expect "AC2: exit 1"                 "[ $rc2 -eq 1 ]"
expect "AC2: verdict=block"          "grep -q '^verdict=block\$' <<<\"\$out2\""
expect "AC2: in-scope receipt named" "grep -q '^new_blocks=x\$' <<<\"\$out2\""

# --- AC3: unknown producer inputs -> in-scope, fail-closed --------------
notes="$T/notes.tsv"
printf 'mystery-receipt\tno path or test token here\n' > "$notes"
diff_out="$("$HERE/../scripts/gate-attribution.sh" compute "$T/repo" HEAD HEAD "$notes" 2>"$T/attr3.stderr")"
expect "AC3: scope is in-scope"          "echo \"\$diff_out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"blocks\"][0][\"scope\"]==\"in-scope\" else 1)'"
expect "AC3: block flagged unknown-inputs" "echo \"\$diff_out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"blocks\"][0].get(\"attribution\")==\"unknown-inputs\" else 1)'"
expect "AC3: unknown_inputs count is 1"    "echo \"\$diff_out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"unknown_inputs\"]==1 else 1)'"
expect "AC3: stderr summary carries attribution=unknown-inputs" "grep -q 'attribution=unknown-inputs' \"$T/attr3.stderr\""

# --- AC4: delta-pass ship's archive trailer, auto-populated -------------
mkdir -p "$T/repo/target/autobuilder"
cat > "$T/repo/target/autobuilder/last-verdict.json" <<'EOF'
{"verdict":"delta-pass","inherited_blocks":["a","b"]}
EOF
mkdir -p "$T/prds/build-queue" "$T/prds/built-prds"
cat > "$T/prds/build-queue/PRD-ac4fixture.md" <<EOF
# PRD — ac4fixture

- Status: queued
- build_target: shell
- build_into: $T/repo

## Acceptance criteria

1. one thing happens.
EOF
out4="$("$ARCHIVE_TRAILER" "$T/prds/build-queue/PRD-ac4fixture.md" --paired 1=smoke-test)"; rc4=$?
expect "AC4: exit 0"                                "[ $rc4 -eq 0 ]"
expect "AC4: inherited_blocks=[a, b]"               "grep -q '^inherited_blocks=\[a, b\]\$' <<<\"\$out4\""
expect "AC4: Receipts line verdict=delta-pass inherited=2" "grep -q '^Receipts: verdict=delta-pass inherited=2\$' <<<\"\$out4\""

# --- AC5: first gate whose inherited set matches main -> draft now, ----
# ------- no Depends-on added -------------------------------------------
git init -q --bare "$T/prds-origin.git"
git init -q "$T/prds5"
mkdir -p "$T/prds5/build-queue" "$T/prds5/built-prds" "$T/prds5/visions"
: > "$T/prds5/visions/buildloop-operations.md"
git -C "$T/prds5" remote add origin "$T/prds-origin.git"
FAKE_REPO5="$T/fake-repo5"
mkdir -p "$FAKE_REPO5/target/autobuilder"
printf '[package]\nname = "fake-repo5"\nversion = "0.0.0"\n' > "$FAKE_REPO5/Cargo.toml"
git -C "$T/prds5" add -A
git -C "$T/prds5" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/prds5" push -q -u origin HEAD:main
VERDICT5="$T/verdict5.json"
cat > "$VERDICT5" <<'EOF'
{"blocks":[{"receipt":"risk-gate","finding":"x","path":"src/runs.rs","scope":"inherited"}],"in_scope":0,"inherited":1}
EOF
cp "$VERDICT5" "$FAKE_REPO5/target/autobuilder/last-verdict.json"
out5="$("$GATE_DEBT" check "$FAKE_REPO5" deadbeefcafefeed0000000000000000000abcd \
  --verdict-file "$VERDICT5" --prd-dir "$T/prds5" --state-dir "$T/state5" --journal "$T/journal5.md" 2>&1)"
drafted5="$(ls "$T/prds5/build-queue/" 2>/dev/null | grep gate-debt || true)"
expect "AC5: a debt PRD exists after the FIRST check" "[ -n \"\$drafted5\" ]"
expect "AC5: no Depends-on line anywhere in build-queue" \
  "! grep -rlE '^-?\s*Depends-on:' \"$T/prds5/build-queue\" >/dev/null 2>&1"
expect "AC5: journal has no gate-debt parked line" "! grep -q 'gate-debt  parked' \"$T/journal5.md\""

exit $fail
