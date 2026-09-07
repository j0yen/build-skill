# `agent/intent-card.json` — the shape `autobuilder intake` accepts

Read-only reference, transcribed from `~/wintermute/rustbuild/autobuilder/src/intake.rs`
(`validate_file`, `ALLOWED_TOP`, and the per-field `check_*` helpers) on
2026-09-07, per PRD-build-intent-card-schema requirement 1. This PRD makes
no changes to `intake.rs` — this file exists so the writer scripts
(`scripts/intent-card-refresh.sh`, `scripts/onboard-repo.sh`) and anyone
editing a card by hand can see the accepted shape without re-reading Rust.
If `intake.rs` changes, this file drifts — re-derive it from source, don't
hand-edit around a validator failure.

## Top-level fields

`additionalProperties: false` at every object level in this schema —
**any key not listed below fails validation**, including hand-added
bookkeeping fields. This is the fact this PRD exists to work around:
`carried_forward` was never on `ALLOWED_TOP`, so every card the writer
scripts produced with an embedded `carried_forward` object failed
`intake --validate` before a receipt could be written.

Required (`REQUIRED` in `intake.rs`):

| field | type | constraint |
|---|---|---|
| `schema` | string | must equal `"autobuilder.intent_card.v1"` |
| `prd_source` | string | length 1..∞ |
| `root_motivation` | string | length 1..1000 |
| `user_persona` | string | length 1..500 |
| `unfakeable_metric` | object | see below |
| `acceptance_criteria` | array | ≥1 item, see below |
| `scope` | array of string | |
| `non_goals` | array of string | |
| `hard_constraints` | object | see below |
| `five_whys_trace` | array | 1..5 items, see below |
| `created_at` | string | RFC3339 date-time |

Optional (allowed but not required — the two extra entries in
`ALLOWED_TOP` beyond `REQUIRED`):

| field | type | constraint |
|---|---|---|
| `intent_slug` | string | matches `^[a-z0-9][a-z0-9-]{0,62}$` |
| `ambiguities_resolved` | array | see below |

**Nothing else is allowed at the top level.** No `carried_forward`, no
free-form metadata, no provenance object — any such field must live
outside the card (see "Sidecar" below).

## `unfakeable_metric` (object)

Required: `name` (string), `lower_is_better` (bool), `harness_command`
(string). Optional: `target` (number or null). No other keys.

## `acceptance_criteria[]` (array, ≥1 item)

Each item is an object with required `id` (matches `^AC[0-9]+$`), `level`
(one of `MUST`/`SHOULD`/`MAY`), `test` (string), `description` (string,
length 1..500). No other keys per item.

## `hard_constraints` (object)

Required: `rust_edition` (`"2021"` or `"2024"`), `target_kind` (`"cli"` or
`"lib"`), `deny_unsafe` (bool). Optional: `max_deps` (non-negative integer
or null), `msrv` (string matching `^[0-9]+\.[0-9]+(\.[0-9]+)?$`, or null),
`additional` (object whose values are each string/number/bool). No other
keys.

## `five_whys_trace[]` (array, 1..5 items)

Each item is an object with required `why` (integer 1..5), `q` (non-empty
string), `a` (non-empty string). No other keys per item.

## `ambiguities_resolved[]` (array, optional, unbounded)

Each item is an object with required `question` (string), `resolution`
(string). No other keys per item.

## `created_at`

RFC3339 / JSON-Schema `format: date-time`:
`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$`.

## Sidecar: where `carried_forward` actually lives

Since no location inside the validated card tolerates an extra field,
`carried_forward` (the per-field boolean map recording which required
fields a writer script could not source from the PRD and instead carried
forward from a prior card) is written to a sidecar file next to the card:

```
agent/intent-card.carried.json
```

Shape: a flat JSON object, `{"<field>": true|false, ...}`, one entry per
non-PRD-sourceable field (`user_persona`, `unfakeable_metric`, `scope`,
`non_goals`, `hard_constraints`, `five_whys_trace`, `created_at`, and
`ambiguities_resolved` when carried). `intake` never reads this file — it
is bookkeeping for humans and for `intent-card-refresh.sh`'s own
idempotency check (a re-run reads the sidecar, not the card, to know
whether a field was already marked carried on a prior run). Written
atomically (temp + rename) alongside the card, same directory, same
`agent/` creation.

For backward compatibility with cards written before this PRD (which
carry an embedded `carried_forward` object inside the card itself,
now invalid), `intent-card-refresh.sh` falls back to reading that
embedded object when no sidecar exists yet, then writes the sidecar going
forward — the card itself is always rewritten to the new, valid shape on
the very next refresh.
