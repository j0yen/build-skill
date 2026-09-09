# Manifest state machine — the transition table

PRD-build-manifest-invariants. Every status `manifest.json`'s `prds.<slug>.status`
can hold, who is allowed to write it, what may legally precede and follow it,
and its inverse (the transition back) or an explicit note that none exists
(terminal by design). `scripts/manifest-invariants.sh` hand-codes this same
set of statuses as `KNOWN_STATUSES` (generating the check from this file is
explicitly NOT required — see the PRD's Technical considerations; a selftest
(`tests/manifest-inv_ac6_table_coverage.sh`) asserts every status present in
the *live* manifest appears in this file, so the two can't silently drift
past what's actually running).

Reviewed against every script that writes `prds.<slug>.status` as of
2026-09-09: `scan-prds.sh`, `manifest-set.sh` (generic writer — never itself
decides a transition, just applies whatever patch a caller built),
`manifest-reconcile.sh`, `lane-claim.sh` (writes the PRD file's own
`Status:`/`Lane:` lines, not `manifest.json`, but that value is what
`manifest.json` mirrors once a branch acts on the claim), `clear-stale-blockers.sh`
(blocker-list surgery, absorbed into `manifest-invariants.sh` by this PRD —
see "Absorbed scripts" below), and the Phase 4 `archive` action in `SKILL.md`.

## The nine required statuses (PRD requirement 1)

### `queued`

The ground state: selectable by Phase 2, re-enterable from almost anywhere.

- **Predecessors:** new PRD discovery (`scan-prds.sh`); `blocked` healed
  (empty `blockers[]` AND empty `iter_log` — this PRD's central heal);
  `needs_classification` healed (the file now passes `prd-lint.sh` — subsumes
  the 2026-09-09 1e9af92 one-instance fix); `vanished` (file reappears before
  the 7-day grace period — `manifest-reconcile.sh`). **Never** from `archived`
  (see that status's Successors — a hard non-transition).
- **Successors:** `building` (`lane-claim.sh claim` wins the push race);
  `in_progress` (a Phase 4 branch starts a step directly, bypassing the
  claim protocol on lanes that don't use it); `blocked` (a step fails with a
  named blocker); `needs_classification` (`scan-prds.sh`'s `prd-lint.sh` gate
  fails the file on (re-)scan).
- **Writers:** `scan-prds.sh`, `manifest-reconcile.sh` (file/dir wins over a
  stale cache value), `manifest-invariants.sh` (heals), Phase 4 branches via
  `manifest-set.sh`.
- **Inverse:** N/A — `queued` is the state everything else inverts back to.

### `building`

A lane holds a push-won claim: `Status: building` + `Lane: <host> <ts>
[pid=<n> boot=<id>]` written into the **PRD file's own frontmatter** by
`lane-claim.sh claim`; `manifest.json`'s cached `status` mirrors this once a
branch acts on it.

- **Predecessors:** `queued` (`lane-claim.sh claim` — push-wins over other lanes).
- **Successors:** `in_progress` (the branch proceeds past the claim into an
  implementation step); `queued` (claim released — `lane-claim.sh release` —
  or reclaimed by another lane once stale); `blocked`.
- **Writers:** `lane-claim.sh` (the PRD file's `Status:`/`Lane:` lines —
  `manifest.json` is a mirror, not the source, for this one); Phase 4
  branches (`manifest.json`, via `manifest-set.sh`).
- **Inverse:** `lane-claim.sh release`, or another lane's `claim` once the
  claim is stale (age ≥ 3h, or the coordinator is confirmed gone — see
  `lane-claim.sh`'s `coordinator_gone`). **This is the one inverse this PRD
  does NOT auto-heal**: which lane resumes a dead claim is a *selection*
  decision (`lane-predicate.sh` / `lane-claim.sh target-busy`'s own-claim
  exemption), explicitly out of `manifest-invariants.sh`'s scope per the
  PRD's Non-goals ("no changes... to selection logic"). Instead
  `manifest-invariants.sh` **alarms** (`manifest-invariant-stale-claim`) so a
  human or the next tick's selection sees it — see "Alarms" below.

### `in_progress`

An atomic step landed but the PRD isn't done — the mid-chain state.

- **Predecessors:** `building`, `queued` (Phase 2 bucket-1 continuation, lanes
  that skip the claim protocol), `in_progress` (the previous chained step).
- **Successors:** `in_progress` (next chained step, `chain-guard.sh` said
  `continue`); `blocked` (a step fails and names a blocker); `shipped` (the
  final `archive` action's checks all pass); `needs_classification` (a step
  discovers a structural PRD defect mid-build, rare but possible if the file
  was edited after the initial lint pass).
- **Writers:** Phase 4 branches via `manifest-set.sh`.
- **Inverse:** none forced by this PRD — an `in_progress` entry with no
  activity for 24h is **alarmed** (`manifest-invariant-stale-activity`), not
  auto-healed back to `queued`: whether a stalled chain's partial work should
  be discarded is a judgment call, not a mechanical one (Non-goal: this PRD
  changes no status's meaning).

### `blocked`

A step failed and recorded one or more blockers.

- **Predecessors:** `in_progress`, `building`.
- **Successors:** `queued` (heal, requirement 2a: `blockers[]` AND `iter_log`
  both empty — the mis-park trap this PRD closes: `self_build_blocked_empty_blockers`);
  `in_progress` (the same writer that set a blocker clears it once the fix
  lands — ordinary forward progress, not a reconciler concern).
- **Writers:** Phase 4 branches (a gate/step failure names the blocker);
  `manifest-invariants.sh` clears **stale version-collision** blockers of the
  form `vX.Y.Z collision with <slug>` once at most one of the two PRDs still
  claims that version in a phasing header (absorbed from
  `clear-stale-blockers.sh` — see "Absorbed scripts").
- **Inverse:** `queued` (mechanical heal, empty-blockers+empty-iter_log) or
  `in_progress` (ordinary unblock, not this script's concern).

### `shipped`

Set the instant the `archive` action's verified-completed checklist AND gate
pass — a manifest-only marker, written in the same action that is *about* to
`git mv` the file into `built-prds/` and rewrite the PRD's own `Status:` line
to `built`. Normally lives for milliseconds.

- **Predecessors:** `in_progress`.
- **Successors:** `archived` (the same `archive` action's git-mv-and-commit,
  immediately after).
- **Writers:** Phase 4 `archive` action, via `manifest-set.sh`.
- **Inverse:** none — this PRD does **not** attempt to complete a stalled
  `git mv` on the manifest's behalf (that is a git-write action, out of a
  pure manifest auditor's scope). Instead, `shipped` (or `built`, see below)
  whose file is STILL under `build-queue/` after the alarm threshold is
  **alarmed** (`manifest-invariant-shipped-not-archived`) so a human or
  `archive-finalize.sh` can finish the job. The exact threshold N is an open
  question in the PRD (measure a week of normal lag); `manifest-invariants.sh`
  defaults to `SHIPPED_NOT_ARCHIVED_MINUTES=20` (roughly 4 ticks at the
  5-minute cadence), overridable via that env var, pending the measurement.

### `built`

The PRD **file's own** `Status:` line value once shipped (`Status: built` +
`Built: <date>`), written by the same `archive` action, immediately before
its `git mv`. If a manifest entry ever shows `status: built` (rather than
`shipped`) it is the exact same in-flight moment as `shipped` above, just
observed after the frontmatter rewrite and before the directory move landed.

- **Predecessors:** `shipped`.
- **Successors:** `archived`.
- **Writers:** Phase 4 `archive` action (PRD file frontmatter; rarely mirrored
  into `manifest.json` directly).
- **Inverse:** none — same non-heal reasoning as `shipped`; a `built`-status
  entry whose file is still in `build-queue/` past the threshold folds into
  the identical `manifest-invariant-shipped-not-archived` alarm class as
  `shipped`, since both name the same stalled-git-mv condition.

### `archived`

Terminal. The file lives in `built-prds/`.

- **Predecessors:** `shipped` / `built`.
- **Successors:** **NONE** — never re-queued. `scan-prds.sh`'s hard
  pre-filter and Phase 2's hard pre-filter both enforce this independently of
  the manifest cache (a PRD absent from `build-queue/` and present in
  `built-prds/` is forced to `archived` on sight, `manifest-reconcile.sh`
  never lets a directory-derived `archived` verdict get overridden).
- **Writers:** `manifest-reconcile.sh` / `scan-prds.sh` (directory-derived —
  a manifest entry whose scan path contains `/built-prds/` is always
  `archived`, full stop); Phase 4 `archive` action.
- **Inverse:** deliberately **none automated**. The sole way an archived PRD
  builds again is a **human** moving the file back out of `built-prds/` — at
  which point `manifest-reconcile.sh` (not `manifest-invariants.sh`) treats
  it as a "human un-archive" and nulls `verified_completed`. No script in
  this fleet re-queues an archived PRD on its own initiative; that guardrail
  predates this PRD and is unchanged by it (Non-goal).

### `parked`

A human decision, not a machine one.

- **Predecessors:** any status — a human moves the file to `parked/` from
  wherever it was.
- **Successors:** any status — a human moves the file back out; un-parking
  is exclusively human, never a script.
- **Writers:** humans, via file placement. `scan-prds.sh` /
  `manifest-reconcile.sh` mirror the directory into `status: parked` as a
  read-only observation of that human decision; neither script, nor
  `manifest-invariants.sh`, ever *causes* a `parked` transition.
- **Inverse:** human un-park. **`manifest-invariants.sh` MUST NOT heal or
  alarm a `parked` entry under any condition** (requirement 4 / AC4) — even
  one that would otherwise match a heal rule (e.g. `blocked` + empty
  blockers) is left untouched and silent if its status happens to read
  `parked` (parked always wins; a parked PRD's OTHER fields are frozen along
  with it, by design — the human parked the whole PRD, not just its status
  label).

### `needs_classification`

A structural PRD defect (a `prd-lint.sh` failure, or Phase 3 classification
ambiguity) blocks selection until fixed.

- **Predecessors:** `queued` (`scan-prds.sh`'s `prd-lint.sh` gate); `in_progress`
  (Phase 3 hits an ambiguous shape mid-build, rare).
- **Successors:** `queued` — **the heal this PRD adds** (requirement 2b): once
  the PRD file passes `prd-lint.sh` again, `manifest-invariants.sh` clears
  `needs_classification_reason` and re-queues it. Before this PRD, this
  transition **did not exist as an automated heal** — it was a one-way trap
  fixed only by hand (the 2026-09-09 incident this PRD's Problem statement
  opens with; a human had to notice and re-run the equivalent of this heal
  by hand, twice, for two different lint-passing PRDs).
- **Writers:** `scan-prds.sh` (writes `needs_classification_reason` alongside
  the status), Phase 3 (classification ambiguity), `manifest-invariants.sh`
  (the heal).
- **Inverse:** `queued`, as above. This is the PRD's flagship example: a
  punish-without-heal transition existing for months before a human found it
  by journal archaeology.

## Auxiliary statuses (present in the fleet, out of this PRD's heal/alarm scope)

These two are real, in-use statuses that predate this PRD and already have a
single owning script covering their full lifecycle including any inverse —
`manifest-invariants.sh` recognizes both (so it never flags them as
"unknown") but performs no heal or alarm logic of its own for either; folding
them in here would duplicate, not improve, an already-complete owner.

### `vanished`

File gone from both `build-queue/` and `built-prds/` (and not `parked`).

- **Predecessors:** any.
- **Successors:** entry hard-deleted after a 7-day grace period, OR `queued`
  if the file reappears before the grace period elapses.
- **Writers / owner:** `manifest-reconcile.sh` exclusively — it already owns
  both the forward transition (marking `vanished`) and the inverse
  (reappear → `queued`, or grace-period expiry → delete). Not a
  `manifest-invariants.sh` concern.

### `notebook`

A doctrine/process PRD with no concrete build (Phase 3 classification).

- **Predecessors:** `queued`.
- **Successors:** terminal in practice (there is no code to build); a human
  can still re-queue by editing the PRD's `build_target`.
- **Writers / owner:** Phase 3 classification. A human decision embedded in
  the PRD's own `build_target`, same spirit as `parked` — not a
  `manifest-invariants.sh` concern.

## Heals (mechanical, requirement 2)

Applied under `tick.lock`, via `manifest-set.sh` (so each heal is its own
atomic manifest rename), and logged to a per-entry `invariants_audit_log`
array (mirroring `blockers_audit_log`'s existing shape) naming the rule that
fired, the `from`/`to` status, and a UTC timestamp:

| rule | condition | action |
|---|---|---|
| `blocked-empty-blockers-empty-iterlog` | `status: blocked`, `blockers` empty/absent, `iter_log` empty/absent | → `queued` |
| `needs-classification-lint-pass` | `status: needs_classification`, `prd-lint.sh <file>` now exits 0 | → `queued`, `needs_classification_reason` cleared |
| `stale-version-collision-blocker` | a `blockers[]` entry matches `vX.Y.Z collision with <slug>` AND at most one of the two PRDs' texts still claims `vX.Y.Z` in a `**N (vX.Y.Z):**`-style phasing header (identical condition to the retired `clear-stale-blockers.sh`) | that one blocker entry removed from `blockers[]`; if the array becomes empty AND `iter_log` is also empty, the row above then fires on the *same* pass |

`parked` entries are skipped before any rule is evaluated (requirement 4 /
AC4). An entry whose `status` is not one of the statuses named above (known
or auxiliary) is never healed — see "Alarms" below.

## Alarms (requirement 3)

Written to the day's build journal AND, when the `docket` binary is on
`$PATH`, reported via `docket report --key manifest-invariant-<class> ...`
(fail-open: `docket` absent, or any `docket` invocation error, degrades to
"journal-only", never blocks or fails the run). Alarms never mutate the
manifest.

| class (`manifest-invariant-<class>`) | condition |
|---|---|
| `stale-claim` | the PRD file carries a claim (`lane-claim.sh status <path> --json` → `claimed: true`) that script's own `stale` verdict marks stale (age ≥ 3h, OR the coordinator is confirmed gone via PID+boot-id — see `lane-claim.sh`'s `coordinator_gone`) |
| `shipped-not-archived` | `status` is `shipped` or `built` AND the PRD file is still found under `build-queue/` AND `last_action` is older than `SHIPPED_NOT_ARCHIVED_MINUTES` (default 20; the PRD's own Open Questions table leaves the exact N to a week of measurement) |
| `unknown-status` | `status` is not one of the eleven statuses in this document |
| `stale-activity` | `status` is `building` or `in_progress` AND neither `last_action` nor any `iter_log` entry falls within the last 24h |

## Absorbed scripts

`clear-stale-blockers.sh`'s audit role (stale version-collision blocker
clearing) is now performed by `manifest-invariants.sh`'s
`stale-version-collision-blocker` heal, using the identical condition
(`collision_re` match + `phasing_claims` count ≤ 1). `clear-stale-blockers.sh`
itself is left in place (self-review may still invoke it directly without
harm — its logic is now duplicated, not removed, to avoid a hard cutover in
the same change that ships the new path) but `/self-review`'s Phase B.5
`build_stale_blockers` playbook is retired: this table + one
`manifest-invariants.sh --report` reading replaces it (PRD user story 3).

## Non-goals reaffirmed

This document describes the machine that exists; it does not change what any
status *means*, nor any selection-logic predicate (`lane-predicate.sh`,
`chain-guard.sh`, `select-guard.sh` are unaffected). It is not a general
workflow engine — new statuses are still hand-added here and to
`KNOWN_STATUSES` in `manifest-invariants.sh` together, by a human PRD, the
same way every other status in this file arrived.
