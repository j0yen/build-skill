# History

Dated incidents and rationale, moved out of `SKILL.md` and
`docs/branch-contract.md` so neither has to carry them in the hot path.
Every entry below is headed with its date and originating PRD slug (P1
requirement 6) so `git log -S` and `scripts/lint-contract-size.sh`'s
sibling link-lint can trace it back. `docs/branch-contract.md` links here
by anchor (`see history.md#<anchor>`) instead of inlining any of this.

## branch-prompt-origin — 2026-09-18, PRD-build-branch-contract-split

The branch prompt used to be composed by the coordinator by copying
paragraphs out of `SKILL.md`'s "Dispatch" section (`## Parallelism` →
`### Dispatch` → "Each agent prompt must include, self-contained"). No
template file existed — `grep -rl 'You are advancing ONE PRD'` hit
`SKILL.md` only, and 249 coordinator ticks on 2026-09-17 each re-read the
whole 3,651-line file to reconstruct it. `docs/branch-contract.md` is now
that template, numbered and capped.

## lock-holder — 2026-09-15, PRD-build-tick-lock-held

Two coordinators ran concurrently on RedBaron for hours on 2026-09-15
because a `flock -n tick.lock` taken inside one Bash tool call is released
the instant that call returns. `tick.lock`'s lifetime is now tied to the
coordinator PROCESS via `scripts/tick-run.sh`, which opens it on a fixed
fd and execs the coordinator with that fd still open. A branch's own
per-PRD lock (`state/prd-<slug>.lock`) follows the same discipline: one
`flock -n` before any mutation, held for the branch's whole life.

## worktree-isolation — 2026-09-10, PRD-build-python-worktree-isolation

Two same-lane python-agent PRDs (`synthorg-run-telemetry`,
`synthorg-capability-tasks`) collided writing `src/synthorg/cli.py` in a
shared main checkout on 2026-09-10 — only the rust-extend/kernel-extend
paths had a worktree-isolation mechanism at the time. `scripts/
worktree-extend.sh add`/`land` closed the gap for python, then
(2026-09-15, PRD-build-shell-worktree-isolation) for shell/hooks/config
PRDs sharing a `build_into` too.

## cargo-lane — 2026-09-02, project convention

RedBaron is the fleet's Rust build machine (i7-11700KF, 16 threads, 30
GB, sccache + mold). User instruction 2026-06-16, reaffirmed 2026-09-02:
a silent local cargo build on any other lane is not allowed — every cargo
invocation routes through the shim to RedBaron. Measured 2026-09-01: a
clean release build of `recall` took 79s on RedBaron. The Hetzner burst
box was retired 2026-09-01; Wintermute Hub (the NATS box) builds nothing.

## cargo-budget — 2026-09-09, PRD-build-cargo-concurrency-budget

RedBaron OOMed for ~6 minutes at 06:08Z 2026-09-09 (load average 21,466)
while the same-target sub-cap was only 3 — the sub-cap counted branches,
not what each branch's `cargo test` unleashed underneath it.
`scripts/cargo-budget.sh` now enforces a host-wide concurrency budget
(counting semaphore, memory floor, load ceiling on RedBaron) that every
cargo-running branch must route through.

## burst-lane — 2026-09-11, PRD-build-burst-lane-ccx53

Requirement 4 (rust) and requirement 12 (python) added an opt-in Hetzner
CCX53 burst lane, gated on `burst_configured()` so the RedBaron-local
default carries zero behavior change when burst is not configured.
Requirement 13 added per-session cost reporting
(`burst-lane.sh cost --today`); PRD-build-cost-attribution (2026-09-10)
added per-slug attribution on top of the per-session total.

## operator-authorization — 2026-09-14, PRD-build-operator-authorization-contract

Five-whys in `visions/buildloop-operations.md`: a branch agent deferred an
in-scope, operator-authorized AC on its own risk judgment, and the
identical text was honored one tick earlier by a different branch —
neither outcome reflected a rule the loop enforced, because a PRD-carried
`Operator-authorization:` line was inert prose until this PRD gave the
contract a key for it.

## manifest-set — 2026-06-02, PRD-build-durable-manifest-write (gotcha noted 2026-09-03)

Before `scripts/manifest-set.sh`, branches hand-rolled lock + read-modify-
write logic against `manifest.json`, which is exactly the kind of thing
that races. The one gotcha (hit by `scripts/manifest-reconcile.sh` on
2026-09-03): the patch argument is always a path to a JSON file, never an
inline JSON string.

## verdict-receipts — PRD-build-verdict-receipts

Before this PRD, a NOT-ARCHIVED or blocking verdict citing test failures
could be written off a single run — a scheduler hiccup cost a blocked PRD
and a human escalation instead of one re-run. The reserved words
(`bisected`, `reproducible`, `flaky-infra`, `unreachable`, `SSH timeout`)
close the same gap a sandboxed shell has for branding a healthy host
unreachable off one probe from a degraded context.

## in-tick-chaining — 2026-09-09, PRD-build-chained-tick-actions

Operator authorization, Joe, verbatim: "does it have to be one action per
PRD for tick? Can we expand thsis?" (expand it), and on a chain cap, "no,
no chain cap" — superseding an earlier "can it do 10 per branch?" Before
this PRD, the 5-minute tick timer was the only thing that let a green PRD
advance to its next lifecycle step; a PRD needing N sequential steps paid
up to N tick boundaries even when every step's preconditions already held
the moment the prior step committed.

## lane-tagged-journal — 2026-09-06, PRD-build-second-lane-carbon

Before this PRD, the journal had no way to say which of two lanes (RedBaron,
carbon) built a given PRD when both shared one PRD clone. The `lane=`
key/value tail field answers "who built this" without cross-referencing
every branch line against `Lane:` frontmatter.

## coordinator-message-distrust — PRD-build-coordinator-message-distrust

A branch agent used to treat any message arriving mid-Phase-4 as
authoritative — including a claimed gate state, a stop instruction, or a
scope-widening request — without re-running the check the message claimed
the result of. This directive makes the branch re-verify independently
and log both the claim and the verdict, whichever way it comes out.

## run-pin — 2026-09-15, PRD-build-select-tick-run-pin

Grounded in a 2026-09-15 21:24Z tick that admitted 5 PRDs by priority and
ignored all 5 pinned slugs in the run list with no journal line, and a
22:23:55Z tick where the coordinator called `select-guard.sh` itself for
each pinned slug — a forbidden second selection wave. `run <slugs>` now
resolves inside `select-tick.sh`'s one call; the coordinator never sees
the slug list and never calls a guard itself.

## tick-lock-held — 2026-09-15, PRD-build-tick-lock-held

Requirement 6: a hand-run `claude -p /build` or `systemd-run ... claude -p
/build` bypasses `tick.lock` entirely — exactly how the 2026-09-15
concurrent-tick incident happened. `claude-build-headless.sh` is the one
manual path that routes through `claude-build-tick.sh` → `tick-run.sh`,
which holds the lock for the coordinator's whole life.

## unit-liveness — 2026-09-11, PRD-buildloop-unit-liveness

A bare `systemctl --user enable --now` by hand left
`claude-vibeloop-measure.timer` inactive for 29 hours after a restart,
unnoticed, because the operator only re-enabled the units they
remembered to name. `loop-arm.sh` reads the full declared set from
`scripts/loop-units.txt` and verifies every one came back.

## outcome-liveness — 2026-09-18, PRD-buildloop-tick-outcome-liveness

Units stayed `active` through fifteen consecutive failed ticks on
2026-09-18 — "the unit is active" and "the loop is building anything"
are different claims. `tick-outcome.json` plus `lib/tick-cause.sh`
(`auth-expired` / `quota-saturated` / `other`) closes the gap; AC16's
drill (`loop-arm-drill.sh`) proves the auth-expired path against the real
`claude` binary rather than a fixture coordinator, and (same day) was
fixed to own `tick.lock` for its whole span after ten consecutive
dispatches lost the drill's own lock race to the very tick it was trying
to test against.

## auto-publish-uncapped — 2026-05-25 / 2026-05-27 / 2026-05-30, user instruction

Auto-publish became the default with no opt-outs and no daily caps
(2026-05-27): `build_auto` is no longer parsed, every PRD is treated as
auto-buildable, and external mutations (new repo creation, push,
settings.json edits, hook installs, follow-on PRD commit+push) are all on.
Budget caps were set to null the same window (`caps[k]` always null,
`used[k]` telemetry-only, per user instruction 2026-05-30). The blanket
"defer while an interactive session is live" guard was removed 2026-05-25
per user request — ticks now coexist with live terminals; `tick.lock` plus
one-action/chained-step-at-a-time are the only guardrails. If file-write
races with an interactive user are observed in practice, add a per-repo
flock around the Phase 4 action rather than reinstating the blanket guard.

## publish-authorization-scope — 2026-05-25 / 2026-05-27 / 2026-05-30 / 2026-08-03, user instruction

The no-operator-confirm publish authorization (private `j0yen/<slug>` repos
by default, public only when the PRD says `publish: j0yen/public`,
`~/.local/bin` installs, `~/.claude/scripts/` hook symlinks,
`~/.claude/settings.json` edits with timestamped backups, follow-on PRD
authorship) was granted 2026-05-25, expanded 2026-05-27, reaffirmed
2026-05-30, then re-scoped to AtScale-primary on 2026-08-03 (see
`atscale-retired` below for what "AtScale-primary" meant before the org
itself was retired).

## fan-out-cap-growth — 2026-05-28 / 2026-05-29 / 2026-06-11, user instruction

The per-tick parallel-dispatch cap grew three times on user instruction:
1 → 5 (2026-05-28, "this laptop can handle it"), 5 → 10 (2026-05-29), then
10 → 30 (2026-06-11) — 30 is the default `BUILD_MAX_BRANCHES` fan-out
today, overridable per-host (PRD-build-max-branches-cap, 2026-09-11) for a
lane that needs a lower ceiling. See "Parallelism" in `SKILL.md`.

## worktree-conflict-root-cause — 2026-06-06, project incident

The 2026-06-06 conflict (3 of 6 branches deferred to the same
`build_into`, all landing in the same window) is the incident that
motivated worktree isolation for shared-target branches — see
`worktree-isolation` above for the mechanism it led to.

## rebuild-gate-ported — 2026-08-03, gap #68 (ported from ryzen7)

The rebuild gate (`scripts/archive-rebuild-gate.sh`) was ported from
ryzen7 on 2026-08-03: a re-queued PRD (`manifest.revision > 1`, e.g. a
dreamer reconciliation caught a false-ship) must prove it actually
advanced the work — bump the crate strictly past `last_shipped_version`,
prepend a matching `## v<new-version>` CHANGELOG section, and record a
non-empty `rebuild_reason` — before archive is allowed. The legacy
`commit-reachable`/`changelog-v<X>-exists` checks alone are satisfiable by
the *prior* ship's stale artifacts, which is the gap this closed.

## atscale-retired — 2026-08-18 / 2026-08-27, project milestone

The AtScale org (`joeyen-atscale`) was retired 2026-08-18, with access
gone by 2026-08-27; every remaining AtScale-era PRD in this workspace is
historical. Never publish, push, or `gh repo view` against that org —
`j0yen/<slug>` (private by default) is the publish target since.

## manifest-reconcile-and-lint-gate — 2026-09-04, PRD-build-manifest-reconcile / PRD-build-prd-lint

`scripts/manifest-reconcile.sh` (also reachable as `scan-prds.sh
--reconcile`) landed 2026-09-04 to patch `manifest.json`'s cache back to
what the PRD files and directory placement actually say before Phase 1's
scan-vs-manifest diff runs — a PRD `built` in the file and `queued` in the
cache, or `shipped` in the cache while still sitting in `build-queue/`,
had each cost a cycle or a human the day before. The same date landed the
lint gate: `scan-prds.sh` runs `scripts/prd-lint.sh` over every
`build-queue/` PRD first, routing a contract-shape failure straight to
`needs_classification` before it ever reaches the Phase 2 candidate pool.

## intent-card-refresh-incident — 2026-09-05, PRD-build-intent-card-refresh

An extend ship that never touches `agent/intent-card.json` leaves it
describing whatever PRD last refreshed it. On mcphost, 2026-09-05, a card
frozen since v0.5.x blocked two routinely-shipped heads in one night
(`intent-card-diff-scope-mismatch`) while six PRDs and eight version bumps
had landed underneath it unnoticed. `intent-card-refresh` now runs after
changelog & install, before push, for every rust-extend ship.

## dispatch-boundary-and-worktree-targets — 2026-09-08, PRD-build-select-target-busy-unskippable / PRD-build-lane-roster-ryzen7 / PRD-build-worktree-targets-off-root

Three unrelated fixes landed the same day. (1) `select-guard.sh
<slug> [lane] [prd-dir] <branch-count> [admitted-targets]` became a
required, unskippable call immediately before every Agent/Task dispatch —
closing a target-busy race a coordinator could otherwise sidestep by
composing the check differently each time. (2) the cargo-free lane roster
(`CARGO_FREE_LANES`, today just `carbon`, 15 GB RAM / 0 swap) restricted
that lane to non-cargo `build_target`s, added for ryzen7's own onboarding.
(3) rust worktree `target/` dirs (50G+ each) moved off the root
filesystem to `$BUILD_TARGET_ROOT`/`/mnt/data/jsy/cargo-targets` — two
landed-but-uncleaned worktrees had filled `WT_ROOT` on the root filesystem
to 100% and killed two truth-tier measure runs that day.

## classification-bounce-and-loop-arm — 2026-09-12, PRD-build-classification-self-heal / PRD-buildloop-unit-liveness

`classification-self-heal.sh bounce-check` landed 2026-09-12 to stop a
`needs_classification` PRD from bouncing back to `queued` on a diagnosis
that hadn't actually changed, alarming on a second identical bounce
instead of silently re-admitting it a third time. The same date,
`loop-arm.sh` became the only arming step for the buildloop's systemd
units (reads `scripts/loop-units.txt`'s declared per-host set, enables
`--now` exactly those, verifies with `loop-liveness.sh`) — a restart that
silently dropped one unit had gone unnoticed for 29h before this.

## mid-september-incident-cluster — 2026-09-13, PRD-build-gate-before-land / PRD-build-selector-honors-priority / PRD-build-tenant-secret-continuity / burst-lane incident

Several 2026-09-13 fixes: (1) the mcphost-agent-consent incident — a
hand-resolved "missing" Depends-on that was, in the same commit, sitting
right in `build-queue/` — closed the loophole letting an agent resolve a
dependency name by hand instead of through `prd-lint.sh`'s verdict. (2)
`select-tick.sh`'s priority-then-path ordering became real (previously
aspirational prose). (3) shared-target gate wall time (332s-3864s
observed) held the crate's integration lock because the gate's producers
wrote into the main checkout's shared receipts dir — moving receipts
per-branch let `gate-before-land` stop capping same-target admission at 1
purely for that reason. (4) a dead `prove` process's pid on `burst-lane.sh`'s
`up.lock` refused every retry until locks were tied to the owning process
exiting, not a disowned child outliving it. (5) PRD-build-tenant-secret-continuity:
a dispatch that mints a credential a later dispatch needs (that day, an
mcphost.dev tenant key) and holds it only in-process memory loses it the
instant the process exits — read-only DB inspection confirmed the key was
gone for good, non-reversibly hashed server-side.

## under-dispatch-ledger-and-cross-repo-gate — 2026-09-16, PRD-build-tick-under-dispatch-ledger / PRD-build-cross-repo-commit-gate

`select-tick.sh` started persisting its own `admitted[]` result to
`state/select-tick/<tick-id>.json` so `tick-run.sh` could compare it
against real dispatch evidence itself, instead of relying on the
coordinator noticing and narrating its own deviation — a 21:24Z tick that
admitted 5 and worked 3 had written nothing at all under the old,
honesty-dependent scheme. The same date's grounding incident: a
build-skill shell PRD wrote `.buildloop/ci-equivalent.toml` straight into
mcphost, landed through a green-CI PR, and reds every mcphost branch's
vti-plan because the commit was unrouted in `agent/proof-lanes.toml` — the
`gated-targets.sh is-gated` check before any cross-repo write traces to
this.

## test-isolation — 2026-09-15, PRD-build-test-isolation-by-default

A bare `*-selftest.sh` invocation (bypassing `run-selftests.sh`) leaked
fixture-shaped lines straight into the real production journal. The
runner now sets `BUILD_TEST_ROOT`/`BUILD_TEST=1` and redirects `HOME` and
every state dir into a temp root before any test runs; `journal.sh`'s
`journal_line` additionally refuses (exit 3) a fixture-shaped line aimed
at the unmodified production root even if isolation was somehow skipped.

## reviewer-auth — 2026-09-18, PRD-build-reviewer-agent-auth-contract

Claude Code strips `CLAUDE_CODE_OAUTH_TOKEN` from Bash-tool children, so
the reviewer's nested `claude -p` (spawned from inside a branch agent's
own Bash tool) never had it in `extend-gate.sh`'s ambient environment and
always fell through, silently, to the file fallback
`~/.claude/.credentials.json` — a copy nothing refreshes since the
12:07 am setup-token-in-environment.d migration. Its access token expired
at 7:51 am EDT on 2026-09-18; every gate on a Rust target ran its full
24-receipt sequence (~276 s), then the reviewer failed in 1–2 s with
`Failed to authenticate: OAuth session expired and could not be
refreshed` — printed on stdout, not stderr, so the receipt's own
`infra_detail` read `stderr_tail=<empty>` and nobody could tell it was an
auth failure from the receipt alone. `run_reviewer` now resolves the
token from a named source (env, then `REVIEWER_AUTH_FILE`, then
`systemctl --user show-environment`), hands it to the `claude -p`
invocation's own environment only (never exported into this script's
shell), and a branch-scope (or pinned-landing) gate probes it once before
any receipt producer runs — a missing token ends the gate
`incomplete infra=reviewer-agent:auth-missing` in well under the 276 s the
old failure cost, naming every source checked, before paying for a single
receipt.
