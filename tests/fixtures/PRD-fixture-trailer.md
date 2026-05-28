# PRD-fixture-trailer (test fixture)

Status: Draft v0.1
build_target: rust-cli
build_priority: low
deferred_acs: [1, 3]

## TL;DR

Fixture PRD used by `tests/archive-trailer.sh`. 4 ACs total, [1,3]
declared deferred. Drives AC3 of PRD-build-deferred-acs: archive-trailer.sh
must emit a combined `Verified-completed:` + `Deferred:` block, with
the deferred entries falling back to "(no reason given)" when
deferred_ac_reasons is empty (current scan-prds stub) and using the
real reason when --reasons-json is passed.

## Acceptance

1. Wake-to-event latency requires a real mic (deferred).
2. JSON snapshot — code-pairable.
3. AEC quality requires PipeWire (deferred).
4. Schema round-trip — code-pairable.
