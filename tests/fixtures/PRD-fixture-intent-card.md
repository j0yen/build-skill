# PRD-fixture-intent-card (test fixture)

- Status: Draft v0.1
- build_target: shell
- Drafted: 2026-01-01

## Problem statement

The fixture repo's intent card describes a scope that no longer matches
what actually shipped, which is exactly the drift intent-card-refresh.sh
exists to close. This paragraph is the fixture's root_motivation source.

## Acceptance

1. P0 — Given a landed PRD, When the refresh runs, Then the card names
   this PRD's slug, source path, and one acceptance_criteria entry per
   AC line.
2. P1 — Given an existing card field the PRD cannot source, When the
   refresh runs, Then the field carries forward unchanged with
   carried_forward true.
