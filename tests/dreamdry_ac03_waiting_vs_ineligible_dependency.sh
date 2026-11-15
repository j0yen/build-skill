#!/usr/bin/env bash
# dreamdry_ac03 — PRD-dream-dryrun-hook AC3. A and B (B depends on A) in one call,
# fake answering admit for A and skip:depends-unresolved:A for B: A eligible,
# B `waiting — depends-unresolved:A`, exit 5. B alone with A not in the batch and not
# in the destination build-queue, same fake answer: `ineligible — depends-unresolved:A`,
# exit 3.
# Boundary (recorded in out/report.md): with A in NO corpus directory, R1(b) and AC1
# make prd-lint refuse first (`depends-on-missing`), so the explain branch is reached
# only with A in the destination built-prds/ (lint passes, A is not queued). Both
# shapes are asserted below.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-a
dd_prd "$DD_T/drafts" dreamdry-b "- Depends-on: PRD-dreamdry-a.md"
dd_answer dreamdry-b "tick-would: skip:depends-unresolved:dreamdry-a {\"reasons\":[\"depends-unresolved:dreamdry-a\"]}"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md" "$DD_T/drafts/PRD-dreamdry-b.md"
dd_expect_line dreamdry-a "admit-would: dreamdry-a eligible claims=unknown open-runs=unknown" "AC3 batch A"
dd_expect_line dreamdry-b "admit-would: dreamdry-b waiting — depends-unresolved:dreamdry-a claims=unknown open-runs=unknown" "AC3 batch B"
dd_expect_rc 5 "AC3 batch"
[ "$(grep -c '^admit-would:' <<<"$DD_OUT")" -eq 2 ] && [ "$(grep '^admit-would:' <<<"$DD_OUT" | head -1 | cut -d' ' -f2)" = dreamdry-a ] \
  && dd_ok "R3 one line per file in argument order" || dd_fail "R3 order: $DD_OUT"

# A queued in the destination (not in the batch): still waiting
dd_prd "$DD_T/dest/build-queue" dreamdry-a
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-b.md"
dd_expect_line dreamdry-b "admit-would: dreamdry-b waiting — depends-unresolved:dreamdry-a claims=unknown open-runs=unknown" "AC3 dep queued in destination"
dd_expect_rc 5 "AC3 dep queued in destination"
rm -f "$DD_T/dest/build-queue/PRD-dreamdry-a.md"

# B alone, A only in built-prds/: lint passes, the daemon answer is a refusal
dd_prd "$DD_T/dest/built-prds" dreamdry-a
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-b.md"
dd_expect_line dreamdry-b "admit-would: dreamdry-b ineligible — depends-unresolved:dreamdry-a claims=unknown open-runs=unknown" "AC3 B alone (A not batch, not queued)"
dd_expect_rc 3 "AC3 B alone"
rm -f "$DD_T/dest/built-prds/PRD-dreamdry-a.md"

# B alone, A in no corpus directory at all: prd-lint refuses first (R1(b) precedence)
: > "$DD_T/wb.log"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-b.md"
dd_expect_line dreamdry-b "admit-would: dreamdry-b ineligible — lint: depends-on-missing claims=unknown open-runs=unknown" "AC3 B alone, A nowhere (lint precedence)"
dd_expect_rc 3 "AC3 B alone, A nowhere"
dd_tmp_empty "AC3"
dd_finish
