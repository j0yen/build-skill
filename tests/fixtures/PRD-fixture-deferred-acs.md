# PRD-fixture-deferred-acs (test fixture)

Status: Draft v0.1
build_target: rust-cli
build_priority: low
deferred_acs: [1, 3, 5]

## TL;DR

Fixture PRD used by `tests/scan-deferred-acs.sh` to assert that
`scan-prds.sh` extracts the inline `deferred_acs:` list verbatim.

## Acceptance

1. Wake-to-event latency requires a real mic (deferred).
2. JSON snapshot — code-pairable.
3. AEC quality requires PipeWire (deferred).
4. Schema round-trip — code-pairable.
5. 8h soak — deferred.
