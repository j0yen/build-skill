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

## test-isolation — 2026-09-15, PRD-build-test-isolation-by-default

A bare `*-selftest.sh` invocation (bypassing `run-selftests.sh`) leaked
fixture-shaped lines straight into the real production journal. The
runner now sets `BUILD_TEST_ROOT`/`BUILD_TEST=1` and redirects `HOME` and
every state dir into a temp root before any test runs; `journal.sh`'s
`journal_line` additionally refuses (exit 3) a fixture-shaped line aimed
at the unmodified production root even if isolation was somehow skipped.
