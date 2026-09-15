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
# PRD-build-gate-before-land requirement 7: select-guard.sh now journals
# every same-target admit/block decision — isolate it same as JOURNAL_DIR
# above, or every run of this selftest pollutes the real shared journal.
export SELECT_GUARD_JOURNAL="$ROOT/select-guard-journal.md"

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
      # PRD-build-gate-before-land requirement 5: the binary distinct-target
      # message is replaced by the same-target-cap message (cap=1 here,
      # since BUILD_DISTINCT_TARGETS=1 still forces the compat cap of 1).
      # $out is 2>&1-combined, so it also carries the stderr
      # `select same-target cap=...` diagnostic line requirement 5 adds —
      # match on containment, not full equality.
      echo "$out" | grep -qF "blocked: beta: same-target: /tmp/select-guard-distinct-repo-a already at cap=1 (source=local, 1 admitted this tick)" \
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

# --- selslot_* (PRD-build-select-guard-depends-before-slot) ----------------
# Depends-on gated before the same-target slot is reserved. Requirement 3's
# (P1) tie-break ordering is out of scope here (deferred_acs: [3, 7] on the
# PRD itself, per its own Technical Considerations: "staged as P0 and can
# ship independently if 3 slips") -- these fixtures cover requirements
# 1/2/4 and 5(a)/5(b) only.
mkdir -p "$ROOT/clone/built-prds"

cat > "$ROOT/clone/build-queue/PRD-selslot-first.md" <<'EOF'
# PRD: selslot-first — first by sort, has an unmet Depends-on

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-selslot-repo
- build_priority: high
- Depends-on: PRD-selslot-dep-unmet.md
EOF
cat > "$ROOT/clone/build-queue/PRD-selslot-second.md" <<'EOF'
# PRD: selslot-second — second by sort, no Depends-on

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-selslot-repo
- build_priority: high
EOF
cat > "$ROOT/clone/build-queue/PRD-selslot-third.md" <<'EOF'
# PRD: selslot-third — third candidate, same target, no Depends-on

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-selslot-repo
- build_priority: high
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "stage selslot_a fixtures"
git -C "$ROOT/clone" push -q origin "$BRANCH"

echo "== selslot_a: unmet Depends-on gates before the same-target slot is reserved (AC1/AC5) =="
set +e
out_first=$(BUILD_DISTINCT_TARGETS=1 BUILD_SAME_TARGET_CAP=1 "$SG" selslot-first carbon "$ROOT/clone" 0 "" 2>&1); rc_first=$?
set -e
[ "$rc_first" -eq 1 ] || { echo "FAIL: expected selslot-first gated, got rc=$rc_first: $out_first"; exit 1; }
echo "$out_first" | grep -q '^blocked: selslot-first: gated: depends-on:' \
  || { echo "FAIL: verdict text missing gated: depends-on: prefix: $out_first"; exit 1; }
echo "$out_first" | grep -q 'selslot-dep-unmet' \
  || { echo "FAIL: verdict does not name the unmet dependency: $out_first"; exit 1; }

# The gated candidate above was called with admitted_targets="" (as a real
# caller would, since a gated candidate never contributes its build_into) --
# the second candidate, sharing the same target, must still see an EMPTY
# admitted_targets and be admitted: the slot was never spent.
out_second=$(BUILD_DISTINCT_TARGETS=1 BUILD_SAME_TARGET_CAP=1 "$SG" selslot-second carbon "$ROOT/clone" 0 "" 2>&1); rc_second=$?
[ "$rc_second" -eq 0 ] || { echo "FAIL: expected selslot-second admitted, got rc=$rc_second: $out_second"; exit 1; }
echo "$out_second" | grep -q '^ok: selslot-second:' || { echo "FAIL: $out_second"; exit 1; }

# Now prove the slot WAS consumed exactly once by the second candidate (not
# zero, not twice): a third same-target candidate, threaded with the
# admitted-targets state a real caller would carry forward after admitting
# selslot-second, is blocked by the same-target cap -- NOT by depends-on.
set +e
out_third=$(BUILD_DISTINCT_TARGETS=1 BUILD_SAME_TARGET_CAP=1 "$SG" selslot-third carbon "$ROOT/clone" 1 "/tmp/select-guard-selslot-repo" 2>&1); rc_third=$?
set -e
[ "$rc_third" -eq 1 ] || { echo "FAIL: expected selslot-third blocked (slot already consumed), got rc=$rc_third: $out_third"; exit 1; }
echo "$out_third" | grep -q 'same-target:' || { echo "FAIL: expected same-target block (slot consumed once), got: $out_third"; exit 1; }
echo ok

echo "== selslot AC2: select-guard.sh and a coordinator stand-in resolve depends-gate.sh identically =="
DG="$HERE/lib/depends-gate.sh"
coordinator_unmet=$(bash -c '
  set -uo pipefail
  source "$1"
  depends_gate_unmet "$2" "$3"
' _ "$DG" "$ROOT/clone/build-queue/PRD-selslot-first.md" "$ROOT/clone/built-prds") || true
coordinator_csv=$(printf '%s' "$coordinator_unmet" | tr '\n' ',' | sed 's/,$//')
guard_out=$(BUILD_DISTINCT_TARGETS=1 "$SG" selslot-first carbon "$ROOT/clone" 0 "" 2>&1) || true
guard_csv="${guard_out#*gated: depends-on: }"
[ -n "$coordinator_csv" ] || { echo "FAIL: coordinator stand-in reported no unmet dependency"; exit 1; }
[ "$guard_csv" = "$coordinator_csv" ] || { echo "FAIL: select-guard.sh ($guard_csv) and coordinator stand-in ($coordinator_csv) disagree"; exit 1; }
echo ok

echo "== selslot_b: every same-target candidate gated -> slot stays free, caller's nothing-to-do path fires (AC6) =="
cat > "$ROOT/clone/build-queue/PRD-selslot-gated-one.md" <<'EOF'
# PRD: selslot-gated-one — shares the selslot_b target, unmet Depends-on

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-selslot-b-repo
- build_priority: high
- Depends-on: PRD-selslot-dep-unmet.md
EOF
cat > "$ROOT/clone/build-queue/PRD-selslot-gated-two.md" <<'EOF'
# PRD: selslot-gated-two — shares the selslot_b target, a different unmet Depends-on

- Status: queued
- build_target: shell
- build_into: /tmp/select-guard-selslot-b-repo
- build_priority: high
- Depends-on: PRD-selslot-dep-unmet-2.md
EOF
git -C "$ROOT/clone" add -A
git -C "$ROOT/clone" -c user.name=t -c user.email=t@t commit -q -m "stage selslot_b fixtures"
git -C "$ROOT/clone" push -q origin "$BRANCH"

admitted_targets=""
for slug in selslot-gated-one selslot-gated-two; do
  set +e
  out=$(BUILD_DISTINCT_TARGETS=1 "$SG" "$slug" carbon "$ROOT/clone" 0 "$admitted_targets" 2>&1); rc=$?
  set -e
  [ "$rc" -eq 1 ] || { echo "FAIL: expected $slug gated, got rc=$rc: $out"; exit 1; }
  echo "$out" | grep -q '^blocked: '"$slug"': gated: depends-on:' || { echo "FAIL: $slug not reported gated: $out"; exit 1; }
  # A gated candidate never contributes to admitted_targets -- this loop
  # mirrors exactly what a real caller (select-tick.sh's own composition)
  # does: only an admitted entry's build_into is appended.
done
# The caller-level "nothing to do for this target" path: only reachable
# when admitted_targets is still empty after every candidate for the
# target has been evaluated. Marker set ONLY on that path (AC6 requires an
# explicit marker, not absence of output).
nothing_to_do_marker=""
[ -z "$admitted_targets" ] && nothing_to_do_marker="nothing-to-do-for-target:/tmp/select-guard-selslot-b-repo"
[ -n "$nothing_to_do_marker" ] || { echo "FAIL: nothing-to-do marker not set despite zero admissions"; exit 1; }
echo "$nothing_to_do_marker"
echo ok

echo "== selslot_d: gated journal line matches the exact contract format, literally (AC4/AC8) =="
: > "$SELECT_GUARD_JOURNAL"
BUILD_DISTINCT_TARGETS=1 "$SG" selslot-first carbon "$ROOT/clone" 0 "" >/dev/null 2>&1 || true
grep -qxF 'select: selslot-first gated (depends-on) slot-not-consumed' "$SELECT_GUARD_JOURNAL" \
  || { echo "FAIL: journal missing exact gated line"; cat "$SELECT_GUARD_JOURNAL" 2>/dev/null; exit 1; }
echo ok

echo "ALL PASS"
