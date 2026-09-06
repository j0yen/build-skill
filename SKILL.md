---
name: build
description: Continuously implement queued PRDs end-to-end — scan for new PRDs, build them (delegating to /rustbuild for Rust — cargo runs on RedBaron, locally there and remotely from every other node), wire them into the system, publish them as GitHub repos per the PRD's `publish:` key (default `j0yen/private`; the joeyen-atscale route was retired 2026-08-27), update Abouts (per-repo READMEs + wintermute REPOS.md), and draft follow-on PRDs that expand Claude's own capabilities. Rust routes to /rustbuild, Python (`python-*`) to /pybuild. The parsed PRD contract is documented in build-contract.md. Runs on manual invocation or systemd-user timer when enabled; up to 30 PRDs advanced in parallel per tick (one action per PRD). Use when the user says /build, when the SessionStart hook reports a queued PRD, or when the user asks Claude to "make progress on the queue" or "build the next thing."
model: sonnet
---

# /build — continuous PRD implementation loop

`/build` is the autonomous self-extension loop. It looks at the PRDs under
`~/Documents/PRDs/build-queue/` (a clone of `j0yen/prds`, private, shared across
machines — a build started on carbon continues on ryzen7 from the same
frontmatter) and walks each one from "queued" through "shipped" — implementing,
wiring, publishing, documenting, then drafting whatever follow-on PRDs the
experience made obvious. Where a PRD ships is decided by its own `publish:`
frontmatter key, never by which directory it sits in. What `/build` parses from
a PRD is written down once in `build-contract.md` (sibling file); `/dream` reads
that file at run start and writes to it — keep the two in step.

**AtScale org retired (2026-08-18 / 2026-08-27).** Access to `joeyen-atscale`
is gone; every remaining AtScale-era PRD in this workspace is historical. Never
publish, push, or `gh repo view` against that org.

**One workspace (2026-09-02).** Every PRD lives in the `j0yen/PRDs` clone at
`~/Documents/PRDs` (`build-queue/`, `built-prds/`, `parked/`). The former
`~/wintermute/PRDs` queue is gone; its shipped PRDs were folded into
`built-prds/`. Shipped repos live at `~/wintermute/<slug>` (the fleet's repo
root, indexed in `~/wintermute/REPOS.md`). Canonical skill sources are listed
in `README.md` and enforced by `fleet-sync`.

Cadence is **every 5 minutes** (systemd-user timer `claude-build.timer`).
Per tick, the skill advances **up to 30 PRDs in parallel** — one action
per PRD, dispatched as parallel Agent (subagent) tool calls in a single
tool-use message, then collected. The per-PRD one-action invariant is
preserved; only fan-out per tick changed (2026-05-28: 1 → 5; 2026-05-29:
5 → 10; raised by user 2026-06-11: 10 → 30 — **30 is the operative cap, do not
self-throttle below it**). Worst-case blast radius is 30×288 = 8640 small
changes/day, still bounded and each independently revertable. See the
"Parallelism" section for selection, dispatch, locking, and failure
isolation.

**Auto-publish is the default, no opt-outs, no daily caps (updated
2026-05-27).** Every PRD is buildable — `build_auto` is no longer
parsed; the parser treats every PRD as auto-buildable regardless of
frontmatter. Notebook PRDs included. External state mutations (new
GitHub repo creation, push, settings.json edit, hook install,
follow-on PRD commit+push) are all on. Daily budget caps are set to
null (unlimited); `budget.json` still records `used[k]` counters as
telemetry but never blocks an action.

User explicitly authorized (2026-05-25, expanded 2026-05-27, reaffirmed
2026-05-30, re-scoped to AtScale-primary 2026-08-03 — **no operator-confirm
gate: publish autonomously without review. Do NOT set `next: publish-gated`
or wait for confirmation.**):
- GitHub repos under `j0yen/<slug>` — private by default (`publish: j0yen/private`), public only when the PRD says `publish: j0yen/public`,
  the default target as of 2026-08-03 (direct `gh repo create`, no wrapper
  yet — see the publish phase below).
- Public GitHub repos under `j0yen/<slug>` when the PRD says
  `publish: j0yen/public` (via `wm-publish` where installed, else direct
  `gh repo create`).
- `~/.local/bin/` binary install
- `~/.claude/scripts/` hook symlinks
- `~/.claude/settings.json` edits (with timestamped backups)
- Follow-on PRD authorship into `~/Documents/PRDs/build-queue/`
- New tool/mechanism vectors as needed

## Inputs

- **PRDs:** `~/Documents/PRDs/` is a clone of `j0yen/prds` with three PRD
  directories: `build-queue/PRD-*.md` (the buildable queue — the ONLY place
  new work is read from), `built-prds/PRD-*.md` (scanned but already-done —
  never re-queued), `parked/` (never scanned; a human parks and un-parks by
  moving the file). Legacy `ARCHIVE/` / `archive/` directories are read as
  aliases of `built-prds/`. Per-project profiles live in `projects/<name>.md`
  and are `/dream`'s input, not ours. **The PRD's frontmatter is the shared
  state** (`Status`, `Built`, `Blocked`, `Receipts`): any machine with the
  clone can continue; `manifest.json` below is a local cache rebuilt from it.
- **Manifest:** `~/.claude/skills/build/state/manifest.json` — per-PRD
  status, last_action timestamp, blockers, output repo URL when published.
- **Budget:** `~/.claude/skills/build/state/budget.json` — **all budget caps
  removed (uncapped, per user instruction 2026-05-30).** New repos, commits,
  pushes, and follow-on PRDs are unlimited. `used[k]` counters are still
  recorded as telemetry but `caps[k]` are always null and never block an action.
- **Lock:** `~/.claude/skills/build/state/tick.lock` — `flock`-style
  guard so two concurrent ticks never race.

## Phases (each tick)

### Phase 0 — Guard

1. Acquire `tick.lock` with `flock -n`. If already held, exit cleanly:
   another tick is in flight.
2. (Removed 2026-05-25 per user request.) The skill no longer defers
   on active interactive Claude sessions. Ticks coexist with live
   terminals; `tick.lock` plus one-action-per-tick are the guardrails.
   If file-write races with an interactive user are observed in
   practice, add a per-repo flock around the Phase 4 action — do NOT
   reinstate this blanket interactive-session guard.
3. Load `budget.json`. Roll over if `date` ≠ today. All `caps[k]` are
   null (unlimited) per the 2026-05-27 update; `used[k]` counters still
   increment for telemetry. No blocking on any action class.

### Phase 1 — Scan

**Reconcile first (2026-09-04, PRD-build-manifest-reconcile).** Before
diffing anything, run `scripts/manifest-reconcile.sh` (equivalently
`scripts/scan-prds.sh --reconcile`, a passthrough to the same script).
Frontmatter and directory placement are the shared state per the build
contract; `manifest.json` is a local cache that tick branches write through
`manifest-set.sh` and never re-derive on their own — left alone, the cache
drifts (a PRD `built` in the file and `queued` in the cache; a PRD
`shipped` in the cache while still sitting in `build-queue/`; an extend
PRD with no `output_repo_path` because that field is normally set at
publish time and an extend PRD publishes into a repo that already
exists — each of these cost a cycle or a human on 2026-09-03). Reconcile
patches the cache to match the files (through `manifest-set.sh`, same
locked write path Phase 7 branches use — see that section for the
patch-file-not-inline gotcha), backfills `output_repo_path` from
`build_into` for `rust-extend`/`kernel-extend` PRDs, copies
`build_target`/`build_into` onto entries that lack them, clears
`blockers` once a file's `Blocked:` line is gone, and marks/drops
`vanished` entries (7-day grace). Record `reconciled: n` (from the
script's own summary line) in the tick's own summary. Only after this
runs does Phase 1's scan-vs-manifest diff below execute — reconcile
already resolved the disagreements it knows how to resolve, so the diff
should normally be clean.

Run `scripts/scan-prds.sh` — it reads `build-queue/` and `built-prds/` under
`$PRD_DIR`, which defaults to `~/Documents/PRDs` (2026-09-02; pass `PRD_DIR`
only to scan a different workspace). This emits a JSON list of
`{path, slug, status, build_auto, last_modified}` for every PRD under
`~/Documents/PRDs/build-queue/` plus `built-prds/`. Diff against `manifest.json`
(a local cache — if it is missing or older than the clone, rebuild it from the
scan and the PRDs' `Status` lines rather than trusting it):

- **new** PRDs → add to manifest with `status: queued`, log "discovered
  PRD-<slug>".
- **modified** PRDs → reset `last_action` and bump `revision`.
- **deleted** PRDs (file gone from `build-queue/` AND from `built-prds/`; a
  file that reappears under `parked/` is `parked`, not vanished) → mark
  `status: vanished` in manifest; don't actively clean up.
- **archived** PRDs (file gone from `build-queue/` but present in `built-prds/`)
  → mark `status: archived`; **never re-queue**. scan-prds.sh emits `built-prds/`
  entries so Phase 1 can distinguish archived from truly-vanished. A manifest
  entry whose scan path contains `/built-prds/` (or legacy `/ARCHIVE/`) is
  always treated as archived.

**Lint gate (PRD-build-prd-lint, 2026-09-04).** Before the diff above,
`scan-prds.sh` runs `scripts/prd-lint.sh` over every `build-queue/` PRD; a
PRD that fails a contract-shape check (unparseable `deferred_acs`, a
missing/cyclic `Depends-on`, a malformed AC section, an unknown
`build_target`, ...) is written into the manifest as `status:
needs_classification` with the failure's id and message, so it never enters
the Phase 2 candidate pool. See build-contract.md's "Lint gate" section and
run `scripts/prd-lint.sh <file> [--format text|json]` standalone to check a
PRD before committing it.

### Phase 2 — Select

**Depends-on gate (2026-09-02).** A queued PRD whose frontmatter `Depends-on:`
names a PRD that is not yet in `built-prds/` is not selectable this tick.
Log one line per skipped PRD (`waiting on PRD-<slug>`), do not mark it
blocked, and re-check next tick. Resolve the name against
`~/Documents/PRDs/built-prds/` (a PRD is "built" once its file is there);
a name that matches neither `build-queue/` nor `built-prds/` is a typo — mark
the dependent `needs_classification` and say which name failed. Ordering
within a tick follows the same rule: never dispatch a dependent in the same
tick as the PRD it waits on.

Build a candidate pool in priority order:

1. PRDs whose manifest `status` is `in_progress` and `last_action` is
   ≥ 1 hour ago (continue interrupted work).
2. PRDs with `status: queued` (start new work; `build_auto` is no
   longer consulted).
3. None → "nothing to do," log, exit.

**Hard pre-filter (applied before the pool, removes entries that must not run):**
- `status: archived` or `status: vanished` → never selectable; skip silently.
- PRD file is absent from `build-queue/` AND present in `built-prds/` → force `status:
  archived` in the manifest right now and skip; do NOT dispatch a cloud agent.
- PRD file is absent from `build-queue/` AND absent from `built-prds/` → force `status:
  vanished` and skip.
- `status: queued` but `last_action` is within 24h with `action: verified-*` or
  `action: already-*` → skip this tick (was just re-verified; don't spend another
  cloud session re-confirming the same thing). Next tick it remains queued and
  will be picked if nothing newer is available.

Within both buckets, sort by `build_priority` descending
(`high` > `normal` > `low`; null counts as `normal`), then by
`last_modified` ascending (oldest queued first within a priority).
PRDs the user has explicitly bumped to `build_priority: high` get
picked before their normal-priority siblings.

Then pick **up to 30 PRDs** from the pool that mutually satisfy the
parallel-dispatch rules in the "Parallelism" section (shared `build_into`
isolated via worktrees up to the ≤3 same-target sub-cap, ≤1 kernel-extend,
≤1 reflect-eligible). Fewer than 30 is fine; the cap is 30, the floor is
whatever the queue admits after conflict-pruning. If the pool yields zero,
exit clean.

**Lane predicate (2026-09-06, PRD-build-second-lane-carbon).** Before
admitting a candidate, run `scripts/lane-predicate.sh select <prd-path>`
(lane defaults to `hostname`, so RedBaron and carbon both use the same
script and the same tick logic — no fork, no env drop-in). Exit 0 ("ok: ...")
admits the candidate to the pool; exit 1 ("skip: ...") drops it silently
from this tick's selection (log the reason, do not mark it blocked — the
other lane, or this lane next tick, may still take it). Two things gate a
candidate:
- **Cargo-free filter, carbon only.** On any lane whose hostname is not
  `RedBaron`, only `build_target` ∈ {`python-cli`, `python-lib`,
  `python-agent`, `shell`, `hooks`, `config`, `notebook`} is selectable.
  RedBaron itself is unrestricted (the filter is an optimization on
  carbon, never a partition — RedBaron may still take cargo-free PRDs).
- **Target-repo exclusivity, every lane.** A PRD whose `build_into` repo
  is named in another lane's live (non-stale) claim — per
  `scripts/lane-claim.sh target-busy` — is skipped by this lane this tick,
  regardless of which lane is doing the selecting.

Before a lane's tick may CLAIM (not merely select) a PRD it runs
`scripts/lane-claim.sh claim <prd-path> [lane-name]` — push-wins: it
writes `Status: building` + `Lane: <hostname> <ISO-ts>` into the PRD's own
frontmatter, commits (one PRD per commit), and pushes; a rejected push
means rebase-and-reread — if the PRD now carries another lane's fresher
claim, this lane skips it this tick (exit 2, `held: ...`/`lost-race: ...`).
A claim ≥3h old with no subsequent commit touching that PRD is stale and
reclaimable (`reclaim-receipt: ...` printed on exit 0) — see
`scripts/lane-claim.sh`'s own header for the full exit-code contract and
`scripts/lane-claim-selftest.sh` / `scripts/lane-predicate-selftest.sh`
for the race/exclusivity/reclaim scenarios exercised offline. `Lane:` is a
display-only key to the rest of this parser (see build-contract.md);
archived PRDs keep it as inert history.

**Carbon-lane origin check.** Before a non-RedBaron lane assembles its
candidate pool at all, run `scripts/lane-predicate.sh reachable` once
(mirrors Phase 2.5's RedBaron check below, but for the PRD clone's own
origin rather than the Rust build machine). If it reports `unreachable`,
build nothing this tick, journal the reason, and exit cleanly — an
unpushed claim is invisible to the other lane, so a lane that cannot push
must idle rather than build unclaimed.

### Phase 2.5 — RedBaron reachability check

The Hetzner burst box was retired on 2026-09-01; there is no session to start.
RedBaron is the fleet's Rust build machine and is always on (Wintermute Hub is
the Hetzner NATS box and builds nothing). If this tick selected any cargo-bound
PRD (`rust-cli`, `rust-lib`, `rust-extend`) and `hostname` is not `RedBaron`,
run `bash ~/.claude/skills/rustbuild/scripts/cargo-on-redbaron.sh status` once; if
RedBaron is unreachable, mark those PRDs `blocked: RedBaron unreachable` for
this tick and dispatch only the non-cargo PRDs.

### Second lane setup (carbon, PRD-build-second-lane-carbon)

Carbon runs the same tick scripts as RedBaron unmodified (the lane comes
from `hostname`, not a fork) — enabling the second lane is purely a
carbon-local systemd install, done once:

```
bash ~/.claude/skills/build/scripts/carbon-lane-install.sh        # dry-run: append --dry-run
systemctl --user daemon-reload
systemctl --user enable --now claude-build.path prd-sync.timer
```

`carbon-lane-install.sh` symlinks `systemd/carbon/*` (this repo's versioned
mirror of RedBaron's proven unit set: `claude-build.path` +
`claude-build.path.d/nolimit.conf`, `claude-build.service` +
`claude-build.service.d/pacing.conf` — `TimeoutStartSec=400` sized above
the 300s `ExecStartPost` sleep, the 20:12 lesson pre-fixed here —
`claude-build.timer`, `prd-sync.{service,timer}`) into
`~/.config/systemd/user/`. It only links files; it never enables, starts,
or `daemon-reload`s anything, and it is a no-op when already in sync — the
enable/disable state stays carbon-local by design (this repo's clone
travels to every box; the systemd install does not). With the units
disabled, carbon's behavior is byte-identical to today (idle). RedBaron
needs no equivalent step — its units already live in `~/dotfiles` and are
unaffected by any of this.

### Phase 3 — Classify

Read the PRD. Determine its implementation shape:

- **Rust crate / lib / CLI** → delegate to `/rustbuild`. The PRD is
  the input; the skill runs `/rustbuild` in this conversation with
  the PRD path as the argument, then captures the result repo path and
  acceptance-test verdict.
- **Python CLI / lib / agent** (`build_target: python-cli | python-lib |
  python-agent`) → delegate to `/pybuild` with the PRD path as the
  argument and `--target cli|lib|agent` taken from the suffix. If the PRD
  sets `build_into: <abs-path>`, validate the path exists and is a git repo
  with a `pyproject.toml`, set `output_repo_path` to it and let pybuilder
  extend in place (no `gh repo create`); otherwise pybuilder scaffolds a new
  project and the new-repo publish path applies. Capture the Stage 4 gate
  verdict (`ready` / `blocked`) and the receipt directory
  (`<project>/.pybuilder/`) into the manifest `verification` field. All
  Python runs locally under `uv` — there is no remote leg for Python.
- **Rust extend** (`build_target: rust-extend`) → the PRD declares an
  existing repo to extend, via `build_into: <abs-path>`. The skill
  validates the target with `scripts/extend-handler.sh validate <slug>`;
  if validation fails, mark `needs_classification` and stop. Otherwise
  set `status: in_progress`, set `output_repo_path` to the validated
  `build_into`, and route to the Phase 4 extend path. NEVER calls
  `gh repo create` for this target type — the repo already exists.
- **Kernel extend** (`build_target: kernel-extend`) → the PRD extends
  one of `~/wintermute/{agentns,memlog,provfs/lsm}` or proposes a new
  kernel feature. `/rustbuild` does NOT handle this — autobuilder is
  Rust-only. The skill itself drops the new C file(s), Kconfig stanza,
  Makefile entry, and (if the change touches existing in-tree files)
  appends new anchor blocks to
  `~/wintermute/wintermute-kernel/pkg/apply-agentns.py` (or a sibling
  `apply-<feature>.py`). Implementation is hand-written, not delegated.
  The PRD must declare `build_into: ~/wintermute/<slug>` so the skill
  knows where the C source lives. Routes to Phase 4 kernel-extend path.
  NEVER `gh repo create` if the target already has a repo
  (`agentns`/`memlog`/`provfs`); for genuinely new kernel components,
  treat as new-repo.
- **Shell scripts / hook scripts** → implement directly with Write/Edit.
  Run with `set -uo pipefail`; smoke-test before committing.

  **Self-mod distribution (build-skill's own files).** When a shell/config
  PRD's `build_into` points INSIDE this repo (`~/.local/share/build-skill`,
  i.e. the `~/.claude/skills/build` symlink target — its `scripts/*.sh`,
  `SKILL.md`, or `.gitignore`), the edit takes effect locally the moment it
  lands (the symlink means the running skill reads it), but it does NOT
  reach other clones until pushed. There is no `wm-push`/`wm-publish`
  wrapper for this repo. So after committing such a self-mod with the Joe
  Yen identity, run `scripts/self-push.sh` as the final step — it
  fast-forwards `origin/main` under hard guards (correct repo/remote/branch,
  no uncommitted tracked changes, strictly fast-forward, ≥1 ahead) and is a
  no-op when already in sync. If it exits 5 (diverged), `git fetch` +
  rebase onto `origin/main` first, then re-run; never force-push.
  # After self-push.sh: answerable-emit.sh self-edit <file> "<why>" false
- **Config / settings.json changes** → edit settings.json with jq plus
  atomic rename. Always snapshot first to `settings.json.bak.<ts>`. For
  ticks that touch settings.json AND one or more hook scripts in the
  same action, wrap the set in `txn-edit snap` so a mid-write failure
  rolls back together; `txn-edit commit <id>` once the new wiring is
  verified end-to-end (e.g., a smoke invocation of the new hook).
- **Doctrine / process / planning** (PRDs that have no concrete build,
  e.g. `PRD-serious-200.md`) → skip; mark `status: notebook` in manifest.
- **Mixed** (Rust + hooks, or Rust + Python) → do the Rust portion via
  `/rustbuild` this tick; queue the hook or Python portion for the next tick.

If classification is ambiguous, mark the PRD `status: needs_classification`
and emit one line in the journal asking the user to add a hint to the PRD
frontmatter (e.g., `build_target: rust-cli`).

### Phase 4 — Implement (one action per selected PRD)

For each PRD selected in Phase 2, do exactly ONE of the following —
whichever advances that PRD by one well-defined step. The 1..=30 PRDs
in this tick's selection run in parallel via Agent tool calls
(see "Parallelism" below). Each branch stops after its action.

- **iter-1 (scaffold)**: For a Rust target, invoke `/rustbuild` with
  the PRD path. Let autobuilder run its own loop. Capture the result
  in the manifest as `output_repo_path`.
- **iter-1 (extend-scaffold)** [rust-extend only]: invoke
  `/rustbuild --extend <build_into>` with the PRD path. If
  `/rustbuild` doesn't yet support `--extend`, fall back to running
  cargo + writing src/tests/ files directly with cwd = `build_into`.
  Do NOT init a new repo, do NOT overwrite existing src files (extend,
  don't replace). Record `output_repo_path` = `build_into` in the
  manifest.

  **Worktree isolation invariant — the main checkout is never left dirty
  between ticks.** For every rust-extend PRD, iter-1 calls
  `wm-buildtree ensure <slug> <build_into>` and records the returned
  worktree path as `manifest.<slug>.work_tree`. All subsequent file
  writes for that PRD target the worktree path, not `build_into` itself.
  Every tick that mutates files ends with `wm-buildtree commit <slug>
  <build_into> <msg-file>` so the increment is durable on branch
  `build/<slug>` and the main checkout stays clean. The final
  `bump-version & commit` step (see below) becomes: bump in the
  worktree, commit, then `wm-buildtree land <slug> <build_into>
  --ff-only` to fast-forward the default branch; `wm-push` runs after
  a successful land. `wm-buildtree land` exits 4 (no mutation) if the
  main checkout is dirty, preserving Hard Safety Rule 5 — but now only
  at the *land* boundary, not on every intermediate increment.

  **Shared-target case (≥2 PRDs share one `build_into` this tick):**
  use `worktree-extend.sh add <build_into> <slug>` instead of
  `wm-buildtree ensure` — the shared-target helper uses a different
  worktree root (`~/.cache/build-worktrees/`) and defers the version
  bump + CHANGELOG to a serial locked `integrate` step. See "Worktree
  isolation" for details. Do NOT use `wm-buildtree land` for
  shared-target branches; use `worktree-extend.sh integrate` + `cleanup`.
- **iter-1 (kernel-extend)** [kernel-extend only]: do NOT call
  `/rustbuild`. Hand-write the kernel C source per the PRD spec:
  drop new C file(s) into `<build_into>/` (e.g.
  `~/wintermute/memlog/driver/foo.c`), update the local Kconfig stanza,
  add the obj line to the local Makefile. If the change requires
  touching upstream kernel files, append a new `edit(...)` /
  `replace_once(...)` block to
  `~/wintermute/wintermute-kernel/pkg/apply-agentns.py` (idempotent,
  anchored on a unique substring). Then trigger
  `cd ~/wintermute/wintermute-kernel/pkg && makepkg -e --skippgpcheck
  --noconfirm` and capture the build log. If build fails, leave
  `status: in_progress` and put the compile error in
  `manifest.<slug>.last_error`. Counts as one tick action. The first
  successful build verifies the iteration; live `insmod`/reboot
  validation is the user's call (don't auto-reboot).

  **Worktree isolation (kernel-extend):** apply the same
  `wm-buildtree ensure/commit` discipline as rust-extend — the kernel
  C files and Kconfig edits all go into the worktree. The
  `wintermute-kernel/pkg/makepkg` build is triggered from the worktree
  path. `wm-buildtree land` at verified-complete fast-forwards the
  `build_into` default branch exactly as for rust-extend. Main checkout
  of `build_into` is never left dirty between ticks.
- **iter-2..N (continue)**: If `/rustbuild` left work, hand the same
  PRD back to it. Each `/rustbuild` invocation IS one tick's action;
  do not chain them within a single tick.
- **bump-version & commit** [rust-extend only]: when implementation is
  locally green, run `scripts/extend-handler.sh bump-version <build_into>
  <bump>` (bump from manifest `version_bump`, default minor), then
  commit with the Joe Yen identity. Commit subject:
  `"<crate>: v<new-version> — <one-line from PRD title>"`. Counts as
  one tick action. **Shared-target branches do NOT do this in place** —
  they commit implementation-only on their worktree branch, and the
  version bump + commit happen at `worktree-extend.sh integrate` time
  (serial, locked) so stacked branches increment cleanly.
- **changelog & install** [rust-extend only]: extract the PRD's TL;DR
  into a tempfile, run `scripts/extend-handler.sh changelog-prepend
  <build_into> <new-version> <tldr-file>` then
  `scripts/extend-handler.sh install <build_into>`. Bin reinstalls to
  `~/.local/bin/` if the crate has a `[[bin]]` (or single-bin
  convention). Counts as one tick action.

  **Daemon-restart wiring convention (PRD-vigil-build-restart-wiring):**
  `extend-handler.sh install` automatically routes each binary through
  the safe install+restart path when the install dest is backed by an
  active `~/.config/systemd/user/*.service` unit:
  - Detection: `scripts/unit-for-dest.sh <dest>` scans `ExecStart=`
    lines (with `%h`/`%t` expansion) and echoes the backing unit name,
    or empty if none.
  - If a unit is found AND `rollout` is on `$PATH`: runs
    `rollout install <artifact> --dest <dest>` (installs + restarts the
    unit through the safe path). Verdict: `rollout-install`.
  - If a unit is found AND `rollout` is NOT installed: falls back to
    `install -m755`, logs a WARNING to stderr, appends a Pending note to
    `~/wintermute/rustbuild/notes/gossip.md` naming the unit that was
    installed-but-not-restarted. Build still exits 0. Verdict:
    `install-m755-fallback`.
  - If no unit backs the dest: plain `install -m755`, unchanged
    behaviour. Verdict: `install-m755`.
  The chosen verdict is echoed to stderr as `[install-verdict]` for the
  per-tick log. Non-daemon-backed CLIs, libs, hooks, and config targets
  are entirely unaffected — no `rollout` invocation, no behavioural diff.

- **intent card refresh** [rust-extend only]: after changelog & install,
  before push — PRD-build-intent-card-refresh: an extend ship that never
  touches `agent/intent-card.json` leaves it describing whatever PRD last
  refreshed it, so the reviewer-agent's scope check eventually blocks a
  routinely-shipped head with `intent-card-diff-scope-mismatch` against a
  diff the card never described (mcphost, 2026-09-05: two blocks in one
  night from a card frozen since v0.5.x while six PRDs and eight version
  bumps landed). Run:

  ```
  scripts/intent-card-refresh.sh <build_into> <prd-path>
  ```

  This regenerates `<build_into>/agent/intent-card.json` from the PRD that
  just landed (schema, prd_source, intent_slug, root_motivation, and
  acceptance_criteria are sourced from the PRD; every other required field
  — user_persona, unfakeable_metric, scope, non_goals, hard_constraints,
  five_whys_trace — carries forward unchanged from the existing card,
  marked in the card's `carried_forward` object, never fabricated) and, in
  the same pass, removes `agent/intent_card_amendment_request.json` when
  every one of its `scope_additions` entries is now covered by the
  refreshed card. On a malformed PRD (no parseable AC lines) the script
  exits 3 and writes nothing — treat that as a `gate-red`-shaped stop
  (`next: investigate-prd-ac-format`), the same as any other pre-gate
  failure, rather than shipping a card that doesn't match the diff.
  Commit the result with the Joe Yen identity, subject `"agent: refresh
  intent card for <slug>"`, before the `push` step below — the gate must
  review a head whose card is already true. Counts as one tick action.
  Shared-target branches: run this at `worktree-extend.sh integrate` time
  (same serial per-repo lock), immediately after that step's version-bump
  commit and before its own push, for the same reason.

- **push** [rust-extend only]: `wm-push --slug <slug>` from inside
  `<build_into>`. `wm-push` (installed at `~/.local/bin/wm-push` per
  PRD-build-push-allowlist) wraps `git push origin <branch>` with a
  slug-regex + allow-list + origin-URL match + branch-equals-current
  + fast-forward + ≥1-commit-ahead guard, and has a settings.json
  allow rule (`Bash(wm-push:*)`) so it doesn't trigger the auto-mode
  classifier on every tick. **If `wm-push` is not on `$PATH`, do NOT
  defer to a human — push directly:** verify clean tree + branch ==
  current + fast-forward + ≥1 commit ahead inline, then run
  `git push origin <branch>`, and log `wm-push-fallback-direct` to the
  journal. Only set `next: investigate-push-guard-failure` if those
  inline guards genuinely fail (a correctness stop, not a permission
  gate) — same if `wm-push` itself exits 2 with a guard rejection. New
  slugs need to be added to the `ALLOW` array near the top of `wm-push`
  — keep it in sync with `wm-publish`'s ALLOW and `~/wintermute/REPOS.md`.
  Counts as one tick action.
  # After wm-push succeeds: answerable-emit.sh push <repo> "v<ver> — <one-line>" false
- **gate** [rust-extend only — the PRD's non-goals exclude python-* (already
  gated by `pybuilder gate ready`) and kernel-extend (gated by `makepkg`,
  no autobuilder receipts)] —
  after `push` and before anything reads `built`, on EITHER landing path
  (`wm-buildtree land` + `wm-push`, or the shared-target `worktree-extend.sh
  integrate` + `wm-push` + `cleanup`). PRD-build-extend-gate-receipts: the
  extend path lands, bumps and pushes on the default branch without ever
  regenerating autobuilder's 25 receipts, so every ship since the last
  human-run regeneration is gate-red at the landed commit — this action
  closes that gap. Run:

  ```
  scripts/extend-gate.sh <build_into> --head <landed sha>
  ```

  `<landed sha>` is the bump commit's sha on `origin/<default>` right after
  the push above (`git -C <build_into> rev-parse HEAD`). `extend-gate.sh`
  regenerates all 25 receipts at that HEAD on the main checkout (never in a
  worktree — the worktree's `target/` holds none of the crate's real
  receipts) and runs `autobuilder gate --project .` as the single verdict.
  Counts as one tick action.

  **Mixed-tick burst routing (2026-09-06, PRD-build-gate-cloudburst).**
  Heavy cargo (this gate's 25-receipt regeneration) sharing a box with a
  timing-sensitive Python suite can flip the suite's verdict under load
  (observed 2026-09-06: a 444s mcphost gate beside a synthorg suite that
  went red at an unchanged green commit). Before invoking `extend-gate.sh`,
  the tick consults the mixed-tick predicate with this tick's own dispatch
  counts:
  ```
  scripts/gate-burst.sh should-route --rust <n_rust_gate_prds> --python <n_python_prds>
  ```
  Exit 0 (both counts > 0) routes the ENTIRE `extend-gate.sh` invocation
  through the burst manager instead of running it locally:
  ```
  scripts/gate-burst.sh run <build_into> -- scripts/extend-gate.sh <build_into> --head <landed sha>
  ```
  Exit 3 from `gate-burst.sh run` (or `should-route` reporting `local`)
  means: run `extend-gate.sh` locally exactly as written above — today's
  behavior, unchanged. `gate-burst.sh run`'s own fallback covers every
  burst failure mode (precondition absent, boot failure, rsync/ssh
  failure) by printing `fallback: <cause>` and exiting 3 — the tick must
  treat that exit code as "fall back to local", never as a gate block.
  **Precondition, verified 2026-09-06:** no `/cloudbuild` skill exists on
  this machine (checked directly — not under a renamed pre-fleet-sync
  backup either) and `hcloud` itself is not on `$PATH`, so
  `scripts/gate-burst.sh precondition` currently fails closed for real;
  bursting stays off until a Hetzner-capable box runs `hcloud` setup +
  `~/.config/wm-burst/.env`'s `SNAPSHOT_ID` — see the script's own header
  for exactly what it checks. At tick end (Phase 7 parent step, after all
  branches return), call `scripts/gate-burst.sh down` (add
  `--more-work-queued` when the next tick's candidate pool already shows
  pending rust-extend gates) so a box never survives into a second billed
  hour idle.

  - **On pass** (`pass=25 block=0`): tag the shipped commit —
    `~/.claude/skills/rustbuild/scripts/ship-tag.sh <build_into> <slug>`
    (tags `v<version>` at HEAD, pushes `--follow-tags`; a second run is a
    no-op) — then write the PRD's `Receipts:` line:

    ```
    Receipts: <build_into>/target/autobuilder/receipts (gate: pass=25 block=0 verdict=pass at <sha>, tag v<version>; rollback base <tag> at <sha>)
    ```

    (`<tag>` and its `<sha>` come from `target/autobuilder/receipts/rollback-plan.json`'s `base_tag`/`base_sha` — when `base_tag` is `null`, write `rollback base initial (no tags) at <base_sha>` instead.) Then proceed to the verified-completed checklist (check #6 below).
  - **On block**: the manifest entry's `blockers` gains one
    `gate: <receipt> — <message>` line per blocking receipt (the receipt
    names and messages `extend-gate.sh` printed and journaled), `next:
    gate-red`, the PRD's `Status:` stays `in_progress` — **do NOT tag,
    archive, or write a passing `Receipts:` line.** The journal already has
    one line naming the blocking receipts (written by `extend-gate.sh`
    itself); no separate journal write is needed here.
  - `extend-gate.sh` takes the crate's own integration lock, so a `gate`
    action never races a same-crate `integrate` or another `gate` run.
    Resumable: if a tick ends mid-gate, the next tick's `gate` action reruns
    `extend-gate.sh` from the start — a partial receipt set is never read
    as green.
- **install / wire** [new-repo only]: When implementation is locally
  green (tests pass, `cargo test --release` ok), install built binaries
  to `~/.local/bin/` via `install -Dm755`. If the PRD includes hooks,
  symlink them into `~/.claude/scripts/` and patch
  `~/.claude/settings.json` (jq + atomic rename, snapshot first).
  Each install/wire counts as one action. (For rust-extend, use the
  bump-version/changelog-install actions above instead.)

  Scope-check the action with `wchg`: register a watch on the
  expected-write roots before the action (`wchg watch
  ~/.local/bin`, `wchg watch ~/.claude/scripts`, `wchg watch
  ~/.claude/settings.json` — or whichever paths the PRD declared),
  run the install/wire, then `wchg since <path>` for each. Any file
  outside the declared roots is a scope-escape: leave
  `status: in_progress`, put the unexpected paths in
  `manifest.<slug>.last_error`, and surface for the next reflect
  cycle. The watch state is cheap to keep across ticks; only `wchg
  reset` after the PRD ships.
- **publish** [new-repo only — never for rust-extend or a `build_into`
  Python extend]: **the PRD's `publish:` frontmatter key decides the
  destination — never the directory the PRD came from.**
  - `publish: j0yen/private` (**default when the key is absent**): 
    ```
    gh repo create j0yen/<slug> --private --source=. --remote=origin --push --description="<one line from the PRD>"
    ```
    Log `publish-j0yen-private` to the journal.
  - `publish: j0yen/public`: create via the `wm-publish` wrapper
    (`~/.local/bin/wm-publish --slug <slug> --description "…"`), which wraps
    `gh repo create j0yen/<slug> --public …` behind a slug-regex + allow-list
    guard and has a settings.json allow rule. New slugs must be added to the
    `ALLOW` array near the top of `wm-publish` — keep it in sync with
    `~/wintermute/REPOS.md`. Public is an explicit choice in the PRD, never a
    default.
  - `publish: none`: skip repo creation; the artifact stays local (used for
    experiments and harness-only PRDs). C2 of the archive gate is then
    satisfied by "no publish requested".
  - **Guard**: the only organisation `/build` may create repos in is `j0yen`.
    Any other value (including `joeyen-atscale`, whose access is gone) →
    mark `needs_classification`, do not publish, ask. A PRD carrying a
    `publish:` value that contradicts its project profile's `Publish:` line
    (see `~/Documents/PRDs/projects/`) is likewise a stop-and-ask, not a guess.

  After the publish lands, write the initial `README.md` from the
  PRD's TL;DR + acceptance tests + an "Install" block. Update
  `~/wintermute/REPOS.md` with a one-line entry under the appropriate
  category section — this index tracks shipped repos regardless of target
  org (ryzen7's build skill does the same, per its own SKILL.md). Bump
  `budget.used.repos_created`.
- **clerical-finalize**: When a candidate's archive gate fails on
  **only** clerical checks (C2 publish/push, C3 README/CHANGELOG, C4
  REPOS.md) while C1 (tests green) AND C5 (ACs paired/deferred) already
  pass, run `scripts/archive-finalize.sh <slug>` as this PRD's ONE
  action. The helper gates the gate (exits 10 `not-clerical` and mutates
  nothing if C1 or C5 fail), performs exactly the missing clerical fixes
  (publish/push, README or `## v<ver>` CHANGELOG from the PRD TL;DR,
  idempotent REPOS.md row), commits **path-scoped** with the Joe Yen
  identity (never sweeping a dirty tree), pushes, and re-runs
  `verified-completed.sh` — echoing `[finalize-verdict] ready|still-blocked`
  to stderr. It NEVER writes test files, edits `src/`, or alters AC
  pairing. If the verdict is `ready`, the NEXT tick re-selects and
  archives. Use `--dry-run` to preview the plan + commit pathspec. Fenced
  companion to `verified-completed.sh` (classifier) and `extend-handler.sh`
  (extend mechanics).
- **archive**: When the PRD passes the **verified-completed** checklist (all
  checks must hold — five for new-repo/python-*/kernel-extend, six for
  rust-extend, see check #6 below) **AND the rebuild gate passes**, update manifest to
  `status: shipped`, set the PRD's own `Status:` line to `built` (+ `Built:
  <date>` and `Receipts: <path>` lines), then move the file into `built-prds/`
  and commit +
  push. Path depends on which workspace the PRD lives in:
  - **`~/Documents/PRDs` (default)** — push to `j0yen/prds` (origin); pull
    first so another machine's progress is never overwritten:
    ```
    cd ~/Documents/PRDs && git pull --rebase -q
    git mv build-queue/PRD-<slug>.md built-prds/
    git -c user.name="Joe Yen" -c user.email=jyen.tech@gmail.com commit -m "archive: <slug> shipped"
    git push
    ```
  Record the five passing checks in the manifest entry's `verified_completed` field.

  **Rebuild gate (gap #68 — re-queues must prove they advanced the work;
  ported from ryzen7 2026-08-03, applies to either path).** Before
  archiving, if the manifest entry's `revision > 1` (this PRD was re-queued
  after a prior ship — e.g. a dreamer reconciliation caught a false-ship),
  run `scripts/archive-rebuild-gate.sh <slug>`. A non-zero exit **blocks
  archive**: it means the re-queue did not (1) bump the crate to a version
  strictly greater than `last_shipped_version`, (2) prepend a
  `## v<new-version>` CHANGELOG section for *that* version, and (3) record
  a non-empty `rebuild_reason` on the manifest entry. The legacy C2
  (`commit-reachable`) and C3 (`changelog-v<X>-exists`) checks are
  satisfiable by the *prior* ship's stale artifacts, so without this gate a
  no-op rebuild self-satisfies the archive gate and "ships" nothing. The
  re-queuer (the dreamer reconciliation tick, or the tick that bumps
  `revision`) MUST set `rebuild_reason` to why it re-queued; a real rebuild
  always has one, a no-op has nothing to say.

  **On archive, also set `last_shipped_version`** in the manifest entry to
  the crate version just shipped (`extend-handler.sh current-version
  <build_into>` for cargo crates). This is the baseline the NEXT re-queue's
  rebuild gate compares against — without it, "version advanced" is
  unverifiable and the gate degrades to `ok-indeterminate` (still enforces
  changelog + rebuild_reason, but cannot prove the version moved). Record
  the rebuild-gate result as `verified_completed.c6` (`rebuild-gate-na` for
  first builds, `rebuild-gate-ok`/`-indeterminate` for passing re-queues).

  **Verified-completed checklist (new-repo path):**
  1. `output_repo_path` exists locally AND the language's test command
     exits 0: `cargo test --release` for `rust-*`; `uv run pytest` for
     `python-*` (plus a `ready` verdict from `pybuilder gate`); or the
     PRD's declared test command.
  2. `output_repo_url` is set in the manifest AND `gh repo view
     j0yen/<slug>` succeeds with the visibility the PRD's `publish:` key
     asked for (`private` unless it says `j0yen/public`), with the latest
     commits pushed. A PRD with `publish: none` passes C2 vacuously.
  3. README.md exists in the repo root, opens with the PRD's TL;DR,
     and contains an Install section.
  4. `~/wintermute/REPOS.md` lists this repo under its category with a
     one-line description.
  5. Every acceptance test the PRD declared (numbered list under
     `## Acceptance` / `## Acceptance tests`) is paired with EITHER:
     - a passing `cargo test` name / `pytest` node id (real test) or a
       smoke-test command in the manifest `verification` field, OR
     - a passing `cargo test --test mocks::ac<N>` (mock test under
       `tests/mocks/ac<N>.rs`) AND the AC is listed in PRD frontmatter
       `deferred_acs:`, OR
     - the AC is in BOTH `deferred_acs:` AND `mock_unjustified_for:`
       with a companion `mock_justifications:` entry (one sentence per
       listed AC; an entry with no companion justification is a parser
       error per `scan-prds.sh`).

     Any AC with none of the three remains a hard fail: the PRD is NOT
     verified-completed — leave `status: in_progress` and surface the
     gap in the next reflect cycle. This OR-clause pairs the
     hardware-mock convention (see `~/.claude/skills/rustbuild/SKILL.md`
     "Hardware mock convention") with the older `deferred_acs:` escape
     hatch: deferring is honest, but a deferred AC must still take a
     mock-test path or carry a prose justification. It is back-compat —
     already-shipped PRDs whose deferred ACs gain a `mock_unjustified_for:`
     + justification backfill still pass.

  **Check #5 is DERIVED, not asserted (`verified-completed.sh --derive`,
  per PRD-build-archive-autopair).** The tick and `archive-finalize.sh`
  both call `verified-completed.sh <prd> --derive` — this is also the
  script's default whenever `--paired` is absent. Derivation scans the
  build repo's `tests/` for every AC-naming convention the fleet actually
  uses, in this order (first match wins; `--format table` shows which
  rule fired and the matched path):
  1. **prefix** — `tests/<p>_ac<N>_*.rs` or the bare `tests/<p>_ac<N>.rs`
     (and `.py`, `.sh` — PRD-build-intent-card-refresh added `.sh` so
     shell-target PRDs, this repo's own build shape, can derive-pair
     instead of always falling back to `deferred_acs`), for a candidate
     prefix `<p>`: the PRD's `test_prefix:`
     frontmatter key if declared (bare scalar or `[a, b]` list — see
     build-contract.md), else a single guess derived from the slug
     (strip the crate name + `-`, split the rest on `-`, take the last
     token unless it's the generic word `tools`, in which case take the
     second-to-last instead — `mcphost-rest-tools` on crate `mcphost` →
     `rest`; `ac-judge-pluggable-backend` on crate `ac-judge` → `backend`).
     Tried FIRST, ahead of the bare rule below, and once ANY of a PRD's
     ACs match via a given prefix, the bare rule is disabled for the
     REST of that PRD's ACs too — both exist specifically because a
     shared crate's `tests/` holds bare `ac01_*.rs`..`ac19_*.rs` files
     belonging to an entirely different PRD, and an extend PRD's own
     un-prefixed leftover ACs (deferred ones, say) must not silently
     false-pair to them.
  2. **bare** — `tests/ac<N>_*.rs` / `tests/ac<NN>_*.rs` (and `.py`, `.sh`).
  3. **acceptance_ac** — `tests/acceptance_ac<N>.rs` (and `.py`, `.sh`).
  4. **mocks** — `tests/mocks/ac<N>.rs` (and `.py`, `.sh`).
  5. **fn-scan** — a `#[test] fn ac<N>_...` or `def test_ac<N>_...` /
     `def test_ac_<N>_...` anywhere under `tests/`. Last resort.

  A guessed slug-derived prefix that doesn't match the crate's real
  convention (e.g. `mcphost-rest-tools`'s tests are actually `http_ac*`,
  not `rest_ac*`) simply finds nothing at that rule and falls through —
  it never produces a wrong pairing, only a missed one, so **declare
  `test_prefix:`** whenever the guess would be wrong. `--paired N,N,...`
  still works and composes ADDITIVELY: it never overrides a derived
  pairing, it only covers ACs the derivation didn't find (shown as rule
  `asserted` in `--format table`/`json`). `deferred_acs:` in prose form
  (not the `[N, N]` list) is reported once as `deferred_acs: unparsed —
  use [N, N]` and treated as none — the ACs that would have deferred
  land on MISSING instead of silently passing. P1: `--verify-run`
  re-runs each derived (non-`asserted`) test and marks a failure
  `PAIRED-FAILING` (still a gate failure) so a stale test file can't
  pair.

  **Verified-completed checklist (rust-extend path):**
  Same as above with three substitutions, plus a sixth check
  (PRD-build-extend-gate-receipts):
  - Check #2 becomes: remote `origin` exists for `output_repo_path` AND
    the new version-bumped commit is reachable from `origin/main` (or
    the repo's default branch). No `gh repo view` because no new repo
    was created.
  - Check #3 becomes: `CHANGELOG.md` exists in the repo root and has a
    `## v<new-version>` section at the top containing the PRD's TL;DR.
    The repo's existing README.md is NOT required to be regenerated.
  - Check #4 becomes: `~/wintermute/REPOS.md` is unchanged by this
    PRD's tick history (negative AC — the extended repo is already listed).
  - **Check #6 (new)**: `autobuilder gate --project <build_into>` at a
    HEAD equal to `origin/<default>` reports `pass=25 block=0`. This is
    what the `gate` ship action (above) already established and recorded
    in the `Receipts:` line — archive re-checks it rather than trusting a
    stale line. **The archive gate refuses otherwise, naming check #6** —
    a PRD whose `gate` action last blocked, or whose `build_into` HEAD has
    since moved (another PRD landed on the same crate without a fresh
    `gate` run), fails archive here and stays in `build-queue/` with
    `Status: in_progress`, not silently treated as shipped on the strength
    of checks #1/#5 alone.

  **Verified-completed checklist (python-* path):**
  Same as the new-repo checklist with these substitutions:
  - Check #1: `uv run pytest` exits 0 AND `pybuilder gate <project>
    --target <t>` reports `ready` (receipts under `<project>/.pybuilder/`).
  - Check #5: ACs pair with pytest node ids or with pybuilder eval-dataset
    cases named in the manifest `verification` field; `deferred_acs` and
    `mock_justifications` work as for Rust.
  - With `build_into` set (extend in place): checks #2–#4 follow the
    rust-extend substitutions (origin reachable, `CHANGELOG.md` top section,
    REPOS.md unchanged).

  **Verified-completed checklist (kernel-extend path):**
  Same as the new-repo checklist with these substitutions:
  - Check #1 becomes: `cd ~/wintermute/wintermute-kernel/pkg && makepkg
    -e --skippgpcheck --noconfirm` exits 0 AND produces
    `linux-wintermute-*.pkg.tar.zst`. We do NOT require live boot/insmod
    validation — that's the user's call. Build-cleanliness is the gate.
  - Check #2 becomes: if `<slug>` already has a j0yen repo
    (agentns/memlog/provfs), the new commit is reachable from
    `origin/main`. Otherwise a fresh repo with the same shape as
    rust-cli.
  - Check #5 becomes: every AC the PRD declares is paired with either a
    compile-time test (e.g. "module compiles", "header syntax-checks")
    OR a runtime test under `<build_into>/tests/` that runs once the
    user boots the wintermute kernel. Compile-only ACs are valid for
    kernel-extend; runtime ACs document the post-reboot validation.

  An unverified PRD never gets archived. If the user manually moves a
  PRD to `parked/`, the next scan detects it as `parked` and the
  skill stops trying to advance it.

  **Clerical-only failures are auto-finishable.** If the only failing
  checks are C2/C3/C4 (publish/push, README/CHANGELOG, REPOS.md) and both
  C1 and C5 pass, do NOT re-build or re-queue — run the
  **clerical-finalize** action above (`scripts/archive-finalize.sh
  <slug>`). It performs the missing chores under a hard C1/C5 guard so it
  can only ever do clerical work, then the next tick archives. This is the
  designated escape from the done→shipped clerical cliff (PRDs that build
  green but re-fail the gate on README/CHANGELOG/REPOS/push bookkeeping).

### Recovery — stale dirty-tree from a pre-wm-buildtree tick

If a rust-extend PRD left uncommitted modifications in a shared main
checkout before `wm-buildtree` was available (the recall logjam pattern),
the user (or a gated tick) can recover without losing the in-flight work:

1. Run `wm-buildtree ensure <slug> <repo>` — creates the isolated branch
   `build/<slug>` from the current `main` HEAD.
2. `git stash` the dirty main tree, then `git stash show -p | git -C
   <worktree> apply -` to port the stashed diff into the worktree.
   Alternatively `cp` the modified files manually into the worktree path.
3. `wm-buildtree commit <slug> <repo> <msg-file>` — commits the salvaged
   work onto `build/<slug>`.
4. `git restore .` (or `git checkout -- .`) in the main tree to return it
   to a clean state — now the other recall-* PRDs can commit their version
   bumps without triggering Hard Safety Rule 5.
5. Resume normal tick flow: subsequent ticks for this PRD will find the
   worktree via `wm-buildtree path` and continue building on the branch.

This migration is user-gated (committing or reverting another PRD's work
is Rule 5). The skill never auto-triggers it.

### Phase 5 — Abouts

After any implementation, ensure the Abouts are consistent. The shape
differs for new-repo vs. rust-extend PRDs:

**New-repo path:**
- Per-repo `README.md`: present, opens with the PRD's TL;DR, ends with
  an "Install" + "License" block. Regenerate when the PRD revision bumps.
- `~/wintermute/REPOS.md`: every repo listed once under the right
  category, one-line description. Detect missing entries by diffing
  against `ls ~/wintermute/`.
- `~/.claude/CLAUDE_SELF.md` changelog: prepend a one-line note when a
  new repo ships ("YYYY-MM-DD (build): shipped <slug> from PRD-<x>.md").
  Stay under the 200-line lint cap.

**Rust-extend path:**
- Per-repo `README.md`: do NOT regenerate. Optionally append a one-line
  bullet under a `## Recent` section (create if missing) summarizing
  what the new version added. Existing structure preserved.
- Per-repo `CHANGELOG.md`: REQUIRED. Use
  `scripts/extend-handler.sh changelog-prepend <build_into> <ver> <tldr>`
  to prepend a `## v<new>` section. Script creates the CHANGELOG if it
  doesn't yet exist.
- `~/wintermute/REPOS.md`: untouched. The repo is already listed.
- `~/.claude/CLAUDE_SELF.md` changelog: prepend a one-line note when a
  new version ships ("YYYY-MM-DD (build): extended <slug> v<old>→<new>
  from PRD-<x>.md"). Stay under the 200-line lint cap.

### Phase 6 — Reflect & propose

At most ONCE PER DAY, write a follow-on PRD. Triggers:

- A `/rustbuild` run blocked on a missing primitive → PRD for that
  primitive ("autobuilder needs a JSON-stable receipt for X").
- A wired feature exposed an obvious next step (the existing observer-
  correlation and daemon PRDs are exactly this shape — see them as the
  template).
- A repeated failure pattern across two or more ticks → a PRD
  proposing a guardrail or pattern that prevents it.

Follow-on PRDs go in `~/Documents/PRDs/build-queue/PRD-build-<topic>.md`
with frontmatter `Status: queued` and a `build_target`. Omit `build_auto` (no longer
parsed). Bump `budget.used.prds_drafted` for telemetry.

**Commit + push the drafted PRD as part of this same tick action.**
Per user instruction 2026-05-27, generated work doesn't accumulate
untracked. Steps:

1. `cd ~/Documents/PRDs && git pull --rebase && git add build-queue/PRD-build-<topic>.md`
2. `git -c user.email=jyen.tech@gmail.com -c user.name="Joe Yen" commit
   -m "build: draft PRD-build-<topic> (Phase 6 reflect)"` — include a
   one-paragraph body explaining what triggered the reflect.
3. `git push origin main`. Bumps `budget.used.commits` for telemetry.
# After Phase-6 PRD commit: answerable-emit.sh draft <prd-path> "Phase 6 reflect" true

No caps block this action — `budget.caps` are all null.

### Phase 7 — Persist & log

**Note on `manifest-set.sh`'s one gotcha** (see Phase 1's reconcile-first
step, which hit this on 2026-09-03): its patch argument is always a PATH
TO A JSON FILE, never an inline JSON string — `manifest-set.sh <slug>
/tmp/<slug>.patch.json`, not `manifest-set.sh <slug> '{"status":...}'`.
`scripts/manifest-reconcile.sh` writes a tempfile per slug for exactly
this reason; do the same in any new caller.

Each branch (per selected PRD) persists its own work through the shared
**`scripts/manifest-set.sh`** helper (added 2026-06-02 — see
PRD-build-durable-manifest-write). Branches MUST NOT hand-roll lock +
read-modify-write logic anymore; the helper owns the one correct
implementation (write-ahead intent file → block on the lock with a hard
60s ceiling → RMW only this slug → drop the intent → release the lock).

**Branch step:**
- Build the patch object (the keys to merge into `prds.<slug>`) and write
  it to a temp file, e.g.:
  `printf '%s' '{"status":"shipped","last_action":"<ISO>","ticks_invested_delta":1,"output_repo_path":"<...>","action":"<...>","outcome":"<...>"}' > /tmp/<slug>.patch.json`
  (include `"last_error":"<...>"` only when the build failed).
- Call `scripts/manifest-set.sh <slug> /tmp/<slug>.patch.json`. The helper
  writes `state/intent/<slug>.json` (write-ahead) BEFORE attempting the
  lock, so even an OOM-kill mid-acquire leaves a recoverable pointer. It
  then acquires `state/manifest.lock.d` (mkdir, retry every 0.2s, hard 60s
  ceiling — NOT the old 5s give-up), RMWs ONLY `prds.<slug>`, deletes the
  intent file, and releases the lock. A non-zero exit means the patch did
  not land but the intent file remains for the parent's replay — do not
  treat it as success in your summary.
- Append a one-line summary to `~/brain/journal/build/YYYY-MM-DD.md`:
  `<ISO-ts>  <slug>  <action>  <outcome>  (<key=value...>)`. The journal
  append is naturally serial — each branch appends its own line. Use `>>`
  to avoid clobbering. **Lane-tagged journaling (2026-09-06,
  PRD-build-second-lane-carbon):** the `key=value` tail MUST include
  `lane=<hostname>` — this is the existing journal path gaining a field,
  not a second journal file, so "who built this" always has an answer
  across two lanes sharing one clone. Any archive commit this branch makes
  (see the `archive` action) likewise names its lane in the commit body or
  the journal line covering it — the git history alone should never leave
  it ambiguous which box shipped a given PRD.
- Release this branch's `state/prd-<slug>.lock`.

**Lane health line (P1, PRD-build-second-lane-carbon).** Once all branches
for this tick have returned, the parent (whichever lane is running this
tick) runs `scripts/lane-status.sh tick-summary <lane> <claimed> <skipped>`
— `<claimed>` and `<skipped>` are the tick's own counts (PRDs this lane
actually claimed and advanced vs. PRDs skipped via the lane predicate's
cargo-free filter or target-busy exclusivity). This appends one line to
today's journal so `/self-review` and a human reading the journal can see
both lanes' contribution without cross-referencing every branch line.
Read both lanes' status (last tick, live claims, stale claims) at any time
with `scripts/lane-status.sh report`.

**Parent step (after all branches return, before releasing `tick.lock`):**
- Run `scripts/manifest-set.sh --replay-orphans`. For every
  `state/intent/*.json` whose patch is not yet reflected in the manifest
  (a branch that hit the lock ceiling or was killed before its write
  landed), it applies the patch under the same locked RMW and logs a
  `manifest-replay` line; intents already reflected are cleaned up without
  a redundant write. It is a no-op (exit 0, no manifest change) when
  `state/intent/` is empty. This is the automatic version of the by-hand
  repair the parent did on 2026-06-02 when 2/6 branches dropped their
  writes under contention.
- Run `scripts/verdict-receipts.sh postflight ~/brain/journal/build/<today>.md`
  (PRD-build-verdict-receipts). This scans the tick's own journal for the
  reserved-word verdicts branches just appended and, if any lack their
  required receipt(s), appends ONE flag line to that same journal naming
  them — belt and braces alongside the branch-prompt prose contract
  above, since prose alone already let an unreceipted "bisected
  regression" and an unretried "unreachable" block ship in one evening.
  Never fails the tick (always exits 0); a flagged verdict is Phase 6's
  reflect-phase input, not a reason to block this tick's own exit.
- Then release `tick.lock`.

This design (per-slug write-ahead intent + a blocking-with-ceiling lock +
end-of-tick replay) makes a Phase-7 write durable even if the branch loses
the lock or dies mid-acquire — the failure mode that caused silent manifest
loss under fan-out (observed 2026-05-30 9-way, 2026-06-02 6-way). The
legacy "acquire the lock yourself + direct RMW with a 5s give-up" pattern
is REMOVED; do not reintroduce it in branch agents.

## Parallelism (per-tick fan-out, added 2026-05-28)

Each tick advances **up to 30 PRDs in parallel**. The per-PRD
constraint (one action per PRD per tick) is preserved unchanged;
only the per-tick fan-out grew (1 → 5 → 10 → 30). User instruction
2026-05-28: "this laptop can handle it"; raised 5 → 10 on 2026-05-29;
raised 10 → 30 by user 2026-06-11 — **30 is the operative cap, do not
self-throttle below it.**

**Fan out to the full cap by default — do NOT self-throttle below 30 on
memory grounds.** Carbon has **15 GB RAM (0 swap), typically ~11 GB
free** (RedBaron has 30 GB). On carbon/ryzen7 heavy cargo builds route
to RedBaron through /rustbuild's cargo shim, so local memory pressure is minimal; on
RedBaron they run locally, so honor the ≤3 same-target sub-cap strictly. The real OOM guard is the **≤3 same-target
sub-cap** below (it bounds parallel cargo builds of ONE heavy crate like
recall's fastembed); honoring that, total width 30 is safe. The **< 4 GB
available** check (at selection time) is the ONLY permitted reason to
reduce width — and it must be logged with the measured number.

Note on coordination: ticks run detached as `claude-build-work.service`
(30-min cap), so a 30-wide fan-out has room to finish + commit. Seeing
`claude-build-work.service` active/activating is **THIS tick's own
container** — do not mistake it for a competing tick and shrink the
fan-out; the launcher's overlap guard already guarantees one tick at a
time.

### Selection rules (extends Phase 2)

After the existing priority sort, pick up to 30 PRDs that mutually
satisfy:

1. **Shared `build_into` → isolate with worktrees, don't serialize.**
   Two branches mutating the same crate in place would race cargo locks
   and the git index. Instead, when ≥2 selected rust-extend PRDs share a
   `build_into`, each runs in its own git worktree (separate index, tree,
   and `target/`) — see "Worktree isolation" below. This is the fix for
   the recall/agorabus/episodic-observer clusters that used to serialize
   one-per-tick behind a single repo. **Sub-cap: ≤3 same-target branches
   per tick** — parallel cargo builds of a heavy-dep crate (e.g. recall's
   fastembed) are memory-hungry; 3 bounds the blast radius. Kernel-extend
   targets are exempt from worktree fan-out (rule 2 already caps them).

   **Serial-fallback override (loom-serial-fallback, PRD-loom-serial-fallback).**
   Before admitting multiple branches for the same `build_into` target, check
   whether that target has a conflict streak ≥ 2 (consecutive ticks ending in
   integrate-conflict or rebase-broke-build for that repo):
   ```
   scripts/loom-serial-fallback.sh serial-limit <build_into>
   ```
   Exit 0 = serial mode active → admit **at most 1** branch for that repo this
   tick (call `serial-gate <repo> <count>` per candidate to enforce the cap).
   Exit 1 = normal parallel → apply the ≤3 sub-cap as usual.
   Fail-open: any error or absent streak file → exit 1 (no serialization).
   When serial mode is active, pick the **oldest-deferred branch first**
   (sort by `last_action` ascending, then `first_deferred_at` if present) so
   selection is deterministic (AC3). `worktree-extend.sh integrate` calls
   `streak-record` on every exit-4 (conflict/rebase-broke-build) and
   `streak-reset` on every clean integrate — the parent tick does NOT need to
   call these directly. Mode flips are logged to gossip (AC6); never silent.

2. **≤1 `build_target: kernel-extend` per tick** — the kernel
   `makepkg` build saturates the box (load avg ≥ 10 single-threaded);
   running two in parallel triples wall time without finishing faster.
3. **≤1 Phase-6-eligible reflect candidate per tick** — the
   daily-reflect cap still applies (once per day across all branches).
   If two candidates would otherwise both trigger reflect, designate
   one as reflect-eligible and the other skips Phase 6.

Fewer than 30 is fine. Selection is greedy — walk the sorted candidate
pool, admit each PRD that doesn't violate a rule against already-
admitted ones, stop at 30 or end-of-pool.

### Dispatch

Issue the selected PRDs as **parallel Agent tool calls in a single
tool-use message**, one Agent call per PRD. Use
`subagent_type=general-purpose` unless the PRD frontmatter declares
otherwise.

**Model override (added 2026-05-28).** Dispatch each branch with
`model: "sonnet"`. Branch work is well-specified PRD execution behind a
gate (cargo test / the autobuilder 7-receipt gate catches errors), which
is Sonnet's sweet spot — running branches on Opus burns tokens without a
quality gain the gate can't already enforce. The parent tick orchestrator
(this skill, selecting/dispatching/journaling) runs on Sonnet (`model: sonnet`
in the skill frontmatter). **Escalate a branch to `model: "opus"`** when any of:
- the PRD declares `build_priority: high` AND its shape is architectural /
  ambiguous (new subsystem, cross-cutting design), not a mechanical extend;
- `build_target: kernel-extend` (hand-written C, subtle, no autobuilder
  gate — wants the stronger model);
- the PRD's manifest entry shows it failed or stalled on a prior tick
  (`last_error` set, or `ticks_invested ≥ 3` with no status change) —
  retry one tier up before giving up.
Pass the chosen model via the Agent call's `model` field. When unsure,
default to Sonnet; the escalation list is the only reason to go Opus.

**Where cargo runs (2026-09-02).** RedBaron is the fleet's Rust build machine
(i7-11700KF, 16 threads, 30 GB, sccache + mold in `~/.cargo/config.toml`).
On RedBaron, branch agents run `cargo` locally. On carbon or ryzen7, every
`cargo build`, `cargo test`, `cargo clippy` and `cargo deny` runs on RedBaron
through /rustbuild's cargo shim; a silent local build is not allowed (user
instruction 2026-06-16, reaffirmed 2026-09-02). Wintermute Hub, the Hetzner
NATS box, builds nothing, and the Hetzner burst box was retired 2026-09-01.
(Measured 2026-09-01: a clean release build of `recall` took 79 s on RedBaron.)

Enforcement (carbon/ryzen7): every branch agent MUST run
`export PATH="$HOME/.claude/skills/rustbuild/bin:$PATH"` before any cargo
work. That shim runs every cargo command on RedBaron (sync, build there with
sccache + mold, pull `target/` back). Before starting:
`bash ~/.claude/skills/rustbuild/scripts/cargo-on-redbaron.sh status`. If
RedBaron is unreachable, do NOT build locally and do NOT try to rent a server
(the burst path is retired): mark the PRD `blocked: RedBaron unreachable`, log
it, and stop this branch.

This applies to both new-scaffold and rust-extend branches. Non-cargo work
(Write/Edit, shell scripts, gh, git) stays local. Each agent prompt must
include this directive verbatim: "Prepend ~/.claude/skills/rustbuild/bin to
PATH so every cargo command runs on RedBaron. Do NOT run cargo directly on
this machine. If cargo-on-redbaron.sh status reports RedBaron unreachable,
mark the PRD blocked and stop; never rent a server."

Each agent prompt must include, self-contained:

- Prepend the output of `inoculate-preamble` (if installed) to the agent's task prompt, so spawned agents carry the in-force strain.
- The PRD's absolute path.
- The PRD's slug.
- "You are advancing ONE PRD as part of a parallel /build tick.
  Run Phases 3 → 4 → 5 → 7 for this PRD only. Do not invoke /build
  recursively. Do not touch any PRD other than this one."
- "Acquire `~/.claude/skills/build/state/prd-<slug>.lock` via
  `flock -n` before any state mutation. If you can't acquire it,
  log `prd-lock-held` and exit."
- "When persisting in Phase 7, write your patch object (the keys to merge
  into `prds.<slug>`: `status`, `last_action`, `ticks_invested_delta`,
  `action`, `outcome`, `output_repo_path`, and `last_error` only on
  failure) to a temp JSON file and call
  `scripts/manifest-set.sh <slug> <patch.json>`. Do NOT acquire
  `state/manifest.lock.d` yourself or write manifest.json directly — the
  helper handles the write-ahead intent, the lock (60s ceiling), and the
  per-slug RMW. A non-zero exit means your write did not land (the parent's
  `--replay-orphans` pass will recover it from your intent file); say so in
  your summary."
- "Verdict-receipt protocol (PRD-build-verdict-receipts): before writing
  any NOT-ARCHIVED or blocking verdict that cites test failures, re-run
  the failing subset (or the full suite) once more in a fresh process
  before you commit to the claim — a scheduler hiccup should cost one
  re-run, not a blocked PRD and a human escalation. Record BOTH runs
  (the original red run and the re-run) as receipts via
  `scripts/verdict-receipts.sh record <kind> <slug> [--timeout <secs>]
  -- <command...>` — each call prints a receipt path; reference every
  receipt from your journal line as `receipt: <path>` (one label per
  path). A green re-run means the verdict is `flaky-infra` (both
  receipts referenced, the PRD is NOT blocked on it — journal it for the
  reflect phase); a repeated red means `reproducible` (both receipts
  referenced) and the PRD may block. The words `bisected`,
  `reproducible`, `flaky-infra`, `unreachable`, and `SSH timeout` are
  reserved: use them in a journal line or a PRD `Blocked:` value ONLY
  when the matching receipt(s) exist and are referenced —
  `scripts/verdict-receipts.sh scan <file>` enforces exactly this and is
  what the tick's postflight replays your journal line against.
  `bisected` needs a receipt whose command names `git bisect` and whose
  output names the guilty commit; `unreachable`/`SSH timeout` in a
  `Blocked:` value needs >=2 probe receipts >=60s apart PLUS a
  crosscheck receipt against a second target (a sandboxed shell cannot
  brand a healthy host unreachable off one probe from a degraded
  context)."
- "Return a one-line summary of what you did: `<slug>: <action>
  <outcome>` so the parent's journal sees it."
- "Your Phase 7 journal line's `key=value` tail MUST include `lane=<hostname>`
  (PRD-build-second-lane-carbon lane-tagged journaling) — run `hostname` if
  unsure which lane you're running as."

Issue all calls in a single message — that's what makes them
parallel. Do not chain follow-up Agent calls in the same tick.

### Locking

- `tick.lock` — parent holds for the whole tick (existing behavior).
- `state/prd-<slug>.lock` — each branch holds for its Phase 4–7 work.
  `flock -n`; on failure skip + log. **The lock MUST be tied to the
  branch agent's own process** — wrap the work as
  `flock -n state/prd-<slug>.lock <agent-command>` (or hold the fd open
  9>) so it auto-releases the instant the agent exits. **NEVER hold it
  via a detached guard like `flock -n <lock> sleep 3600 &`** — if the
  agent dies, the orphaned `sleep` (reparented to init) keeps the lock
  for the full hour and every later tick silently skips the PRD on
  `prd-lock-held` (observed 2026-05-29: autobuilder-publish wedged 40min,
  0 ticks). **Stale-lock reclaim:** before honoring `prd-lock-held`, a
  tick checks the holder — if `fuser` shows no process, or the holder's
  parent is PID 1 (orphan), reclaim the lock (kill the orphan if it's a
  bare `sleep`) and proceed; the PRD is not actually being worked.
- `state/manifest.lock.d` — a mkdir-based lock (macOS has no `flock`)
  held briefly per write around the read-modify-write of a single
  `prds.<slug>` entry. Branches do NOT acquire it directly: they call
  `scripts/manifest-set.sh <slug> <patch.json>`, which writes a
  write-ahead `state/intent/<slug>.json` first, then blocks on the lock
  (retry every 0.2s, hard 60s ceiling — not the old 5s give-up), RMWs only
  that slug, drops the intent, and releases the lock. The parent runs
  `scripts/manifest-set.sh --replay-orphans` after all branches return to
  apply any intent whose write never landed. This makes a Phase-7 write
  durable under contention and across mid-acquire crashes — the failure
  mode that caused silent manifest loss (2026-05-30 9-way; 2026-06-02
  6-way, 2/6 branches dropped). Implementation:
  `scripts/manifest-set.sh` (single helper for both the per-slug write and
  the parent replay).
- `<repo>/.git/autobuilder-integrate.lock` — held (blocking, ≤120s) by
  `worktree-extend.sh integrate` so same-repo integrations serialize.
  Internal to the helper; branches don't manage it directly.

### Worktree isolation (shared `build_into`, added 2026-05-28)

When a tick selects ≥2 rust-extend PRDs that share one `build_into`
repo, the branches do **not** mutate that repo in place. The expensive
work (cargo build/clippy/test/deny) runs in parallel, each branch in its
own git worktree; only the cheap final step (merge + version bump +
changelog) is serial. Mechanics live in `scripts/worktree-extend.sh`:

1. **add** — `worktree-extend.sh add <repo> <slug>` creates (or resumes)
   a worktree at `~/.cache/build-worktrees/<repo>-<slug>` on branch
   `autobuilder/<slug>`, based on `<repo>`'s current `main` HEAD. The
   branch agent `cd`s into the printed path for ALL its Phase-4 work.
   The worktree is a clean checkout of `main`'s HEAD — any dirty files in
   the main working tree are isolated and ignored.
2. **build + gate (parallel, in the worktree)** — edit `src/`/`tests/`,
   run the hard gates, and commit the IMPLEMENTATION on the branch
   (`git commit` inside the worktree). Do **not** bump the version or
   touch `CHANGELOG.md` here — that is deferred to integration so stacked
   branches don't collide on the same version number.
3. **integrate (serial, locked)** — `worktree-extend.sh integrate [--no-rebase] <repo>
   <slug> <bump> <tldr-file>` takes the per-repo integration lock,
   **refuses if the target's main tree is dirty (exit 3 → leave PRD
   in_progress, surface `target-dirty`)**, merges `autobuilder/<slug>`
   into `main` (`--no-ff`), then bumps the version and prepends the
   CHANGELOG via `extend-handler.sh`, committing with the Joe Yen
   identity. Because the bump happens here under the lock, sequential
   branches increment cleanly (e.g. recall 0.5→0.6→0.7 across three
   branches in one tick).

   **Rebase-retry on merge conflict (loom-rebase-retry).** When two
   branches share the same `build_into` target and the first one lands,
   the second's `integrate` will conflict. Instead of immediately
   deferring (the old exit 4 loop), integrate now auto-rebases the
   loser: it runs `git rebase <main_head>` inside the branch's worktree
   (the primary tree stays on `main` and clean), then runs a fast
   `cargo check --offline` guard in the worktree, then retries the
   merge once. Exit outcomes:
   - Rebase succeeds + check passes + retry merge succeeds → exits 0
     (branch lands one tick later, no human needed).
   - Rebase conflicts → `git rebase --abort`, sidecar records
     `last_error=integrate-conflict:<files>`, exits 4 (branch kept).
   - Rebase succeeds but cargo check fails → rebase aborted, sidecar
     records `last_error=rebase-broke-build`, exits 4 (branch kept).
   - Retry merge still conflicts (should not happen) → exits 4.
   Pass `--no-rebase` to reproduce the old abort-immediately behaviour
   (useful for debugging or non-Cargo repos where `cargo check` is
   meaningless).
   **`Cargo.lock` is regenerated, not merged.** integrate sets up a
   `Cargo.lock merge=ours` driver (`.gitattributes`, created idempotently)
   so the lockfile never *conflicts* on merge, then runs
   `cargo generate-lockfile --offline` (fallback `cargo build --offline`)
   after the source merge and before the bump commit, so the committed
   `Cargo.lock` is canonical for the merged `Cargo.toml` — staged into the
   single bump commit by the existing `git add -A`. Branch agents need not
   and should **not** hand-resolve `Cargo.lock` conflicts; just leave the
   lockfile alone (`Cargo.toml` conflicts are real and still defer). If a
   genuinely new uncached dep needs the network, integrate skips with
   `last_error=lockfile-regen-needs-net` rather than committing a stale
   lock — the source merge lands but is flagged.
4. **intent card refresh (serial, locked)** — PRD-build-intent-card-refresh:
   immediately after `integrate`'s bump commit, still under the same
   per-repo integration lock, run
   `scripts/intent-card-refresh.sh <repo> <prd-path>` and commit its
   result (Joe Yen identity, subject `"agent: refresh intent card for
   <slug>"`) before `push` — same reasoning as the non-shared rust-extend
   path: a card that always names the newest landed PRD instead of
   whichever PRD refreshed it last. Exit 3 (malformed PRD, no parseable
   AC lines) is treated the same as a `target-dirty`/conflict defer:
   leave the PRD `in_progress`, do not push a card-stale head.
5. **push + cleanup** — after a successful integrate (and intent card
   refresh), `wm-push --slug
   <repo>` once, then `worktree-extend.sh cleanup <repo> <slug>
   --drop-branch`. On a deferred branch (dirty target / conflict / red
   gate) run `cleanup` WITHOUT `--drop-branch` so the next tick resumes
   the same branch via `add`.
6. **gate** — same `gate` action as the non-shared rust-extend path (see
   above): `scripts/extend-gate.sh <repo> --head <landed sha>` after this
   push, before the PRD reads `built`. On pass, `ship-tag.sh` tags the
   integrated HEAD (not any individual branch's commit — main's HEAD after
   `integrate` + `wm-push` is what's shipped) and the `Receipts:` line is
   written; on block, `blockers` + `next: gate-red` as above. With ≥2
   integrates landing on one crate this tick, the receipts on main after
   all of them carry only the LAST-landed HEAD — earlier integrates' `gate`
   actions see their receipts superseded by the next integrate before their
   own `gate` runs; only the PRD whose integrate was actually last should
   expect its `gate` action to find HEAD unchanged underneath it.

**Dispatch additions for shared-target branches.** Each such branch's
agent prompt must also include: its `build_into` repo, that it shares the
target this tick so it MUST use `worktree-extend.sh add` and operate only
inside the returned worktree path, that it commits implementation-only on
its branch (no version bump in the worktree), and that it finishes with
`worktree-extend.sh integrate` then `wm-push` + `cleanup`. The
`prd-<slug>.lock` still guards the branch's manifest/journal writes; the
worktree guards the build tree.

**Merge-safe CLI dispatcher registration (cli-register.sh convention).**
When a shared-target branch adds a new CLI subcommand to a binary crate,
it MUST use `scripts/cli-register.sh` instead of editing `src/main.rs`
directly. The root cause of the 2026-06-06 conflict (3/6 branches deferred
on structural `src/main.rs` conflicts) is that appending to a shared file
always conflicts in parallel git branches — even with anchors. The fix is
per-new-file registration:

```
# Step 1 (per-branch): register a new subcommand (creates a new file):
scripts/cli-register.sh <worktree_path> <SubcmdName> <module_path>

# Example:
scripts/cli-register.sh ~/.cache/build-worktrees/concord-bridge Bridge bridge
```

This creates `src/register/<SubcmdName>.register` — a NEW file unique to
this branch. Two parallel branches adding different subcommands create
different files, so git merge auto-resolves with zero conflicts.

After all branches are integrated (post-integrate, before version bump):

```
# Step 2 (post-integrate): assemble the dispatcher from all sidecars:
scripts/cli-assemble.sh <repo_path>
```

This reads all `src/register/*.register` files alphabetically and rewrites
the generated enum + match arms in `src/main.rs` between
`// @build:subcommands-start` and `// @build:subcommands-end` anchors.

**Back-compat:** repos that do NOT call `cli-register.sh` are entirely
unaffected. The sidecar directory and assembly step are opt-in per repo;
free-form `src/main.rs` editing still works for non-shared targets (AC6).

**Append-only shared-library surface (lib.rs convention).** When a
shared-target branch adds new public surface to a library crate (a new
module + re-exports), it MUST use `scripts/lib-register.sh` instead of
free-form editing `src/lib.rs`:

```
# Register a new module (idempotent, append-only):
scripts/lib-register.sh <worktree_path> <module_name> [<pub_use_path>...]

# Example:
scripts/lib-register.sh ~/.cache/build-worktrees/mylib-probe probe \
  "probe::{ProbeReport, Severity}"
```

The script appends `pub mod <module>;` just before a `// @build:modules`
end-of-list anchor, and each `pub use` path just before a
`// @build:reexports` anchor. Re-running with the same args is a no-op
(idempotent grep-guard). On first call in a repo that lacks the anchors,
the script seeds both anchors in-place at the end of the existing `pub mod`
and `pub use` blocks (idempotent — second run does not re-seed). A
malformed `lib.rs` with no `pub mod` block causes the script to exit 3
with a clear message rather than corrupting the file.

Note: `lib-register.sh` uses the anchor-append pattern which CAN conflict
when two branches start from the same base and both seed anchors. For
library crates the rebase-retry safety net mitigates this; for CLI
dispatcher use `cli-register.sh` (sidecar pattern) instead.

**Back-compat:** repos that do not adopt the `// @build:modules` /
`// @build:reexports` anchors are entirely unaffected — the helper is
additive and opt-in per repo. Free-form `lib.rs` editing still works for
non-shared targets.

### Failure isolation

A failing branch does not abort siblings. Per-PRD locks auto-release
on agent process exit. The parent collects all returns; for any
branch that errored, journal `tick-branch-error  <slug>  <reason>`
and leave that PRD's manifest entry unchanged. The next tick
re-selects normally.

If `/rustbuild` rate-limits parallel invocations (not currently
observed), drop the per-tick cap to 3 by editing this section's "up
to 5" wording. The cap is a number in the doc, not in code.

## State files

```
~/.claude/skills/build/state/
├── manifest.json           # { prds: { "<slug>": { status, revision, ... } } }
├── budget.json             # { date: "YYYY-MM-DD", caps: {...}, used: {...} }
├── tick.lock               # parent flock; held for the whole tick
├── manifest.lock.d/        # mkdir-lock, briefly held by manifest-set.sh per RMW
├── intent/<slug>.json      # write-ahead Phase-7 patches; replayed end-of-tick
├── conflict-streaks.json   # per-(repo,pathset) conflict-streak counters
│                           # { streaks: { "<repo-basename>:<pathset>": { count, ... } } }
│                           # written by loom-serial-fallback.sh; read at Phase-2 selection
│                           # to gate serial vs parallel fan-out for a build_into target.
│                           # Fail-open: absent/malformed → all streaks read as 0.
└── prd-<slug>.lock         # one per in-flight PRD branch; ephemeral
```

## Manifest entry shape

```json
{
  "slug": "recall-daemon",
  "path": "/home/jsy/wintermute/rustbuild/PRD-recall-daemon.md",
  "status": "queued|in_progress|notebook|shipped|vanished|needs_classification",
  "build_auto": true,
  "build_target": "rust-cli|rust-lib|rust-extend|shell|hooks|config|notebook|mixed|null",
  "revision": 1,
  "last_action": "2026-05-25T01:23:45Z",
  "output_repo_path": null,
  "output_repo_url": null,
  "version_bump": "patch|minor|major|null",
  "ticks_invested": 0,
  "blockers": [],
  "last_shipped_version": null,
  "rebuild_reason": null,
  "verified_completed": { "c1": null, "c2": null, "c3": null, "c4": null, "c5": null, "c6": null }
}
```

`last_shipped_version` and `rebuild_reason` back the rebuild gate (see the
`archive` action above) — both null until the first ship, then
`last_shipped_version` is set on every archive and `rebuild_reason` is set
by whatever re-queues a shipped PRD (dreamer reconciliation, manual
re-queue). `verified_completed.c1`–`c5` record the five checklist checks;
`c6` records the rebuild-gate verdict (`rebuild-gate-na` for first builds,
`rebuild-gate-ok`/`-indeterminate` for passing re-queues).

For `rust-extend` PRDs, `output_repo_path` is the validated `build_into`
from the PRD, `output_repo_url` stays null (no new repo created), and
`version_bump` mirrors the PRD's `build_version_bump` (default `minor`).

## Budget shape (per day, resets at 00:00 local — telemetry only)

```json
{
  "date": "2026-05-27",
  "caps":  { "repos_created": null, "commits": null, "prds_drafted": null, "ticks": null },
  "used":  { "repos_created": 0, "commits": 33, "prds_drafted": 0, "ticks": 68 },
  "cap_semantics": "all caps null per 2026-05-27 update; nothing blocks"
}
```

All caps are null (unlimited). The `used[k]` counters still increment
so the journal can show daily volume, but no action ever blocks on
budget. If you ever want to reinstate a cap, set the value to a
positive number — the code path that compares `used[k] >= caps[k]` is
still present in the spec, just never triggered while caps are null.

## Hard safety rules

1. **Never force-push.** Push only with `git push` (no `--force`).
2. **Never `rm -rf` outside `~/wintermute/<slug>/target/`** or other
   self-built derivative dirs. Source files and PRDs are append-only
   from this skill's perspective.
3. **Never overwrite existing settings.json without an atomic backup**
   (`settings.json.bak.<ts>`).
4. **Never invoke this skill recursively** — `/build` from inside
   `/build` is a no-op. Parallel branches (Phase 4 fan-out) are NOT
   recursive /build invocations; they're Agent subcalls running one
   PRD's Phases 3–7 inline. A branch agent that decides to invoke
   `/build` is a bug — it must instead complete its assigned PRD and
   return.
5. **Defer to the user on conflict** — if a PRD mentions a target that
   already exists at a different path than the manifest expects, mark
   `needs_classification` and stop.
6. **(Removed 2026-05-25.)** Ticks now run alongside interactive sessions.
   The expectation that the tick "does not compete" with the user's
   terminal is preserved as a *design preference* (still pick
   non-conflicting actions when possible), but no longer a hard skip.
7. **Use Joe Yen identity for wintermute commits** — same as
   `CLAUDE_SELF.md` defaults section.
8. **Parallel branches sharing `build_into` MUST use isolated
   worktrees** — never mutate one repo from two branches in place (the
   second's cargo lock / git index races invalidate the first's work).
   Shared-target branches go through `worktree-extend.sh`
   (add → build+gate in the worktree → serial locked integrate); see
   "Worktree isolation". The serializing integration lock plus the
   dirty-tree refusal are load-bearing — a branch that writes directly
   into a shared `build_into` instead of its worktree is a bug.

## PRD frontmatter the skill reads

Add to a PRD's YAML frontmatter (or its plain-text Status header):

```
build_target: rust-cli               # one of: rust-cli, rust-lib, rust-extend,
                                     # kernel-extend, shell, hooks, config,
                                     # notebook, mixed
build_priority: high                 # one of: high, normal, low (default normal)
build_into: /abs/path/to/repo        # required for rust-extend AND kernel-extend
build_version_bump: minor            # rust-extend only: patch|minor|major (default minor)
```

`build_auto` is intentionally absent — the parser ignores it; every PRD
is buildable per the 2026-05-27 update.

Parser notes (`scripts/scan-prds.sh`):
- First-match-wins per key — real frontmatter beats any later
  in-document examples.
- Lines inside ``` fenced code blocks are skipped, so PRDs can include
  the example block above without poisoning their own parse.
- Trailing inline comments (` # ...`) are stripped from values.

PRDs with `build_target: rust-extend` route into the extend Phase 4
path; the existing repo is mutated in place rather than a new one
created. See `scripts/extend-handler.sh` for the mechanical helpers
(validate, current-version, bump-version, install, changelog-prepend).

### Amending PRD frontmatter with vellum

When updating a PRD's `Status:`, `blockers:`, or `iter_log:` from a build tick, prefer `vellum amend` over hand-editing:

```
vellum amend PRD-<slug>.md --set-status shipped
vellum amend PRD-<slug>.md --add-blocker "system: needs reboot"
vellum amend PRD-<slug>.md --append-iter-log "v0.1 — all ACs green"
```

`vellum amend` writes atomically (temp file + rename) and understands all three `deferred_acs` forms. Use `--dry-run` to preview changes. Falls back gracefully if vellum is absent.

`scripts/scan-prds.sh` also uses `vellum scan` as a fast-path when the binary is on `$PATH`, falling back to the bash parser when absent. Both paths emit identical JSON output.

## Manual invocation

- `/build` → run one tick (same as the timer).
- `/build status` → dump manifest as a human-readable table; exit.
- `/build run <slug>` → advance that specific PRD this tick regardless
  of the priority rules.
- `/build pause` → write `state/paused` sentinel; subsequent timer
  fires exit immediately. `/build resume` clears it.

## Disable

```
systemctl --user disable --now claude-build.timer
```

Re-enable with `enable --now`. The skill itself stays usable manually
either way.

## Local tool integration

The tick has a small standard kit it reaches for. Prefer these over
hand-rolled equivalents — they emit structured output, are idempotent,
and self-review already understands their state files.

- **`txn-edit`** — snapshot/commit/rollback for any multi-file mutation
  in Phase 4 (settings.json + hook install, README + REPOS.md updates
  in Phase 5 new-repo path). One txn per logical action; commit only
  after the new wiring is smoke-tested.
- **`wchg`** — scope guard around Phase 4 install/wire (see that
  bullet). Cheap to keep watches registered across ticks; only reset
  on PRD ship.
- **`sbx --no-net`** — wrapper for running PRD-declared smoke commands
  that haven't been vetted yet (the PRD ships a `verification` field
  pointing at a shell command; first invocation should be sandboxed).
- **`procstat snap`** — capture peak RSS / IO bytes against the
  `/rustbuild` invocation PID for runaway-iteration receipts. Optional;
  useful when a tick advances the same PRD ≥3 times without progress.
- **`ctrace query`** — for post-hoc forensics if a tick writes outside
  its scope-check and the wchg delta isn't enough to explain why.
  Today's session ndjson lives under `~/.cache/ctrace/sessions/`.

The kernel tier (`memlog`, `provfs`, `agentns`) is opt-in at boot via
`linux-wintermute`. Don't depend on it from the tick logic — `provfs`
xattrs and `agentns` session ids are nice-to-have provenance, not
required for any Phase 4 action.
