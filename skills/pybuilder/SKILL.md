---
name: pybuilder
description: PRD-driven, evaluation-gated Python code generation. Use when the user wants to build a Python CLI, library, or LLM agent from a Product Requirements Document under an autonomous iterate-and-prove loop. Applying test-driven development for LLM applications — multi-dimensional log-don't-assert evaluation, N-run stability classification, git-commit-pinned eval datasets, and a receipt-based risk gate. Targets cli|lib|agent; agent (state-machine) is first-class.
version: 1.0.0
---

# pybuilder

## What this skill does

Takes a PRD (file path or pasted text) and drives a 5-stage pipeline that yields a
Python project where every artifact is (a) generated from a structured
`intent-card.json` derived via 5-Whys, (b) scaffolded behind a **locked harness**
(ruff + mypy + pytest + coverage; the agent edits only `src/`), (c) evaluated across
a **quality vector** rather than a single pass/fail, and (d) gated by structured
receipts before declaring "ready." It applies the four pillars of *TDD for LLM
applications*:

1. **State-machine modeling** (`pybuilder.flowgraph`) — agents are explicit, traced
   state machines; the flowchart *is* the code, and production traces become
   replayable pytest cases.
2. **Multi-dimensional eval** (`pybuilder.eval`) — exact / fuzzy / static / human /
   judge, collapsed to a quality vector.
3. **Log-don't-assert** (`pybuilder.eval.results_bag`) — every dimension recorded per
   run without aborting on first miss; aggregated to CSV / DataFrame.
4. **Stability + provenance** (`pybuilder.stability`, `pybuilder.dataset`) — same input
   N times to separate acceptable LLM noise from an underspecified prompt; every eval
   row pinned to the producing git commit.

## When to invoke

- The user hands you a PRD and asks for a Python project (CLI, library, or agent).
- The user says "build me a Python X" with concrete acceptance criteria.
- Dogfooding pybuilder against one of its own components.

Do **not** invoke for: surgical edits to an existing Python file (use direct tools);
non-Python projects.

## Targets

`--target cli | lib | agent`. **`agent` is first-class** — the state-machine target is
the reason this tool exists.

## Model assignments

Each stage uses the right model for its job. These are the permanent defaults —
do not override unless the user explicitly asks.

| Stage | Model | Why |
|---|---|---|
| Stage 1 — Intake (5-Whys) | **Sonnet** | Interpreting a PRD and extracting unambiguous ACs requires real reading comprehension |
| Stage 2 — Scaffold | **Haiku** | Generating boilerplate project structure from a filled intent card is templating, not reasoning |
| Stage 3 — Iterate-and-Prove | **Sonnet** | Writing `src/`, evaluating quality vectors, deciding to advance or revert |
| Stage 4 — Gate receipt checks | **Haiku** | Reading structured JSON receipts and evaluating pass/fail conditions is mechanical |
| Stage 4 — Reviewer receipt | **Opus** | Independent adversarial second opinion; never self-approval; never downgrade |
| Stage 5 — Postmortem summary | **Haiku** | Summarizing a completed run from structured data |

Model IDs (set in `src/pybuilder/models.py`; override via env vars if needed):
- `PYBUILDER_FAST_MODEL` — default `claude-haiku-4-5-20251001`
- `PYBUILDER_BUILD_MODEL` — default `claude-sonnet-4-6`
- `PYBUILDER_REVIEW_MODEL` — default `claude-opus-4-8`

## Pipeline

```
PRD ──► Stage 1: Intake (5-Whys)           [Sonnet]  ──► intent-card.json
        Stage 2: Scaffold (locked harness) [Haiku]   ──► <project>/ tree
        Stage 3: Iterate-and-Prove loop    [Sonnet]  ──► quality vector + stability
        Stage 4: Risk Gate                           ──► ready / blocked
                 ├─ receipt checks         [Haiku]
                 └─ reviewer              [Opus]
        Stage 5: Postmortem + Self-Evolve  [Haiku]   ──► evolution-proposal.json
```

### Stage 1 — Intake (5-Whys) · Sonnet
Run `prompts/prd-intake-5whys.md` against the PRD. Output validates against
`schemas/intent-card.schema.json` (`intent-card.v1`). Refuse to proceed if ambiguity
leaves any MUST-AC undefined — surface what's missing and ask.

### Stage 2 — Scaffold · Haiku
`pybuilder scaffold intent-card.json <dest>`. Emits a tree where `tests/`, `scripts/`,
and config are read-only and the agent edits only `src/`. The empty tree is green
under ruff + mypy + pytest. For `--target agent`, also emits a `StateMachine` skeleton.
Use Haiku to interpret the intent card and guide scaffold choices — this is structural
work, not reasoning work.

### Stage 3 — Iterate-and-Prove · Sonnet
Edit `src/` only. Each iteration: run `scripts/run-metrics.sh` (→ `metrics.json`),
evaluate the artifact across dimensions into a `ResultsBag`, compute the quality vector
(`pybuilder.eval.vector`), and for LLM-bearing artifacts run `pybuilder.stability`
(advance only if not `underspecified`). Advance on **net vector improvement AND no
MUST-AC regression**; else revert. Extract any failing real trace into a regression
case via `pybuilder.flowgraph.trace_to_testcase`.

### Stage 4 — Risk Gate
`pybuilder gate <project> --target <t>`. Reads receipts under `<project>/.pybuilder/`:
`intake`, `scaffold-integrity`, `proof` (ruff+mypy+pytest+coverage), `audit`
(BAD_PYTHON), `ci-checks`; and for agents `eval-vector`, `stability`,
`dataset-provenance`. Use **Haiku** to read and evaluate these structured receipts.

The `reviewer` receipt is separate and always uses **Opus** — an independent agent
reads the acceptance criteria in plain English and assesses whether the artifact
genuinely satisfies them. No self-approval. Missing / stale / blocked → block with a
machine-readable diagnostic.

### Stage 5 — Postmortem & Self-Evolve · Haiku
Summarize the run; queue an append-only `evolution-proposal.json`. Grow the BAD_PYTHON
catalog and the default dimension weights from accumulated runs. This is summarization
from structured data — Haiku is sufficient.

## CLI

```bash
pybuilder scaffold <intent-card.json> <dest> [--force]
pybuilder audit    <path>                          # BAD_PYTHON AST scan
pybuilder gate     <project> --target cli|lib|agent
pybuilder demo                                      # whole pipeline on a tiny agent
```

## Layout

```
pybuilder/
├── skill/
│   ├── SKILL.md                       ← this file
│   ├── schemas/intent-card.schema.json
│   └── prompts/{prd-intake-5whys,judge,reviewer}.md
├── skills/prd-writer/                 ← /prd-writer skill (bundled)
├── src/pybuilder/                     ← the pipeline
│   └── models.py                      ← model constants + env overrides
├── tests/
└── install.sh
```

## Reused skills
- `/loop` — long-running iterate-and-prove cadence.
- `/verify` — final end-to-end app-run check (Stage 4).
- `/code-review` — the `reviewer` receipt (dispatches on Opus).
