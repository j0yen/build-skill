#!/usr/bin/env bash
# prd-pipeline-selftest.sh — PRD-prd-pipeline-telemetry ACs 1-6, self-
# contained (builds its own fixture git repo + fake ledger, touches
# nothing under ~/Documents/PRDs or ~/.cache/token-ledger). Exits 0 on
# success, non-zero (naming the failing AC) otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/prd-pipeline.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found/executable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

ok()   { echo "ok  $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------
# Fixture A: a PRDs-shaped repo with a controlled commit history, used
# for AC1 (drafted/shipped ground truth), AC2 (blocked/queued + runway_h
# present), AC3 (no-ledger day), AC4 (ledger present, >0 ships).
# ---------------------------------------------------------------------
repoA="$tmp/prdsA"
mkdir -p "$repoA/build-queue" "$repoA/built-prds"
git -C "$repoA" init -q
git -C "$repoA" config user.email test@example.com
git -C "$repoA" config user.name "Test"

commit_on() { # commit_on <YYYY-MM-DD> -- <files...>
  local d="$1"; shift; shift # drop the literal "--"
  GIT_AUTHOR_DATE="${d}T12:00:00Z" GIT_COMMITTER_DATE="${d}T12:00:00Z" \
    git -C "$repoA" commit -q -m "fixture commit $d" "$@"
}

# 2026-09-10: draft two PRDs (not part of the pinned AC1 date; exercises
# that drafted/shipped are scoped to the requested day only).
printf '%s\n' "- Status: queued" > "$repoA/build-queue/PRD-alpha.md"
printf '%s\n' "- Status: queued" > "$repoA/build-queue/PRD-beta.md"
git -C "$repoA" add build-queue/PRD-alpha.md build-queue/PRD-beta.md
commit_on 2026-09-10 -- build-queue/PRD-alpha.md build-queue/PRD-beta.md

# 2026-09-12 (the pinned AC1/AC4 date): draft one more PRD, ship one
# (git mv alpha into built-prds/, plus mark beta blocked in place).
printf '%s\n' "- Status: queued" > "$repoA/build-queue/PRD-gamma.md"
git -C "$repoA" add build-queue/PRD-gamma.md
git -C "$repoA" mv build-queue/PRD-alpha.md built-prds/PRD-alpha.md
printf '%s\n' "- Status: blocked" > "$repoA/build-queue/PRD-beta.md"
git -C "$repoA" add build-queue/PRD-beta.md
commit_on 2026-09-12 -- build-queue/PRD-gamma.md built-prds/PRD-alpha.md build-queue/PRD-beta.md

# Live/current state after both commits: build-queue/ has gamma (queued)
# and beta (blocked); built-prds/ has alpha. Ground truth for AC1 (day
# 2026-09-12 only): drafted=1 (gamma), shipped=1 (alpha, no-renames add).
line_ac1="$(PRD_PIPELINE_PRDS_DIR="$repoA" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12)"
case "$line_ac1" in
  "2026-09-12 drafted=1 shipped=1 "*) ok "AC1: drafted/shipped for the pinned day match git-log ground truth ($line_ac1)" ;;
  *) fail "AC1: expected drafted=1 shipped=1, got: $line_ac1" ;;
esac

# AC2: blocked/queued match grep -c over frontmatter; line carries runway_h.
grep_blocked="$(grep -lE '^- Status: blocked' "$repoA"/build-queue/PRD-*.md | wc -l | tr -d '[:space:]')"
grep_queued="$(grep -lE '^- Status: queued'  "$repoA"/build-queue/PRD-*.md | wc -l | tr -d '[:space:]')"
line_ac2="$(PRD_PIPELINE_PRDS_DIR="$repoA" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT")"
script_blocked="$(printf '%s' "$line_ac2" | grep -oE 'blocked=[0-9]+' | cut -d= -f2)"
script_queued="$(printf '%s' "$line_ac2" | grep -oE 'queued=[0-9]+' | cut -d= -f2)"
if [ "$script_blocked" = "$grep_blocked" ] && [ "$script_queued" = "$grep_queued" ]; then
  ok "AC2: blocked=$script_blocked queued=$script_queued match grep -c ground truth"
else
  fail "AC2: blocked=$script_blocked (want $grep_blocked) queued=$script_queued (want $grep_queued)"
fi
case "$line_ac2" in
  *"runway_h="*) ok "AC2: line includes runway_h" ;;
  *) fail "AC2: no runway_h field in: $line_ac2" ;;
esac

# AC3: no ledger file at all -> wtok_per_ship=na:no-ledger, exit 0.
out_ac3="$(PRD_PIPELINE_PRDS_DIR="$repoA" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12)"; rc_ac3=$?
if [ "$rc_ac3" -eq 0 ] && printf '%s' "$out_ac3" | grep -q 'wtok_per_ship=na:no-ledger'; then
  ok "AC3: no-ledger day prints wtok_per_ship=na:no-ledger, exit 0"
else
  fail "AC3: rc=$rc_ac3 out=$out_ac3"
fi

# AC4: ledger present, >0 ships that day -> weighted/ships, integer-rounded.
# shipped(2026-09-12)=1 in repoA, weighted=100 -> 100/1=100 (exact; also
# prove the rounding half with shipped=3 further down via fixture B).
ledgerA="$tmp/ledgerA"; mkdir -p "$ledgerA"
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n2026-09-12\tsonnet=100\t100\tbudget off\tyes\ttest\t\t2026-09-13T00:00:00Z\n' > "$ledgerA/ledger.tsv"
out_ac4="$(PRD_PIPELINE_PRDS_DIR="$repoA" TOKEN_LEDGER_STATE_DIR="$ledgerA" "$SCRIPT" --date 2026-09-12)"
if printf '%s' "$out_ac4" | grep -q 'wtok_per_ship=100'; then
  ok "AC4: wtok_per_ship=100 for weighted=100/shipped=1"
else
  fail "AC4: expected wtok_per_ship=100, got: $out_ac4"
fi

# AC4b: rounding — weighted=100 over 3 ships -> round(33.33)=33.
repoA4b="$tmp/prdsA4b"
mkdir -p "$repoA4b/build-queue" "$repoA4b/built-prds"
git -C "$repoA4b" init -q
git -C "$repoA4b" config user.email test@example.com
git -C "$repoA4b" config user.name "Test"
for n in one two three; do printf 'x\n' > "$repoA4b/built-prds/PRD-$n.md"; done
git -C "$repoA4b" add built-prds
GIT_AUTHOR_DATE=2026-09-12T12:00:00Z GIT_COMMITTER_DATE=2026-09-12T12:00:00Z \
  git -C "$repoA4b" commit -q -m "three ships"
out_ac4b="$(PRD_PIPELINE_PRDS_DIR="$repoA4b" TOKEN_LEDGER_STATE_DIR="$ledgerA" "$SCRIPT" --date 2026-09-12)"
if printf '%s' "$out_ac4b" | grep -q 'wtok_per_ship=33'; then
  ok "AC4b: wtok_per_ship=33 for weighted=100/shipped=3 (integer-rounded)"
else
  fail "AC4b: expected wtok_per_ship=33, got: $out_ac4b"
fi

# AC5: --json run twice concurrently -> the sidecar is whole/parseable
# after both exit (atomic temp-file + rename never leaves a partial file).
stateJ="$tmp/state-json"
mkdir -p "$stateJ"
BUILD_STATE_DIR="$stateJ" PRD_PIPELINE_PRDS_DIR="$repoA" TOKEN_LEDGER_STATE_DIR="$ledgerA" "$SCRIPT" --date 2026-09-12 --json &
p1=$!
BUILD_STATE_DIR="$stateJ" PRD_PIPELINE_PRDS_DIR="$repoA" TOKEN_LEDGER_STATE_DIR="$ledgerA" "$SCRIPT" --date 2026-09-12 --json &
p2=$!
wait "$p1" "$p2"
if [ -f "$stateJ/prd-pipeline/2026-09-12.json" ] && python3 -c "import json; json.load(open('$stateJ/prd-pipeline/2026-09-12.json'))" 2>/dev/null; then
  ok "AC5: JSON sidecar whole and parseable after concurrent --json runs"
else
  fail "AC5: JSON sidecar missing or unparseable after concurrent runs"
fi

# AC6: zero ships in the trailing 7 days -> --week prints runway_h=na for
# every line and the totals line, with no division error (exit 0).
repoB="$tmp/prdsB"
mkdir -p "$repoB/build-queue" "$repoB/built-prds"
git -C "$repoB" init -q
git -C "$repoB" config user.email test@example.com
git -C "$repoB" config user.name "Test"
printf '%s\n' "- Status: queued" > "$repoB/build-queue/PRD-solo.md"
git -C "$repoB" add build-queue/PRD-solo.md
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
  git -C "$repoB" commit -q -m "old draft, no ships ever"
out_ac6="$(PRD_PIPELINE_PRDS_DIR="$repoB" TOKEN_LEDGER_STATE_DIR="$tmp/no-ledger" "$SCRIPT" --date 2026-09-12 --week)"; rc_ac6=$?
if [ "$rc_ac6" -eq 0 ] && ! printf '%s' "$out_ac6" | grep -qE 'runway_h=[0-9]'; then
  ok "AC6: zero-ship week prints runway_h=na throughout, exit 0, no division error"
else
  fail "AC6: rc=$rc_ac6 out=<<<$out_ac6>>>"
fi

if [ "$fails" -ne 0 ]; then
  echo "SELFTEST FAILED ($fails)"
  exit 1
fi
echo "SELFTEST PASSED"
