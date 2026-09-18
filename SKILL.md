---
name: build
description: Continuously implement queued PRDs end-to-end — scan for new PRDs, build them (delegating to /rustbuild for Rust — cargo runs on RedBaron, locally there and remotely from every other node), wire them into the system, publish them as GitHub repos per the PRD's `publish:` key (default `j0yen/private`; the joeyen-atscale route was retired 2026-08-27), update Abouts (per-repo READMEs + wintermute REPOS.md), and draft follow-on PRDs that expand Claude's own capabilities. Rust routes to /rustbuild, Python (`python-*`) to /pybuild. The parsed PRD contract is documented in build-contract.md. Runs on manual invocation or systemd-user timer when enabled; up to `BUILD_MAX_BRANCHES` PRDs (default 30, env-overridable per host since 2026-09-11) advanced in parallel per tick, one ATOMIC step at a time per PRD, chained while green with no default cap (2026-09-09). Use when the user says /build, when the SessionStart hook reports a queued PRD, or when the user asks Claude to "make progress on the queue" or "build the next thing."
model: sonnet
---

# /build — continuous PRD implementation loop (index)

`/build` walks the PRDs under `~/Documents/PRDs/build-queue/` from "queued"
to "shipped": implementing, wiring, publishing, documenting, then drafting
follow-on PRDs. This file is a 200-line INDEX, not the procedure itself
(PRD-build-branch-contract-split) — one thing this file used to be four
things (coordinator procedure, branch contract, operator manual, incident
history) and every model touching the loop paid to read all four on every
tick. It is now split:

## Documents

- **`docs/branch-contract.md`** — the ONLY document a dispatched branch
  agent needs (Phases 3→4→5→7, ≤400 lines, zero dated text, lint-enforced).
  Compose every branch dispatch prompt from this file verbatim — never by
  re-deriving directives from prose elsewhere — and tag that dispatch's
  journal/manifest line `prompt-source=branch-contract` so the wiring is
  checkable from the journal, not just claimed.
- **`docs/operator.md`** — the full coordinator procedure (every phase's
  mechanics, in detail) plus runbooks: manual invocation, re-arm/pause/
  resume, second-lane install, burst configuration, status commands,
  selftests. Read this when SKILL.md's one-liner below isn't enough.
- **`docs/history.md`** — every dated incident/rationale paragraph that
  used to sit inline in this file, under a heading naming its date and
  PRD slug.
- **`build-contract.md`** (sibling, unchanged by this PRD) — the PRD
  frontmatter contract `/build` parses and `/dream` writes; keep the two
  in step.

## Phases (each tick) — one line each, full mechanics in docs/operator.md

0. **Guard** — verify (never acquire) `tick.lock` via `scripts/tick-run.sh
   --check-held`; roll over `budget.json` (all caps null, telemetry only).
1. **Scan** — `scripts/manifest-reconcile.sh`, then `scripts/scan-prds.sh`
   (runs the `scripts/prd-lint.sh` gate), then
   `scripts/manifest-invariants.sh --prd-dir "$PRD_DIR"`.
2. **Select** — `scripts/select-tick.sh --prd-dir ~/Documents/PRDs --lane
   $(hostname) --format json` decides the whole candidate pool once;
   dispatch every entry of its `admitted[]` verbatim.
2.5. **RedBaron reachability** — for any selected cargo-bound PRD on a
   non-RedBaron lane, `~/.claude/skills/rustbuild/scripts/cargo-on-redbaron.sh
   status` before dispatch.
3. **Classify** — determine `build_target` and route: Rust → `/rustbuild`;
   `python-*` → `/pybuild`; `rust-extend`/`kernel-extend` → the extend
   paths; `shell`/`hooks`/`config` → direct Write/Edit; ambiguous →
   `scripts/mark-needs-classification.sh`.
4. **Implement** — one ATOMIC, manifest-committed step per PRD, chained
   while green (`scripts/chain-guard.sh check <slug> ...`, no default
   cap). Worktree-isolate any PRD with `build_into` set
   (`scripts/worktree-extend.sh add|land`) before any write.
5. **Abouts** — update the shipped repo's README + `~/wintermute/REPOS.md`.
6. **Reflect & propose** — draft follow-on PRDs the tick's experience made
   obvious; commit + push.
7. **Persist & log** — patch the manifest via `scripts/manifest-set.sh
   <slug> <patch.json>` (temp file, never inline), then append one journal
   line (`lane=<hostname>` in its `key=value` tail).

## Parallelism

Up to `BUILD_MAX_BRANCHES` PRDs (default 30, per-host override) dispatch
per tick as parallel Agent tool calls in one message, model `sonnet`
unless escalation criteria apply. Same-`build_into` PRDs isolate via
worktrees; locking, dispatch mechanics, and failure isolation are in
`docs/operator.md`.

## Scripts

`scripts/*.sh` — one script per operation; each documents its own usage,
mechanics, and exit codes in its own header comment (see e.g.
`scripts/worktree-extend.sh`, `scripts/select-tick.sh`,
`scripts/chain-guard.sh`). `docs/scripts-index.md` — one line per script,
pulled from that header comment, regenerate with `scripts/scripts-index-gen.sh`
(`--check` to detect drift without rewriting) — is the full index; a
script whose header comment is missing lists under that file's own
"Undocumented" section instead of being silently dropped. `README.md`'s
"Repo layout" section indexes the handful a newcomer reads first.

## Selftests / Disable

`scripts/run-selftests.sh <name...> | --all` — the one entrypoint; never
invoke a `*-selftest.sh` directly for a real run (isolates `BUILD_TEST_ROOT`
away from production state). `systemctl --user disable --now
claude-build.timer` disables the loop; see `docs/operator.md` for re-arm.

## Hard safety rules (numbered list + full text in docs/operator.md)

Never force-push; never `rm -rf` outside a self-built `target/`-style dir;
never overwrite `settings.json` without an atomic backup; never invoke
`/build` recursively; defer to the user on a target-path conflict
(`needs_classification`); Joe Yen identity for wintermute commits; a
shared `build_into` is ALWAYS worktree-isolated, never mutated in place
by two branches.
