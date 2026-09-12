#!/usr/bin/env bash
# classification-self-heal-selftest.sh — acceptance harness for
# classification-self-heal.sh (PRD-build-classification-self-heal).
# Throwaway git fixtures (bare origin + clone) and a scratch manifest/state
# dir under a tempdir. No network, never touches a real PRDs checkout or
# the real ~/.claude/skills/build/state/manifest.json.
#
#   AC4 (resolve, unambiguous)  — exactly-one-consistent-target rewrites
#                                 build_target, sets Status: queued, appends
#                                 an iter_log entry naming the probes, and
#                                 commits+pushes.
#   AC5 (resolve, mixed)        — a mixed-substrate repo declines and does
#                                 NOT edit frontmatter.
#   AC6 (resolve, missing path) — a build_into that does not exist declines,
#                                 no auto-resolution attempt.
#   AC1/AC2 real-fixture pairing — reuses the actual 09-12 defect shape
#                                 (python-cli against a Cargo workspace).
#   AC3/AC7 (bounce-check)      — an unchanged diagnosis is skipped and
#                                 journaled once; the second unchanged
#                                 bounce raises one alarm.
#   AC8 (probe)                — passthrough to substrate-probe.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CSH="$HERE/classification-self-heal.sh"
[ -x "$CSH" ] || { echo "selftest: $CSH not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/csh-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label" >&2; FAIL=$((FAIL+1)); fi
}
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

new_prd_fixture() {
  local d="$1"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/prds" 2>/dev/null
  mkdir -p "$d/prds/build-queue"
  printf '# MANIFEST\n' > "$d/prds/MANIFEST.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm init
  local defbr; defbr="$(git -C "$d/prds" symbolic-ref --short HEAD)"
  git -C "$d/prds" push -q origin "$defbr"
  printf '%s' "$defbr"
}

add_needs_classification_prd() {
  # $1=fixture-dir $2=slug $3=defbr $4=build_target $5=build_into
  local d="$1" slug="$2" defbr="$3" target="$4" into="$5"
  {
    printf '# PRD: %s\n\n- Status: needs_classification\n' "$slug"
    printf -- '- build_target: %s\n- build_into: %s\n' "$target" "$into"
    printf -- '- Vision: visions/none.md\n'
  } > "$d/prds/build-queue/PRD-$slug.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add $slug"
  git -C "$d/prds" push -q origin "$defbr"
}

new_scratch_state() {
  # $1=dir; sets up an isolated manifest.json + state dir so bounce-check
  # writes never touch the real skill state.
  mkdir -p "$1/state"
  printf '{"prds":{},"built_at":"2020-01-01T00:00:00Z"}\n' > "$1/state/manifest.json"
}

run_csh() { # $1=state-dir; rest = args
  local sd="$1"; shift
  BUILD_STATE_DIR="$sd/state" BUILD_MANIFEST="$sd/state/manifest.json" \
    JOURNAL="$sd/journal.md" "$CSH" "$@"
}

manifest_field() { # $1=state-dir $2=slug $3=key
  python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
e=m.get("prds",{}).get(sys.argv[2],{})
v=e.get(sys.argv[3])
print("" if v is None else v)
' "$1/state/manifest.json" "$2" "$3"
}

# ======================================================================
# AC8 — probe passthrough
# ======================================================================
mkdir -p "$T/cargo-ws"
printf '[workspace]\nmembers = ["crates/foo"]\n' > "$T/cargo-ws/Cargo.toml"
"$CSH" probe "$T/cargo-ws" --format json > "$T/ac8-probe.json"
expect "AC8: probe passthrough reports substrate=cargo" \
  "python3 -c \"import json; d=json.load(open('$T/ac8-probe.json')); import sys; sys.exit(0 if d['substrate']=='cargo' else 1)\""

# ======================================================================
# AC1/AC4 — the real 09-12 defect shape: python-cli against a Cargo
# workspace, exactly one consistent target (rust-extend) -> auto-resolved.
# ======================================================================
D1="$T/ac4"; mkdir -p "$D1"
DEFBR1="$(new_prd_fixture "$D1")"
mkdir -p "$D1/cargo-ws"
printf '[workspace]\nmembers = ["crates/foo"]\n' > "$D1/cargo-ws/Cargo.toml"
add_needs_classification_prd "$D1" "defect1" "$DEFBR1" "python-cli" "$D1/cargo-ws"
S1="$D1/state"; new_scratch_state "$D1"

out4="$(run_csh "$D1" resolve "$D1/prds/build-queue/PRD-defect1.md" 2>&1)"; rc4=$?
expect "AC4: resolve exits 0"                                  "[ $rc4 -eq 0 ]"
expect "AC4: prints the resolved line"                         "grep -q '^resolved: defect1 python-cli -> rust-extend' <<<\"\$out4\""
expect "AC4: build_target rewritten to rust-extend"            "grep -qxe '- build_target: rust-extend' '$D1/prds/build-queue/PRD-defect1.md'"
expect "AC4: Status back to queued"                            "grep -qxe '- Status: queued' '$D1/prds/build-queue/PRD-defect1.md'"
expect "AC4: iter_log names the probes and decision"           "grep -q 'iter_log:.*auto-resolved: build_target python-cli -> rust-extend' '$D1/prds/build-queue/PRD-defect1.md' && grep -q 'Cargo.toml=True' '$D1/prds/build-queue/PRD-defect1.md'"
expect "AC4: commit identity is Joe Yen"                       "[ \"\$(git -C '$D1/prds' log -1 --format='%an <%ae>')\" = 'Joe Yen <jyen.tech@gmail.com>' ]"
expect "AC4: pushed (local matches origin)"                    "[ -z \"\$(git -C '$D1/prds' diff \"origin/$DEFBR1\" HEAD -- build-queue/PRD-defect1.md)\" ]"
expect "AC4: manifest cache updated to queued/rust-extend"     "[ \"\$(manifest_field "$D1" defect1 status)\" = queued ] && [ \"\$(manifest_field "$D1" defect1 build_target)\" = rust-extend ]"

# ======================================================================
# AC5 — mixed substrate declines, no frontmatter edit
# ======================================================================
D5="$T/ac5"; mkdir -p "$D5"
DEFBR5="$(new_prd_fixture "$D5")"
mkdir -p "$D5/mixed-ws"
printf '[workspace]\n' > "$D5/mixed-ws/Cargo.toml"
printf '[project]\nname = "x"\n' > "$D5/mixed-ws/pyproject.toml"
add_needs_classification_prd "$D5" "mixed1" "$DEFBR5" "python-cli" "$D5/mixed-ws"
before5="$(cat "$D5/prds/build-queue/PRD-mixed1.md")"
out5="$(run_csh "$D5" resolve "$D5/prds/build-queue/PRD-mixed1.md" 2>&1)"; rc5=$?
after5="$(cat "$D5/prds/build-queue/PRD-mixed1.md")"
expect "AC5: resolve exits 1 (declined)"                       "[ $rc5 -eq 1 ]"
expect "AC5: message names mixed substrate"                    "grep -q 'mixed substrate' <<<\"\$out5\""
expect "AC5: frontmatter unchanged"                             "[ \"\$before5\" = \"\$after5\" ]"

# ======================================================================
# AC6 — build_into path does not exist: declines, no auto-resolution
# ======================================================================
D6="$T/ac6"; mkdir -p "$D6"
DEFBR6="$(new_prd_fixture "$D6")"
add_needs_classification_prd "$D6" "gone1" "$DEFBR6" "rust-extend" "/no/such/path/anywhere-$$"
before6="$(cat "$D6/prds/build-queue/PRD-gone1.md")"
out6="$(run_csh "$D6" resolve "$D6/prds/build-queue/PRD-gone1.md" 2>&1)"; rc6=$?
after6="$(cat "$D6/prds/build-queue/PRD-gone1.md")"
expect "AC6: resolve exits 1 (declined)"                       "[ $rc6 -eq 1 ]"
expect "AC6: message says no auto-resolution attempt"          "grep -q 'no auto-resolution attempt' <<<\"\$out6\""
expect "AC6: frontmatter unchanged"                             "[ \"\$before6\" = \"\$after6\" ]"

# ======================================================================
# AC3/AC7 — bounce-check: unchanged diagnosis skipped+journaled once;
# second unchanged bounce raises one alarm.
# ======================================================================
D7="$T/ac7"; mkdir -p "$D7/prds/build-queue"
cat > "$D7/prds/build-queue/PRD-bouncer.md" <<'EOF'
# PRD: bouncer

- Status: queued
- build_target: python-cli
- build_into: /tmp/some-cargo-ws-bouncer
EOF
new_scratch_state "$D7"

b1="$(run_csh "$D7" bounce-check "$D7/prds/build-queue/PRD-bouncer.md" build-into-substrate-mismatch 'msg one' 2>&1)"
expect "AC7: first bounce is 'fresh', bounces=1"                "grep -q 'bounce: bouncer fresh (bounces=1)' <<<\"\$b1\""
expect "AC7: journal has one bounce line after tick 1"          "[ \"\$(grep -c '  bounce  ' "$D7/journal.md")\" -eq 1 ]"

b2="$(run_csh "$D7" bounce-check "$D7/prds/build-queue/PRD-bouncer.md" build-into-substrate-mismatch 'msg one' 2>&1)"
expect "AC3: second identical-diagnosis tick is skipped"        "grep -q 'skip: bouncer unchanged since last bounce (bounces=2)' <<<\"\$b2\""
expect "AC3: exactly one skip line journaled for tick 2"        "[ \"\$(grep -c '  skip  ' "$D7/journal.md")\" -eq 1 ]"
expect "AC7: one alarm raised on the second unchanged bounce"   "[ \"\$(grep -c '  alarm  ' "$D7/journal.md")\" -eq 1 ]"

b3="$(run_csh "$D7" bounce-check "$D7/prds/build-queue/PRD-bouncer.md" build-into-substrate-mismatch 'msg one' 2>&1)"
expect "AC7: a third identical tick is skipped again, no 2nd alarm" \
  "grep -q 'skip: bouncer unchanged' <<<\"\$b3\" && [ \"\$(grep -c '  alarm  ' "$D7/journal.md")\" -eq 1 ]"

b4="$(run_csh "$D7" bounce-check "$D7/prds/build-queue/PRD-bouncer.md" build-into-substrate-mismatch 'a DIFFERENT diagnosis now' 2>&1)"
expect "AC7: a changed diagnosis resets to a fresh bounce"      "grep -q 'bounce: bouncer diagnosis changed (bounces=1)' <<<\"\$b4\""

# --------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
  echo "SELFTEST FAILED ($FAIL fail / $((PASS+FAIL)) total)"
  exit 1
fi
echo "SELFTEST PASSED ($PASS checks)"
