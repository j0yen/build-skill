#!/usr/bin/env bash
# requeue-prd-selftest.sh — acceptance harness for requeue-prd.sh
# (PRD-build-classification-durable-heal requirement 2 / AC3). Same
# throwaway-git-fixture shape as mark-needs-classification-selftest.sh.
# No network, never touches a real PRDs checkout.
#
# One `expect` label per acceptance criterion:
#   AC3 — a parked (needs_classification) fixture PRD: `requeue-prd.sh
#         <slug> "test"` sets Status: queued, the FIRST iter_log line
#         starts with `requeued: test`, and exactly one new commit lands;
#         running it again is a no-op (no new commit).
#
# Plus smoke checks: --dry-run mutates nothing, an already-queued PRD is
# a same-call no-op, an unexpected Status refuses, and bad usage exits 2.
#
# Run: bash scripts/requeue-prd-selftest.sh   (exit 0 = pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RQ="$HERE/requeue-prd.sh"
[ -x "$RQ" ] || { echo "selftest: $RQ not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/rq-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label" >&2; FAIL=$((FAIL+1)); fi
}
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# Bare origin + one clone, build-queue/ pushed. $1 = fixture dir (created
# fresh). Echoes the default branch name.
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

# Add a parked (needs_classification) PRD $2 (slug) to fixture $1, with an
# existing iter_log line already present, and push.
add_parked_prd() {
  local d="$1" slug="$2" defbr="$3"
  {
    printf '# PRD: %s\n\n- Status: needs_classification\n' "$slug"
    printf -- '- build_target: shell\n- build_into: /tmp/nowhere-%s\n' "$slug"
    printf -- '- iter_log: 2026-09-14T00:00:00Z needs_classification: old diagnosis\n'
  } > "$d/prds/build-queue/PRD-$slug.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add $slug"
  git -C "$d/prds" push -q origin "$defbr"
}

# Add an already-queued PRD $2 to fixture $1, and push.
add_queued_prd() {
  local d="$1" slug="$2" defbr="$3"
  {
    printf '# PRD: %s\n\n- Status: queued\n' "$slug"
    printf -- '- build_target: shell\n- build_into: /tmp/nowhere-%s\n' "$slug"
  } > "$d/prds/build-queue/PRD-$slug.md"
  gc "$d/prds" add -A
  gc "$d/prds" commit -qm "add $slug"
  git -C "$d/prds" push -q origin "$defbr"
}

# ======================================================================
# AC3 — parked fixture PRD -> queued, prepended iter_log, one commit;
# a second call is a no-op.
# ======================================================================
D1="$T/ac3"; mkdir -p "$D1"
DEFBR1="$(new_prd_fixture "$D1")"
add_parked_prd "$D1" "parked1" "$DEFBR1"
out1="$(PRD_DIR="$D1/prds" "$RQ" "$D1/prds/build-queue/PRD-parked1.md" "test" 2>&1)"; rc1=$?
expect "AC3: exits 0"                                        "[ $rc1 -eq 0 ]"
expect "AC3: prints the committed line"                      "grep -q '^requeued-committed: parked1 ' <<<\"\$out1\""
expect "AC3: Status is queued"                                "grep -qxe '- Status: queued' '$D1/prds/build-queue/PRD-parked1.md'"
expect "AC3: first iter_log line starts with requeued: test"  "grep -m1 'iter_log:' '$D1/prds/build-queue/PRD-parked1.md' | grep -q 'requeued: test'"
expect "AC3: old iter_log line still present (prepended, not replaced)" \
  "grep -q 'needs_classification: old diagnosis' '$D1/prds/build-queue/PRD-parked1.md'"
expect "AC3: commit identity is Joe Yen"                     "[ \"\$(git -C '$D1/prds' log -1 --format='%an <%ae>')\" = 'Joe Yen <jyen.tech@gmail.com>' ]"
expect "AC3: working tree is clean"                          "[ -z \"\$(git -C '$D1/prds' status --porcelain)\" ]"
expect "AC3: exactly one new commit reached origin"          "[ \"\$(git -C '$D1/origin.git' log --oneline | wc -l)\" -eq 3 ]"

# Running it again: no-op, no new commit.
head1_0="$(git -C "$D1/prds" rev-parse HEAD)"
out1b="$(PRD_DIR="$D1/prds" "$RQ" "$D1/prds/build-queue/PRD-parked1.md" "test again" 2>&1)"; rc1b=$?
head1_1="$(git -C "$D1/prds" rev-parse HEAD)"
expect "AC3: second call exits 0"                            "[ $rc1b -eq 0 ]"
expect "AC3: second call prints noop"                        "grep -q '^requeued-noop: parked1 ' <<<\"\$out1b\""
expect "AC3: second call makes no new commit"                "[ '$head1_0' = '$head1_1' ]"

# ======================================================================
# Smoke: an already-queued PRD is a same-call no-op too
# ======================================================================
D2="$T/ac2"; mkdir -p "$D2"
DEFBR2="$(new_prd_fixture "$D2")"
add_queued_prd "$D2" "already" "$DEFBR2"
head2_0="$(git -C "$D2/prds" rev-parse HEAD)"
out2="$(PRD_DIR="$D2/prds" "$RQ" "$D2/prds/build-queue/PRD-already.md" "n/a" 2>&1)"; rc2=$?
head2_1="$(git -C "$D2/prds" rev-parse HEAD)"
expect "already-queued: exits 0"                             "[ $rc2 -eq 0 ]"
expect "already-queued: prints noop"                         "grep -q '^requeued-noop: already ' <<<\"\$out2\""
expect "already-queued: no new commit"                        "[ '$head2_0' = '$head2_1' ]"

# ======================================================================
# Smoke: an unexpected Status refuses rather than guessing
# ======================================================================
D3="$T/ac-unexpected"; mkdir -p "$D3"
DEFBR3="$(new_prd_fixture "$D3")"
{
  printf '# PRD: weird\n\n- Status: blocked\n- build_target: shell\n'
} > "$D3/prds/build-queue/PRD-weird.md"
gc "$D3/prds" add -A; gc "$D3/prds" commit -qm "add weird"
git -C "$D3/prds" push -q origin "$DEFBR3"
out3="$(PRD_DIR="$D3/prds" "$RQ" "$D3/prds/build-queue/PRD-weird.md" "n/a" 2>&1)"; rc3=$?
expect "unexpected-status: exits 4"                          "[ $rc3 -eq 4 ]"
expect "unexpected-status: mentions the unexpected state"    "grep -q 'unexpected-status' <<<\"\$out3\""

# ======================================================================
# Smoke: --dry-run mutates nothing
# ======================================================================
D4="$T/ac-dry"; mkdir -p "$D4"
DEFBR4="$(new_prd_fixture "$D4")"
add_parked_prd "$D4" "dryrun" "$DEFBR4"
head4_0="$(git -C "$D4/prds" rev-parse HEAD)"
out4="$(PRD_DIR="$D4/prds" "$RQ" "$D4/prds/build-queue/PRD-dryrun.md" "would-be reason" --dry-run 2>&1)"; rc4=$?
head4_1="$(git -C "$D4/prds" rev-parse HEAD)"
expect "dry-run: exits 0"                                    "[ $rc4 -eq 0 ]"
expect "dry-run: prints a DRY RUN plan"                      "grep -q 'DRY RUN' <<<\"\$out4\""
expect "dry-run: no commit made"                             "[ '$head4_0' = '$head4_1' ]"
expect "dry-run: PRD file untouched"                         "grep -qxe '- Status: needs_classification' '$D4/prds/build-queue/PRD-dryrun.md'"

# ======================================================================
# Smoke: bad usage exits 2
# ======================================================================
out5="$("$RQ" 2>&1)"; rc5=$?
expect "usage: missing args exits 2"                         "[ $rc5 -eq 2 ]"

# ======================================================================
echo "requeue-prd-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
