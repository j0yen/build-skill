# Operator manual

Runbooks for Joe. `docs/branch-contract.md` is what a dispatched branch
reads; this file is what a human reads to drive the loop. Dated rationale
lives in `docs/history.md`, linked from here where relevant.

## Manual invocation

- `/build` → run one tick (same as the timer), inside an already-running
  interactive Claude session.
- `/build status` → dump manifest as a human-readable table; exit.
- `/build run <slug...>` → a pin, not an instruction to the coordinator.
  `tick-run.sh` derives `--pin <slug,...>` from this text before it ever
  execs the coordinator (space- or comma-separated, both resolve
  identically) and forwards bare `/build` (no slug list) unchanged. A
  pinned slug that survives the hard pre-filter and Depends-on gate is
  admitted first, ahead of continuations and the priority sort — a pin
  skips the queue, never the safety checks (cap, same-target,
  lane-predicate). See history.md#run-pin.
- `/build pause` → write `state/paused` sentinel; the timer's next fire
  exits immediately. `/build resume` clears it.

**Headless/out-of-session manual batch — the ONLY manual path for
starting a tick from outside a live session:**

```
BUILD_TICK_ARGS="run <slug...>" ~/.local/bin/claude-build-headless.sh
```

`BUILD_TICK_ARGS` is the one knob (`run <slug>`, `status`, etc.) —
everything else is identical to the timer's own path. Do NOT hand-run
`claude -p /build` or `systemd-run ... claude -p /build` directly: that
bypasses `tick.lock` entirely. See history.md#tick-lock-held.

## Re-arm / pause / resume

```
systemctl --user disable --now claude-build.timer   # stop
scripts/loop-arm.sh                                  # re-arm
```

`loop-arm.sh` is the only arming step for the buildloop's units, on any
host — it enables+starts every unit this host declares in
`scripts/loop-units.txt`, then verifies with `scripts/loop-liveness.sh`
and prints its table, exiting non-zero if anything is still inactive. Do
NOT `systemctl --user enable --now` a unit by hand for a full restart —
see history.md#unit-liveness for why. `scripts/loop-liveness.sh --digest`
shows only units that stayed inactive across ≥2 consecutive checks; it
never calls `systemctl` and is safe to run any time.

**Outcome liveness (distinct from "the unit is active")**: a declared
unit staying `active` is not the same claim as the loop building anything.
`scripts/tick-run.sh` writes `$BUILD_STATE_DIR/tick-outcome.json` on every
exit; `scripts/loop-liveness.sh`'s plain-mode summary reads it and prints
`LIVENESS ok n=<N> last_ok_age=<s> streak_failed=<n>` or `LIVENESS
degraded cause=<cause> streak=<n>`. See history.md#outcome-liveness.

**Auth-expired drill (operator-run only, never called from a tick)**:

```
scripts/loop-arm-drill.sh            # foreground, waits on tick.lock
scripts/loop-arm-drill.sh --detach   # backgrounds via systemd-run --user
scripts/loop-arm-drill.sh --resolve-now  # run one real tick immediately after
```

Points the real `claude` binary at a throwaway `HOME`/OAuth token (never
touches this host's real credentials), runs three ticks, and asserts the
alarm path fires. Forces `NOTIFY_CMD=true` so a drill never files a real
alert. Run once per drill need — restoring afterward is automatic.

## Second-lane install (carbon)

Carbon runs the same tick scripts as RedBaron unmodified (the lane comes
from `hostname`, not a fork) — enabling the second lane is a carbon-local
systemd install, done once:

```
bash ~/.claude/skills/build/scripts/carbon-lane-install.sh   # dry-run: append --dry-run
systemctl --user daemon-reload
bash ~/.claude/skills/build/scripts/loop-arm.sh
```

`carbon-lane-install.sh` only symlinks unit files into
`~/.config/systemd/user/` — it never enables/starts/reloads anything, and
is a no-op when already in sync. RedBaron needs no equivalent step; its
units already live in `~/dotfiles`.

## Burst configuration

Cargo (and sandbox-safe python test suites) run locally on RedBaron by
default. Opt into the Hetzner CCX53 burst lane by setting
`BUILD_BURST_ENABLED=1` or populating `~/.config/wm-burst/.env` — when
neither is set, no branch prompt mentions burst routing at all.

```
scripts/burst-lane.sh status              # is a session up
scripts/burst-lane.sh up                  # provision (money-spending; needs Operator-authorization)
scripts/burst-lane.sh down                # tear down, keep the sccache volume
scripts/burst-lane.sh down --force        # tear down AND delete the volume
scripts/burst-lane.sh cost --today        # euros/hours today, by slug or session
scripts/burst-lane.sh cost --by-prd [--today|--session <id>]
```

`up`/`prove`/`bake` are money-spending and record + require an
`Operator-authorization:` string — see `docs/branch-contract.md` §4. See
history.md#burst-lane for the incident this gating traces to.

## Status commands

- `scripts/tick-run.sh --status` → last tick's admitted/dispatched/missing
  slugs, plus the current lock holder's pid/age/cmdline (or `free`).
- `scripts/lane-status.sh report` → both lanes' last-tick contribution,
  live claims, stale claims.
- `scripts/manifest-invariants.sh --report` → read-only manifest audit
  (never mutates); what `/self-review` Phase A reads.
- `scripts/select-tick.sh --explain <slug>` → why a PRD was or wasn't
  picked this tick, without reading the coordinator's own narration.
- `scripts/handoff-header.sh` → the current `GATES(<h>h): green=<n>
  red=<n> ...` line — put this as the FIRST line of any handoff memory.
- `scripts/day-ledger.sh [--date YYYY-MM-DD] --format text` → one day's
  ticks/gates/shipped/landings/decisions/burst, no scout needed.

## Selftests

`scripts/run-selftests.sh <name...> | --all` is the one selftest
entrypoint — it sets `BUILD_TEST_ROOT` (under `/mnt/data/jsy/tmp`, never
tmpfs), exports `BUILD_TEST=1`, and redirects `HOME`/journal/state dirs
into that temp root before any test runs. Do not invoke a
`*-selftest.sh` or `tests/*.sh` file directly for a real verification
run — see history.md#test-isolation for why that leaked fixture lines
into the real production journal once.
