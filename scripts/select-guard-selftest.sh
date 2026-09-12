#!/usr/bin/env bash
# select-guard-selftest.sh — exercises select-guard.sh's dispatch-boundary
# check against scratch repos under /tmp/. Never touches the real
# ~/Documents/PRDs clone.
#
# Reproduces this PRD's own triggering scenario (PRD-autobuilder-gate-debt,
# 2026-09-08): a live foreign-lane claim on the candidate's build_into repo,
# one candidate PRD up for selection — the guard must block it (AC1), and
# once that same claim goes stale (>=3h old) the guard must admit the
# candidate again (AC2).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG="$HERE/select-guard.sh"
LC="$HERE/lane-claim.sh"
ROOT=$(mktemp -d /tmp/select-guard-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
# Never read the real ~/brain/journal/build for the journal-activity
# liveness probe (PRD-build-lane-claim-integrity) — a real journal
# frequently mentions common slug substrings like "holder" (e.g.
# `holder_prd=...` in lock-contended lines) by sheer coincidence, which
# would false-positive this selftest's stale-claim fixtures below.
export JOURNAL_DIR="$ROOT/journal"
mkdir -p "$JOURNAL_DIR"

git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/clone"
mkdir -p "$ROOT/clone/build-queue"

cat > "$ROOT/clone/build-queue/PRD-victim.md" <<'EOF'
# PRD: victim — the candidate this tick wants to dispatch into

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-target-repo
EOF

cat > "$ROOT/clone/build-queue/PRD-holder.md" <<'EOF'
# PRD: holder — shares victim's build_into, claimed by a foreign lane

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-target-repo
EOF

git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m init
BRANCH=$(git -C "$ROOT/clone" symbolic-ref --short HEAD)
git -C "$ROOT/clone" push -q origin "$BRANCH"

VICTIM="$ROOT/clone/build-queue/PRD-victim.md"
HOLDER="$ROOT/clone/build-queue/PRD-holder.md"

echo "== no claim on the target repo: guard admits the candidate =="
out=$("$SG" victim carbon "$ROOT/clone")
echo "$out" | grep -q '^ok: victim:' || { echo "FAIL: $out"; exit 1; }
echo ok

echo "== AC1: a live foreign-lane claim on build_into blocks dispatch, loudly =="
"$LC" claim "$HOLDER" redbaron >/dev/null
set +e
out=$("$SG" victim carbon "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL expected exit 1, got $rc: $out"; exit 1; }
echo "$out" | grep -q '^blocked: victim:' || { echo "FAIL msg prefix: $out"; exit 1; }
echo "$out" | grep -q 'busy:' || { echo "FAIL: message does not name the busy claim: $out"; exit 1; }
echo "$out" | grep -q 'holder' || { echo "FAIL: message does not name the holding slug: $out"; exit 1; }
echo ok

echo "== AC4: usage error surfaces via lane-predicate's own path (composition, not reimplementation) =="
set +e
out=$("$SG" no-such-slug carbon "$ROOT/clone" 2>&1); rc=$?
set -e
[ "$rc" -eq 4 ] || { echo "FAIL expected exit 4 for missing PRD, got $rc: $out"; exit 1; }
echo ok

echo "== AC2: once the same claim goes stale (>=3h), the guard admits the candidate again =="
python3 - "$HOLDER" <<'PYEOF'
import re, sys
f = sys.argv[1]
with open(f) as fh:
    text = fh.read()
text = re.sub(r'^- Lane:.*$', '- Lane: redbaron 2020-01-01T00:00:00Z', text, flags=re.M)
with open(f, 'w') as fh:
    fh.write(text)
PYEOF
git -C "$ROOT/clone" add -A
# Backdate the commit itself to match the backdated Lane: value
# (PRD-build-lane-claim-integrity's evidence bar checks for a commit AFTER
# the claim — an un-backdated "now" commit that merely carries a
# stale-looking Lane: value would otherwise itself read as post-claim
# activity, i.e. long-running rather than genuinely stale).
GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z \
  git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m stale-the-claim
git -C "$ROOT/clone" push -q origin "$BRANCH"

out=$("$SG" victim carbon "$ROOT/clone")
echo "$out" | grep -q '^ok: victim:' || { echo "FAIL expected ok on stale claim, got: $out"; exit 1; }
echo ok

# --- BUILD_MAX_BRANCHES (PRD-build-max-branches-cap, 2026-09-11) -----------
# Per-tick fan-out cap. Extends this file (rather than a standalone
# max-branches-selftest.sh) because select-guard.sh's dispatch-boundary
# call is the enforcement point, and this file already owns that script's
# scratch fixtures. Three PRDs staged (>= 3 eligible, no busy claims) so
# the cap alone decides admission; branch-count is passed positionally
# (4th arg), same convention as chain-guard.sh's --step-count.

cat > "$ROOT/clone/build-queue/PRD-second.md" <<'EOF'
# PRD: second — an independent candidate (own build_into, never busy)

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-second-repo
EOF
cat > "$ROOT/clone/build-queue/PRD-third.md" <<'EOF'
# PRD: third — an independent candidate (own build_into, never busy)

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-third-repo
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "stage second+third for max-branches"
git -C "$ROOT/clone" push -q origin "$BRANCH"

echo "== BUILD_MAX_BRANCHES=2, >=3 eligible: selection admits exactly 2, blocks the 3rd on cap =="
admitted=0
for i in 0 1 2; do
  slug=$(printf '%s\n' victim second third | sed -n "$((i+1))p")
  set +e
  out=$(BUILD_MAX_BRANCHES=2 "$SG" "$slug" carbon "$ROOT/clone" "$admitted" 2>&1); rc=$?
  set -e
  if [ "$i" -lt 2 ]; then
    [ "$rc" -eq 0 ] || { echo "FAIL: expected admit #$((i+1)) ($slug), got rc=$rc: $out"; exit 1; }
    echo "$out" | grep -q "^ok: $slug:" || { echo "FAIL: $out"; exit 1; }
    admitted=$((admitted+1))
  else
    [ "$rc" -eq 1 ] || { echo "FAIL: expected the 3rd ($slug) blocked, got rc=$rc: $out"; exit 1; }
    echo "$out" | grep -q "^blocked: $slug: cap: 2 branches already selected this tick (cap=2)$" \
      || { echo "FAIL cap message: $out"; exit 1; }
  fi
done
[ "$admitted" -eq 2 ] || { echo "FAIL: expected exactly 2 admitted, got $admitted"; exit 1; }
echo ok

echo "== BUILD_MAX_BRANCHES unset: same pool admits all 3 (min(eligible,30)) =="
admitted=0
for slug in victim second third; do
  out=$("$SG" "$slug" carbon "$ROOT/clone" "$admitted")
  echo "$out" | grep -q "^ok: $slug:" || { echo "FAIL: $out"; exit 1; }
  admitted=$((admitted+1))
done
[ "$admitted" -eq 3 ] || { echo "FAIL: expected all 3 admitted with cap unset, got $admitted"; exit 1; }
echo ok

echo "== BUILD_MAX_BRANCHES=0 (invalid, non-positive): falls back to default 30, does not block =="
out=$(BUILD_MAX_BRANCHES=0 "$SG" victim carbon "$ROOT/clone" 0)
echo "$out" | grep -q '^ok: victim:' || { echo "FAIL: BUILD_MAX_BRANCHES=0 should fall back to 30, got: $out"; exit 1; }
echo ok

echo "== BUILD_MAX_BRANCHES=bogus (invalid, non-integer): falls back to default 30, does not block =="
out=$(BUILD_MAX_BRANCHES=bogus "$SG" victim carbon "$ROOT/clone" 0)
echo "$out" | grep -q '^ok: victim:' || { echo "FAIL: BUILD_MAX_BRANCHES=bogus should fall back to 30, got: $out"; exit 1; }
echo ok

# --- BUILD_DISTINCT_TARGETS (PRD-build-distinct-targets-per-tick, 2026-09-11) -----
# Never co-schedule PRDs sharing a build_into in one tick (journal-confirmed
# mcphost-schedules + mcphost-tests-host-independence collision — same
# build_into, integrate-lock contention + cargo-budget starvation, nothing
# shipped). Three PRDs staged: alpha+beta share repo A's build_into, gamma
# is repo B (independent). admitted-targets is passed positionally (5th
# arg), same caller-maintained-running-state convention as branch-count
# (4th arg).
command -v git >/dev/null 2>&1 || { echo "FAIL: git not on PATH"; exit 1; }

cat > "$ROOT/clone/build-queue/PRD-alpha.md" <<'EOF'
# PRD: alpha — repo A, first of two sharing a build_into

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-distinct-repo-a
EOF
cat > "$ROOT/clone/build-queue/PRD-beta.md" <<'EOF'
# PRD: beta — repo A, second of two sharing a build_into

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-distinct-repo-a
EOF
cat > "$ROOT/clone/build-queue/PRD-gamma.md" <<'EOF'
# PRD: gamma — repo B, independent build_into

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-distinct-repo-b
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "stage alpha+beta+gamma for distinct-targets"
git -C "$ROOT/clone" push -q origin "$BRANCH"

echo "== BUILD_DISTINCT_TARGETS=1 (default), cap 2: alpha+gamma admitted, beta blocked same-target =="
branch_count=0
admitted_targets=""
for slug in alpha beta gamma; do
  set +e
  out=$(BUILD_DISTINCT_TARGETS=1 BUILD_MAX_BRANCHES=2 "$SG" "$slug" carbon "$ROOT/clone" "$branch_count" "$admitted_targets" 2>&1); rc=$?
  set -e
  case "$slug" in
    alpha)
      [ "$rc" -eq 0 ] || { echo "FAIL: expected alpha admitted, got rc=$rc: $out"; exit 1; }
      echo "$out" | grep -q '^ok: alpha:' || { echo "FAIL: $out"; exit 1; }
      branch_count=$((branch_count+1))
      admitted_targets="/tmp/select-guard-distinct-repo-a"
      ;;
    beta)
      [ "$rc" -eq 1 ] || { echo "FAIL: expected beta blocked, got rc=$rc: $out"; exit 1; }
      [ "$out" = "blocked: beta: same-target: /tmp/select-guard-distinct-repo-a already selected this tick (BUILD_DISTINCT_TARGETS=1)" ] \
        || { echo "FAIL: same-target message mismatch: $out"; exit 1; }
      ;;
    gamma)
      [ "$rc" -eq 0 ] || { echo "FAIL: expected gamma admitted, got rc=$rc: $out"; exit 1; }
      echo "$out" | grep -q '^ok: gamma:' || { echo "FAIL: $out"; exit 1; }
      branch_count=$((branch_count+1))
      admitted_targets="$admitted_targets,/tmp/select-guard-distinct-repo-b"
      ;;
  esac
done
[ "$branch_count" -eq 2 ] || { echo "FAIL: expected exactly 2 admitted (alpha+gamma), got $branch_count"; exit 1; }
echo ok

echo "== BUILD_DISTINCT_TARGETS=0: both repo-A PRDs admitted (cap permitting) =="
branch_count=0
admitted_targets=""
for slug in alpha beta; do
  out=$(BUILD_DISTINCT_TARGETS=0 BUILD_MAX_BRANCHES=3 "$SG" "$slug" carbon "$ROOT/clone" "$branch_count" "$admitted_targets")
  echo "$out" | grep -q "^ok: $slug:" || { echo "FAIL: $out"; exit 1; }
  branch_count=$((branch_count+1))
  admitted_targets="$admitted_targets,/tmp/select-guard-distinct-repo-a"
done
[ "$branch_count" -eq 2 ] || { echo "FAIL: expected both repo-A PRDs admitted with BUILD_DISTINCT_TARGETS=0, got $branch_count"; exit 1; }
echo ok

echo "== BUILD_MAX_BRANCHES=1: the distinct-target rule never fires (cap blocks beta first) =="
out=$(BUILD_MAX_BRANCHES=1 "$SG" alpha carbon "$ROOT/clone" 0 "")
echo "$out" | grep -q '^ok: alpha:' || { echo "FAIL: expected alpha admitted, got: $out"; exit 1; }
set +e
out=$(BUILD_MAX_BRANCHES=1 "$SG" beta carbon "$ROOT/clone" 1 "/tmp/select-guard-distinct-repo-a" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL: expected beta blocked, got rc=$rc: $out"; exit 1; }
echo "$out" | grep -q '^blocked: beta: cap:' || { echo "FAIL: expected cap block (not same-target) with cap=1, got: $out"; exit 1; }
echo "$out" | grep -q 'same-target' && { echo "FAIL: same-target rule fired despite cap=1 already blocking: $out"; exit 1; }
echo ok

echo "ALL PASS"
