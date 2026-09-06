# PRD-fixture-intent-card-malformed (test fixture)

- Status: Draft v0.1
- build_target: shell

## Problem statement

This fixture exists to prove intent-card-refresh.sh refuses loudly
instead of writing a card when a PRD has no parseable numbered
`N. P[0-2] — Given/When/Then` acceptance-criterion lines.

## Acceptance

Prose only, no numbered P0/P1/P2 lines here — nothing for the AC-line
regex to match.
