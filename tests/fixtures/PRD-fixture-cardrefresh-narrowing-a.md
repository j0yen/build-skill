# PRD-fixture-cardrefresh-narrowing-a (test fixture)

- Status: built
- build_target: shell
- Drafted: 2026-09-16

## Problem statement

This is PRD A in a shared-build_into pair used by
tests/cardrefresh_ac_narrowing.sh. PRD A landed first and owns AC
numbers 1-4 in this repo's shared PRD-numbering scheme. PRD B (the
fixture the test actually refreshes against) reuses the same repo's
build_into but only ever built its own AC1-AC2 -- A's AC3/AC4 must
never leak into B's card as pointers to test files B's own tree does
not have.

## Acceptance

1. P0 — Given PRD A's own change, When the refresh runs, Then AC1 is
   kept and points at PRD A's real, mapped test file.
2. P0 — Given PRD A's own change, When the refresh runs, Then AC2 is
   kept and points at PRD A's real, mapped test file.
3. P0 — Given PRD A's own change, When the refresh runs, Then AC3 is
   kept and points at PRD A's real, mapped test file.
4. P0 — Given PRD A's own change, When the refresh runs, Then AC4 is
   kept and points at PRD A's real, mapped test file.
