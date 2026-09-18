#!/usr/bin/env bash
# tests/gateinfra_ac10_reviewer_block_misfiled_digest.sh — PRD-build-gate-
# finalize-verdict-split P2 requirement 8 / AC10.
#
# Given a week of journal, When scripts/reviewer-misfile-digest.sh runs,
# Then a `reviewer-block-misfiled: <n>` line is present. Three fixture
# scenarios: (1) a repo+head with BOTH an
# `infra=reviewer-agent:finalize-rejected` line and a
# `reviewer-agent verdict=block` line (the misfile signature — these two
# paths are mutually exclusive per finalize call after this PRD's
# classifier, so this is the regression case) counts once; (2) a plain
# finalize-rejected refusal with no matching verdict=block line for the
# same head does not count (Goals: a refusal is never a misfile); (3) an
# empty journal window still prints the line with n=0 (Joe,
# 2026-09-18T13:15Z iter_log: "n may be 0 today").
set -uo pipefail

DIGEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts/reviewer-misfile-digest.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac10-digest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
JDIR="$T/journal"
mkdir -p "$JDIR"

# Scenario 1: misfiled — same repo+head carries both lines.
cat >> "$JDIR/2026-09-18.md" <<'EOF'
2026-09-18T03:14:10Z  gate  widget  incomplete  (scope=branch slug=widget-x head=abc1234def base=main gate: head=abc1234def receipts=25 pass=24 block=1 verdict=block blocking=none wall=100s) verdict=block infra=reviewer-agent:finalize-rejected
2026-09-18T03:14:12Z  gate  widget  reviewer-agent verdict=block reasons=[rollback-plan] finalize_rc=1
EOF

# Scenario 2: genuine refusal, no matching verdict=block for this head —
# not a misfile.
cat >> "$JDIR/2026-09-18.md" <<'EOF'
2026-09-18T05:00:00Z  gate  sprocket  block  (scope=branch slug=sprocket-y head=9990000fff base=main gate: head=9990000fff receipts=25 pass=23 block=2 verdict=block blocking=ci-checks wall=200s) verdict=block infra=reviewer-agent:finalize-rejected
EOF

out1="$(REVIEWER_MISFILE_DIGEST_JOURNAL_DIR="$JDIR" REVIEWER_MISFILE_DIGEST_DAYS=7 \
  REVIEWER_MISFILE_DIGEST_NOW="2026-09-18T23:00:00Z" "$DIGEST")"
expect "AC10: digest line present" \
  "[[ \"\$out1\" == *'reviewer-block-misfiled:'* ]]"
expect "AC10: counts exactly the one repo+head with both lines" \
  "[ \"\$out1\" = 'reviewer-block-misfiled: 1' ]"

# Scenario 3: empty window still prints n=0.
EMPTY="$T/empty-journal"
mkdir -p "$EMPTY"
out2="$(REVIEWER_MISFILE_DIGEST_JOURNAL_DIR="$EMPTY" REVIEWER_MISFILE_DIGEST_DAYS=7 \
  REVIEWER_MISFILE_DIGEST_NOW="2026-09-18T23:00:00Z" "$DIGEST")"
expect "AC10: empty window still prints the line, n=0" \
  "[ \"\$out2\" = 'reviewer-block-misfiled: 0' ]"

echo "--- digest output (scenario 1+2) ---"
printf '%s\n' "$out1"
echo "--- digest output (empty) ---"
printf '%s\n' "$out2"
echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac10_reviewer_block_misfiled_digest: ALL PASS"
else
  echo "gateinfra_ac10_reviewer_block_misfiled_digest: assertion(s) FAILED"
fi
exit "$fail"
