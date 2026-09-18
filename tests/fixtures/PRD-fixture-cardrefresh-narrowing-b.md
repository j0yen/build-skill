# PRD-fixture-cardrefresh-narrowing-b (test fixture)

- Status: Draft v0.1
- build_target: shell
- Drafted: 2026-09-17

## Problem statement

This is PRD B in a shared-build_into pair used by
tests/cardrefresh_ac_narrowing.sh (fix for intent-card-refresh.sh's
acceptance_criteria narrowing gap). AC1-AC2 below are B's own, real,
already-tested ACs. AC3-AC4 reuse the numbering of a sibling PRD (PRD A,
built earlier against the same repo) purely to prove they get dropped,
not pointed at a scaffold file the tree never had for B.

## Acceptance

1. P0 — Given PRD B's own change, When the refresh runs, Then AC1 is
   kept and points at its real, mapped test file.
2. P0 — Given PRD B's own change, When the refresh runs, Then AC2 is
   kept and points at its real, mapped test file.
3. P1 — Given AC3 belongs to sibling PRD A, not PRD B, When the refresh
   runs, Then AC3 is dropped rather than pointed at a nonexistent
   scaffold file.
4. P1 — Given AC4 belongs to sibling PRD A, not PRD B, When the refresh
   runs, Then AC4 is dropped rather than pointed at a nonexistent
   scaffold file.
