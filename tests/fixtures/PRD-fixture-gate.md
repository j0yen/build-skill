# PRD-fixture-gate (test fixture)

Status: Draft v0.1
build_target: rust-cli
build_priority: low
deferred_acs: [1, 3]

## TL;DR

Fixture PRD used by `tests/verified-completed.sh`. 4 ACs total, [1,3]
declared deferred. Drives the AC2 gate: with `--paired 2,4` the gate
must pass; with `--paired 2` it must fail naming AC4.

## Acceptance

1. Wake-to-event latency requires a real mic (deferred).
2. JSON snapshot — code-pairable.
3. AEC quality requires PipeWire (deferred).
4. Schema round-trip — code-pairable.
