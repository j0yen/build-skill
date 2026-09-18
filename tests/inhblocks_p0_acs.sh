#!/usr/bin/env bash
# inhblocks_p0_acs.sh — PRD-build-inherited-blocks-delta-pass, P0 ACs 1-5
# plus P1 ACs 7-8 and P2 AC9. Invoked as a whole suite by
# scripts/inhblocks-selftest.sh (verified-completed.sh's whole-suite
# pairing rule — each AC's own line in the PRD names that script).
#
# Exercises the scripts most of this PRD's Engineering target touches
# directly (gate-delta.sh, gate-attribution.sh via extend-gate.sh's own
# fail-closed fix, archive-trailer.sh, gate-debt.sh, extend-gate.sh
# itself) without needing a real mcphost checkout — the same "drive the
# script in isolation with a hand-built fixture" style tests/gate_delta_
# ac*.sh already uses, one file per requirement instead of per-AC so a
# single `bash tests/inhblocks_p0_acs.sh` covers the whole delta-verdict
# path. extend-gate.sh IS invoked for real (AC7) — this machine has a real
# `autobuilder` on $PATH — against a disposable 2-file fixture crate, not
# mcphost.
#
# AC6 (Live, real mcphost branch gate) is not exercised here — it needs a
# real mcphost branch gate to actually run; see the PRD's own AC6 evidence
# clause. AC8 (--main-health ignores attribution) is exercised at the
# gate-delta.sh unit level below (the exact mechanism the guarantee rests
# on: extend-gate.sh only ever builds `gate_delta_attr_args` when `$scope
# = branch`, so a main-scope/--main-health run always calls gate-delta.sh
# verdict WITHOUT --attribution and gets the pre-existing legacy verdict,
# which mirrors <gate-rc> exactly — an inherited-only block still blocks)
# rather than a full producer-pipeline run, which would just be re-testing
# unrelated producers (proof-receipt, ci-checks, ...) that this PRD never
# touches.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE_DELTA="$HERE/../scripts/gate-delta.sh"
GATE_DEBT="$HERE/../scripts/gate-debt.sh"
GATE_ATTRIBUTION="$HERE/../scripts/gate-attribution.sh"
ARCHIVE_TRAILER="$HERE/../scripts/archive-trailer.sh"
EXTEND_GATE="$HERE/../scripts/extend-gate.sh"
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
diff_out="$("$GATE_ATTRIBUTION" compute "$T/repo" HEAD HEAD "$notes" 2>"$T/attr3.stderr")"
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

# --- AC7: --explain-verdict prints scope, path, producer(=receipt), and --
# ------- the range used, per cached block ------------------------------
T7="$(mktemp -d "${TMPDIR:-/tmp}/inhblocks-ac7.XXXXXX")"
trap 'rm -rf "$T" "$T7"' EXIT
git init -q "$T7/repo"
git -C "$T7/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '[package]\nname = "inhblocks-ac7-fixture"\nversion = "0.0.0"\n' > "$T7/repo/Cargo.toml"
git -C "$T7/repo" add -A
git -C "$T7/repo" -c user.name=t -c user.email=t@t commit -q -m cargo
mkdir -p "$T7/repo/target/autobuilder"
cat > "$T7/repo/target/autobuilder/last-verdict.json" <<'EOF'
{"attribution_range":{"base":"aaa1111","head":"bbb2222"},"blocks":[{"scope":"inherited","receipt":"risk-gate","path":"src/x.rs"},{"scope":"in-scope","receipt":"ci-checks","path":"-"}]}
EOF
out7="$("$EXTEND_GATE" "$T7/repo" --explain-verdict 2>/dev/null)"; rc7=$?
expect "AC7: exit 0"                    "[ $rc7 -eq 0 ]"
expect "AC7: inherited block line: scope+receipt+path+range" \
  "grep -qE '^scope=inherited  receipt=risk-gate  path=src/x\\.rs  range=aaa1111\\.\\.bbb2222\$' <<<\"\$out7\""
expect "AC7: in-scope block line: scope+receipt+path+range" \
  "grep -qE '^scope=in-scope  receipt=ci-checks  path=-  range=aaa1111\\.\\.bbb2222\$' <<<\"\$out7\""

# --- AC8: --main-health never sees --attribution — an inherited-only ----
# ------- block on main still blocks (legacy verdict mirrors gate-rc) ----
# Structural half: extend-gate.sh only builds gate_delta_attr_args when
# $scope = branch (main-health/pinned-landing are --scope main only).
expect "AC8 (structural): attribution only wired for scope=branch" \
  "grep -qE '^\\s*if \\[ \"\\\$scope\" = branch \\] && \\[ -n \"\\\$attribution_json\" \\]; then\$' \"$HERE/../scripts/extend-gate.sh\""
# Functional half: the SAME inherited-only finding that would be
# delta-pass under --attribution (AC1) still blocks via the legacy path
# gate-delta.sh falls back to when no --attribution is passed (exactly
# what a main-scope/--main-health call does) and gate-rc is non-zero.
out8="$("$GATE_DELTA" verdict "$T/repo" /dev/null 1)"; rc8=$?
expect "AC8: legacy path (no --attribution) blocks on gate-rc=1"     "[ $rc8 -eq 1 ]"
expect "AC8: legacy path verdict=block regardless of scope shape"    "grep -q '^verdict=block\$' <<<\"\$out8\""

# --- AC9: weekly digest line, one per crate with an open debt PRD -------
T9="$(mktemp -d "${TMPDIR:-/tmp}/inhblocks-ac9.XXXXXX")"
trap 'rm -rf "$T" "$T7" "$T9"' EXIT
mkdir -p "$T9/prds/build-queue"
cat > "$T9/prds/build-queue/PRD-crate9-gate-debt-abc1234.md" <<EOF
# PRD — crate9-gate-debt-abc1234

- Status: queued
- Drafted: $(date -u -d '3 days ago' +%F)
- build_target: rust-extend
- build_into: /tmp/crate9

## Acceptance criteria

1. risk-gate passes: something.
EOF
out9="$("$GATE_DEBT" digest --prd-dir "$T9/prds" --journal "$T9/journal9.md")"
expect "AC9: prints inherited-debt line for crate9"             "grep -qE '^inherited-debt: crate=crate9 open=1 oldest=[0-9]+d\$' <<<\"\$out9\""
expect "AC9: oldest is at least 3 days"                          "n=\$(grep -oE 'oldest=[0-9]+d' <<<\"\$out9\" | grep -oE '[0-9]+'); [ \"\$n\" -ge 3 ]"
expect "AC9: journal carries the same inherited-debt line"       "grep -q 'inherited-debt: crate=crate9 open=1' \"$T9/journal9.md\""

exit $fail
