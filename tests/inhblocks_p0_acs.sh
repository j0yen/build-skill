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

# --- requirement 2, main-scope clause: a SQUASH landing's attribution ---
# ------- range comes from state/landings/<repo>/<slug>.json, not the ----
# ------- newest version tag --------------------------------------------
# No AC of this PRD names this clause directly (ACs 1-9 cover requirement
# 2 only via AC3's unknown-inputs half), but requirement 2 states it, and
# gate-then-land.sh lands via `--squash` -> a ONE-parent commit, which the
# merge-parent rule above it cannot catch. Fixture: a repo tagged v0.1.0
# followed by THREE single-parent "landings"; the attribution range for
# the last one must cover only its own file, not the two before it.
#
# The block under test is EXTRACTED FROM THE SHIPPED extend-gate.sh by its
# own BEGIN/END marker (the convention tests/canary_ac15_route_block.sh
# already uses), so this proves the code that actually runs rather than a
# transcription of it.
TR2="$(mktemp -d "${TMPDIR:-/tmp}/inhblocks-r2.XXXXXX")"
trap 'rm -rf "$T" "$T7" "$T9" "$TR2" "${T10:-}" "${T11:-}"' EXIT
(
  cd "$TR2" && git init -q repo && cd repo
  git config user.email t@t && git config user.name t
  echo base > base.txt && git add -A && git commit -qm base
  git tag v0.1.0
  for f in landed_one landed_two landed_three; do
    echo x > "$f.txt" && git add -A && git commit -qm "$f"
  done
) >/dev/null 2>&1
M="$(git -C "$TR2/repo" rev-parse HEAD)"
mkdir -p "$TR2/state/landings/repo"
printf '{"merge_sha": "%s"}\n' "$M" > "$TR2/state/landings/repo/myslug.json"

# Extract the shipped block and run it with exactly the inputs it declares.
r2_block="$(sed -n '/BEGIN inhblocks-r2-landing-range/,/END inhblocks-r2-landing-range/p' "$HERE/../scripts/extend-gate.sh")"
expect "R2: landing-range block is present in extend-gate.sh" \
  "[ -n \"\$r2_block\" ]"

r2_run() { # $1 = pinned_landing (true|false); echoes "<base>|<source>"
  local pinned_landing="$1"
  local STATE_DIR="$TR2/state" repo="$TR2/repo" slug="myslug"
  # base_ref stand-in: exactly what resolve_base() would return here —
  # the newest reachable version tag.
  local attr_diff_base; attr_diff_base="$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null)"
  local attribution_range_source=""
  repo_slug_for_ci() { basename "$1"; }
  eval "$r2_block"
  printf '%s|%s\n' "$attr_diff_base" "$attribution_range_source"
}

r2_pinned="$(r2_run true)"
r2_plain="$(r2_run false)"

expect "R2: pinned landing pins the range to the landing record's merge_sha" \
  "[ \"\${r2_pinned%%|*}\" = \"$M^1\" ]"
expect "R2: pinned landing reports attribution_range=landing-record" \
  "[ \"\${r2_pinned##*|}\" = landing-record ]"
# The whole point: the pinned range must see ONLY this landing's file.
r2_files_pinned="$(git -C "$TR2/repo" diff --name-only "${r2_pinned%%|*}" "$M")"
expect "R2: pinned range covers only the landing's own file" \
  "[ \"\$r2_files_pinned\" = landed_three.txt ]"
# ...whereas the un-pinned fallback drags in the two earlier landings,
# which is exactly the over-wide diff that mis-scores inherited as in-scope.
r2_files_plain="$(git -C "$TR2/repo" diff --name-only "${r2_plain%%|*}" "$M" | sort | tr '\n' ' ')"
expect "R2: un-pinned fallback is the over-wide tag range (regression guard)" \
  "[ \"\$r2_files_plain\" = 'landed_one.txt landed_three.txt landed_two.txt ' ]"
expect "R2: a non-landing run is untouched (no attribution_range token)" \
  "[ -z \"\${r2_plain##*|}\" ]"
# Fail-safe: an unusable record must leave the range exactly as found.
printf '{"merge_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}\n' > "$TR2/state/landings/repo/myslug.json"
r2_bad="$(r2_run true)"
expect "R2: unresolvable merge_sha falls back, never crashes the gate" \
  "[ \"\${r2_bad%%|*}\" = v0.1.0 ] && [ -z \"\${r2_bad##*|}\" ]"

# --- AC10: rollback-plan attributed by GUILTY-COMMIT RANGE -------------
# 2026-09-18 live finding (burst-lane-gate-debt-2b2982e): `rollback-plan`
# is pathless and has no producer-input map, so AC3's fail-closed
# unknown-inputs rule scored it in-scope on every branch — including when
# the non-revert-clean commit it names landed on main before the branch
# even forked (guilty commit 31f733d). Its inputs are commits, not files:
# a guilty sha that is an ancestor of the branch base is INHERITED; one
# inside base..head is IN-SCOPE.
#
# Fixture lineage:  c_pre  ->  c_base (the branch base)  ->  c_head
# so c_pre is an ancestor of the base and c_head is inside base..head.
T10="$(mktemp -d "${TMPDIR:-/tmp}/inhblocks-ac10.XXXXXX")"
(
  cd "$T10" && git init -q repo && cd repo
  git config user.email t@t && git config user.name t
  echo pre > pre.txt   && git add -A && git commit -qm pre
  echo base > base.txt && git add -A && git commit -qm base
  echo head > head.txt && git add -A && git commit -qm head
) >/dev/null 2>&1
C_PRE="$(git -C "$T10/repo" rev-parse HEAD~2)"
C_BASE="$(git -C "$T10/repo" rev-parse HEAD~1)"
C_HEAD="$(git -C "$T10/repo" rev-parse HEAD)"

# $1 = the commits= token value (empty -> no token at all); echoes the scope.
ac10_scope() {
  local token="$1" note="rollback-plan"
  local n="$T10/notes.tsv"
  if [ -n "$token" ]; then
    printf 'rollback-plan\tcommits since v0.1.0 are not all revert-clean commits=%s\n' "$token" > "$n"
  else
    printf 'rollback-plan\tcommits since v0.1.0 are not all revert-clean\n' > "$n"
  fi
  "$GATE_ATTRIBUTION" compute "$T10/repo" "$C_BASE" "$C_HEAD" "$n" 2>/dev/null \
    | python3 -c 'import json,sys; b=json.load(sys.stdin)["blocks"][0]; print(b["scope"], b.get("attribution",""), sep="|")'
}

ac10_pre="$(ac10_scope "$C_PRE")"
expect "AC10: guilty commit that pre-dates the branch base is inherited" \
  "[ \"\${ac10_pre%%|*}\" = inherited ]"
expect "AC10: inherited-by-range block is tagged attribution=commit-range" \
  "[ \"\${ac10_pre##*|}\" = commit-range ]"

ac10_head="$(ac10_scope "$C_HEAD")"
expect "AC10: guilty commit inside base..head is in-scope" \
  "[ \"\${ac10_head%%|*}\" = in-scope ]"

# ANY in-range sha makes the whole finding in-scope — the branch caused
# part of it, so it owns it.
ac10_mixed="$(ac10_scope "$C_PRE,$C_HEAD")"
expect "AC10: a mixed set with one in-range sha is in-scope" \
  "[ \"\${ac10_mixed%%|*}\" = in-scope ]"

# Fail-closed: a sha this repo cannot resolve must never become free debt.
ac10_bogus="$(ac10_scope deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)"
expect "AC10: an unresolvable guilty sha is in-scope (fail-closed)" \
  "[ \"\${ac10_bogus%%|*}\" = in-scope ]"
ac10_empty_tok="$(ac10_scope ,)"
expect "AC10: commits= naming nothing is in-scope (fail-closed)" \
  "[ \"\${ac10_empty_tok%%|*}\" = in-scope ]"

# Regression guard: with NO commits= token the pre-existing AC3 rule still
# owns the note (pathless + unmapped producer -> in-scope, unknown-inputs).
ac10_none="$(ac10_scope "")"
expect "AC10: no commits= token keeps the AC3 unknown-inputs path intact" \
  "[ \"\$ac10_none\" = 'in-scope|unknown-inputs' ]"

# Summary counter/token.
printf 'rollback-plan\tnot revert-clean commits=%s\n' "$C_PRE" > "$T10/notes.tsv"
ac10_json="$("$GATE_ATTRIBUTION" compute "$T10/repo" "$C_BASE" "$C_HEAD" "$T10/notes.tsv" 2>"$T10/stderr")"
expect "AC10: commit_range counter is 1" \
  "echo \"\$ac10_json\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[\"commit_range\"]==1 else 1)'"
expect "AC10: stderr summary carries attribution=commit-range" \
  "grep -q 'attribution=commit-range' \"$T10/stderr\""
expect "AC10: the inherited/in-scope pair reflects the range verdict" \
  "grep -q 'inherited=1 in-scope=0' \"$T10/stderr\""

# --- AC10 (producer half): the SHIPPED extend-gate.sh block that puts the
# guilty shas into the note. Extracted by marker, same convention as R2.
ac10_block="$(sed -n '/BEGIN inhblocks-r10-rollback-commits/,/END inhblocks-r10-rollback-commits/p' "$HERE/../scripts/extend-gate.sh")"
expect "AC10: rollback-commits block is present in extend-gate.sh" \
  "[ -n \"\$ac10_block\" ]"

ac10_csv() { # $1 = receipt path (may not exist); echoes _rb_guilty_csv
  local rollback_receipt="$1" _rb_guilty_csv=""
  eval "$ac10_block"
  printf '%s\n' "$_rb_guilty_csv"
}

cat > "$T10/rb-mixed.json" <<EOF
{"schema":"autobuilder.rollback_plan_receipt.v2","commits":[
  {"sha":"$C_PRE","revertable":false},
  {"sha":"$C_BASE","revertable":true},
  {"sha":"$C_HEAD","revertable":false}]}
EOF
expect "AC10: only NON-revertable commits are named as guilty" \
  "[ \"\$(ac10_csv "$T10/rb-mixed.json")\" = \"$C_PRE,$C_HEAD\" ]"

cat > "$T10/rb-clean.json" <<EOF
{"schema":"autobuilder.rollback_plan_receipt.v2","commits":[
  {"sha":"$C_PRE","revertable":true}]}
EOF
expect "AC10: an all-revertable receipt names no guilty commit" \
  "[ -z \"\$(ac10_csv "$T10/rb-clean.json")\" ]"

printf 'not json at all\n' > "$T10/rb-broken.json"
expect "AC10: an unparseable receipt emits no token, never crashes" \
  "[ -z \"\$(ac10_csv "$T10/rb-broken.json")\" ]"
expect "AC10: a missing receipt emits no token" \
  "[ -z \"\$(ac10_csv "$T10/does-not-exist.json")\" ]"

# End-to-end: receipt -> note -> attribution. A crate whose only block is a
# pre-branch non-revert-clean commit must come out inherited=1 in-scope=0,
# which is exactly what lets gate-delta.sh call it delta-pass (AC1).
ac10_e2e_csv="$(ac10_csv "$T10/rb-mixed.json")"
printf 'rollback-plan\tnot all revert-clean commits=%s\n' "${ac10_e2e_csv%%,*}" > "$T10/notes.tsv"
"$GATE_ATTRIBUTION" compute "$T10/repo" "$C_BASE" "$C_HEAD" "$T10/notes.tsv" >"$T10/e2e.json" 2>&1
expect "AC10: receipt -> note -> attribution yields inherited=1 in-scope=0" \
  "grep -q 'inherited=1 in-scope=0' \"$T10/e2e.json\""

# --- AC11: the committed baseline is the operator's WITNESS ------------
# Second half of Joe's 2026-09-18T12:15Z operator note. AC3 made an
# unmapped pathless receipt fail closed to in-scope, which is right when
# there is NO evidence — but agent/gate-baseline.json IS evidence: the
# operator hand-recorded that this receipt was already blocking at the
# recorded head, before this branch existed. So an unknown-inputs receipt
# named in the COMMITTED baseline is inherited, never in-scope.
#
# The rescue must stay narrow: unknown-inputs path only. A finding with a
# path token that the diff touched, or one attributed in-scope by commit
# range (AC10), must stay in-scope even when its receipt is baselined --
# otherwise one stale baseline entry would launder every future real
# defect from that producer into free inherited debt.
T11="$(mktemp -d "${TMPDIR:-/tmp}/inhblocks-ac11.XXXXXX")"
(
  cd "$T11" && git init -q repo && cd repo
  git config user.email t@t && git config user.name t
  echo pre > pre.txt && git add -A && git commit -qm pre
  echo touched > touched.txt && git add -A && git commit -qm touched
) >/dev/null 2>&1
AC11_PRE="$(git -C "$T11/repo" rev-parse HEAD~1)"
AC11_HEAD="$(git -C "$T11/repo" rev-parse HEAD)"

cat > "$T11/baseline.json" <<'EOF'
{"schema":"autobuilder.gate_baseline.v1","recorded_at":"2026-09-12T00:00:00Z",
 "receipts":[{"name":"rollback-plan"},{"name":"reviewer-agent"}]}
EOF

# $1 = notes line body for receipt $2; $3 = extra args. echoes "scope|attribution"
ac11_run() { # $1 = receipt  $2 = note body  $3... = extra args
  local receipt="$1" body="$2"; shift 2
  printf '%s\t%s\n' "$receipt" "$body" > "$T11/notes.tsv"
  "$GATE_ATTRIBUTION" compute "$T11/repo" "$AC11_PRE" "$AC11_HEAD" "$T11/notes.tsv" "$@" 2>"$T11/stderr" \
    | python3 -c 'import json,sys; b=json.load(sys.stdin)["blocks"][0]; print(b["scope"], b.get("attribution",""), sep="|")'
}

ac11_hit="$(ac11_run rollback-plan 'not all revert-clean' --baseline "$T11/baseline.json")"
expect "AC11: a baselined unknown-inputs receipt is inherited, not in-scope" \
  "[ \"\${ac11_hit%%|*}\" = inherited ]"
expect "AC11: the rescued block is tagged attribution=baseline-witness" \
  "[ \"\${ac11_hit##*|}\" = baseline-witness ]"
expect "AC11: stderr summary carries attribution=baseline-witness" \
  "grep -q 'attribution=baseline-witness' \"$T11/stderr\""
expect "AC11: a rescued block is NOT counted as unknown-inputs" \
  "! grep -q 'attribution=unknown-inputs' \"$T11/stderr\""
expect "AC11: the rescued block reads inherited=1 in-scope=0" \
  "grep -q 'inherited=1 in-scope=0' \"$T11/stderr\""

# A receipt NOT in the baseline keeps AC3's fail-closed behaviour exactly.
ac11_miss="$(ac11_run mystery-receipt 'no path token' --baseline "$T11/baseline.json")"
expect "AC11: an unbaselined receipt still fails closed to in-scope" \
  "[ \"\$ac11_miss\" = 'in-scope|unknown-inputs' ]"

# Narrowness 1: a path token the diff TOUCHED stays in-scope even though
# the receipt is baselined -- a real defect must never be laundered.
ac11_path="$(ac11_run rollback-plan 'broke path=touched.txt' --baseline "$T11/baseline.json")"
expect "AC11: a baselined receipt with a TOUCHED path stays in-scope" \
  "[ \"\${ac11_path%%|*}\" = in-scope ]"

# Narrowness 2: commit-range attribution (AC10) still decides on its own.
ac11_range="$(ac11_run rollback-plan "not revert-clean commits=$AC11_HEAD" --baseline "$T11/baseline.json")"
expect "AC11: a baselined receipt with an in-range guilty sha stays in-scope" \
  "[ \"\$ac11_range\" = 'in-scope|commit-range' ]"

# Fail-safe: a malformed / empty / absent baseline is simply no witness.
printf 'not json\n' > "$T11/broken.json"
expect "AC11: an unparseable baseline falls back to fail-closed" \
  "[ \"\$(ac11_run rollback-plan 'not all revert-clean' --baseline \"$T11/broken.json\")\" = 'in-scope|unknown-inputs' ]"
printf '{"schema":"autobuilder.gate_baseline.v1","receipts":[]}\n' > "$T11/empty.json"
expect "AC11: an EMPTY baseline (the 2026-09-12 mcphost state) rescues nothing" \
  "[ \"\$(ac11_run rollback-plan 'not all revert-clean' --baseline \"$T11/empty.json\")\" = 'in-scope|unknown-inputs' ]"
expect "AC11: an absent baseline file falls back to fail-closed" \
  "[ \"\$(ac11_run rollback-plan 'not all revert-clean' --baseline \"$T11/nope.json\")\" = 'in-scope|unknown-inputs' ]"

# Default (no --baseline) reads the COMMITTED copy, not the working tree:
# an uncommitted baseline is not a witness.
mkdir -p "$T11/repo/agent"
cp "$T11/baseline.json" "$T11/repo/agent/gate-baseline.json"
expect "AC11: an UNCOMMITTED working-tree baseline is not a witness" \
  "[ \"\$(ac11_run rollback-plan 'not all revert-clean')\" = 'in-scope|unknown-inputs' ]"
git -C "$T11/repo" add -A >/dev/null 2>&1
git -C "$T11/repo" -c user.name=t -c user.email=t@t commit -qm baseline >/dev/null 2>&1
AC11_HEAD2="$(git -C "$T11/repo" rev-parse HEAD)"
printf 'rollback-plan\tnot all revert-clean\n' > "$T11/notes.tsv"
ac11_committed="$("$GATE_ATTRIBUTION" compute "$T11/repo" "$AC11_PRE" "$AC11_HEAD2" "$T11/notes.tsv" 2>/dev/null \
  | python3 -c 'import json,sys; b=json.load(sys.stdin)["blocks"][0]; print(b["scope"], b.get("attribution",""), sep="|")')"
expect "AC11: once COMMITTED, the baseline rescues by default (no flag)" \
  "[ \"\$ac11_committed\" = 'inherited|baseline-witness' ]"

# Journal token: the SHIPPED extend-gate.sh must surface the witness.
expect "AC11: extend-gate.sh journals attribution=baseline-witness" \
  "grep -q 'journal_suffix attribution=baseline-witness' \"$HERE/../scripts/extend-gate.sh\""
expect "AC11: extend-gate.sh reads the baseline_witness counter" \
  "grep -q 'attribution_baseline_witness=' \"$HERE/../scripts/extend-gate.sh\""

exit $fail
