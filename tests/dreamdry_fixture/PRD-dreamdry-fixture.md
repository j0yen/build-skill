# PRD — dreamdry-fixture: a lint-clean fixture the dream.dryrun live proof stages under a fresh slug

- Status: queued
- build_target: shell
- build_into: /home/jsy/wintermute/build-skill
- build_priority: high
- publish: j0yen/private
- test_prefix: dreamdryfx
- Grounding: grounded
- Vision: visions/dreamdry-fixture.md
- Seed: joe:2026-11-14
- PM: Joe
- Drafted: 2026-11-15

## TL;DR

A fixture, never persisted: `scripts/dream-dryrun.sh` stages a fresh-slug copy of this file in a temporary corpus and asks the daemon what it would say.

## Problem statement

The dry run's live proof needs a PRD file this repository owns, so it never reads a real queued PRD.

## Goals

- One lint-clean PRD with no dependency and no URL.

## Non-goals

- Being built.

## User stories

1. As the dry run's live proof, I copy this file under a fresh slug and read one verdict.

## Requirements

- R1. The file stays lint-clean under `scripts/dream-lint.sh`.

## Success metrics

| metric | baseline | target | method | timeframe |
|---|---|---|---|---|
| lint findings | 0 | 0 | `scripts/dream-lint.sh` | each run |

## Technical considerations

None.

## Migration / compatibility

None.

## Open questions

None.

## Acceptance criteria

1. P0 — Given this file, When `scripts/dream-lint.sh` runs on it, Then it exits 0.
2. P0 — Given the landed fixture, When the judge runs the lint hook on it, Then it exits 0. (Live; evidence: `cmd:~/wintermute/build-skill/scripts/dream-lint.sh ~/wintermute/build-skill/tests/dreamdry_fixture/PRD-dreamdry-fixture.md`)
