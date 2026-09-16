# PRD — {{SLUG}}: {{TITLE}}

- Status: queued
- build_target: rust-extend
- build_into: {{BUILD_INTO}}
- build_priority: high
- publish: none
- Depends-on:
- Vision: visions/buildloop-operations.md
- Drafted: {{DATE}}
- Grounding: {{GROUNDING}}

## TL;DR

The repo-health invariant `{{RULE}}` fired for `{{REPO}}` on {{DATE}} —
see Evidence below. This PRD exists to fix the cause, not to silence the
alarm. `build_target: rust-extend` is a starting guess ({{REPO}}'s usual
shape); if `{{BUILD_INTO}}` doesn't validate as a Cargo workspace on the
lane that picks this up, the existing build-into-substrate-mismatch lint
check reclassifies it to `needs_classification` automatically rather than
stalling silently — this PRD only guarantees the incident is not lost.

## Problem statement

`scripts/repo-health.sh` computed this repo's health from the journal and
`state/ci-status.json` and found the `{{RULE}}` invariant true. Non-goal
(PRD-build-repo-health-invariants): this PRD does not itself fix the
underlying cause — see that PRD's Non-goals ("Fixing the causes the alarms
point at ... own it").

## Goals

1. Diagnose the root cause named by the evidence below.
2. Land a fix such that `{{RULE}}` does not re-fire for `{{REPO}}` for at
   least 7 days.

## Non-goals

- Silencing or raising the `{{RULE}}` threshold without a diagnosed cause.

## Acceptance criteria

1. P0 — Given the evidence below, When the root cause is fixed, Then
   `repo-health.sh compute` no longer lists `{{RULE}}` among `{{REPO}}`'s
   alarms on the next tick.

## Evidence

{{EVIDENCE}}
