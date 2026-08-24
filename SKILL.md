---
name: build
description: Continuously implement queued PRDs end-to-end — scan for new PRDs, build them (delegating to /autobuilder for Rust, cargo via /cloudbuild), wire them into the system, publish them as standalone private GitHub repos under joeyen-atscale (AtScale work — carbon's primary mode as of 2026-08-03), update Abouts (per-repo READMEs + wintermute REPOS.md), and draft follow-on PRDs that expand Claude's own capabilities. Personal wintermute PRDs (j0yen/public) are paused, not deleted — see the "Personal wintermute pipeline (paused)" note below. Runs on manual invocation or systemd-user timer when enabled; up to 30 PRDs advanced in parallel per tick (one action per PRD). Use when the user says /build, when the SessionStart hook reports a queued PRD, or when the user asks Claude to "make progress on the queue" or "build the next thing."
model: sonnet
---

# /build — continuous PRD implementation loop

`/build` is the autonomous self-extension loop. As of 2026-08-03, carbon's
`/build` targets **AtScale work primarily**: it looks at the PRDs under
`~/Documents/PRDs/` (a clone of `joeyen-atscale/atscale-prds`) and walks each
one from "drafted" through "shipped" — implementing, wiring, publishing,
documenting, then drafting whatever follow-on PRDs the experience made
obvious.

**Personal wintermute pipeline (paused, not deleted).** Carbon previously ran
this same loop against `~/wintermute/PRDs/` (published under `j0yen/public`
via `wm-publish`). That pipeline, its manifest, its 196 shipped + 72 archived
PRDs, and `wm-publish` itself are all still intact — `/build` just no longer
scans that directory for new work. To resume personal wintermute building,
add `~/wintermute/PRDs/PRD-*.md` back to the Inputs scan below (or ask Claude
to do it) — nothing was removed, only the scan target changed.

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
- Private GitHub repos under `joeyen-atscale/<slug>` — AtScale/corporate work,
  the default target as of 2026-08-03 (direct `gh repo create`, no wrapper
  yet — see the publish phase below).
- Public GitHub repos under `j0yen/<slug>` — personal wintermute work, the
  original target (via `wm-publish`). **Paused, not revoked**: `/build`
  doesn't scan `~/wintermute/PRDs/` for new work right now, so this path
  won't be exercised, but the authorization and the wrapper both still
  stand if personal building resumes.
- `~/.local/bin/` binary install
- `~/.claude/scripts/` hook symlinks
- `~/.claude/settings.json` edits (with timestamped backups)
- Follow-on PRD authorship into `~/Documents/PRDs/` (current default) or
  `~/wintermute/PRDs/` (if personal building resumes), matching the source
  PRD's provenance
- New tool/mechanism vectors as needed

## Inputs

- **PRDs:** `~/Documents/PRDs/PRD-*.md` (top-level = buildable queue;
  `ARCHIVE/` entries are scanned but treated as already-done — never
  re-queued). This is a clone of `joeyen-atscale/atscale-prds`.
  `~/wintermute/PRDs/PRD-*.md` (personal wintermute work, `j0yen`) is NOT
  scanned as of 2026-08-03 — paused, see the note under Personal wintermute
  pipeline above.
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

Run `PRD_DIR=~/Documents/PRDs scripts/scan-prds.sh` (the explicit `PRD_DIR`
matters — the script's own internal default is `~/wintermute/autobuilder`,
which is neither this path nor the paused personal path, and must never be
relied on implicitly). This emits a JSON list of
`{path, slug, status, build_auto, last_modified}` for every PRD under
`~/Documents/PRDs/` (top-level only). Diff against `manifest.json`:

- **new** PRDs → add to manifest with `status: queued`, log "discovered
  PRD-<slug>".
- **modified** PRDs → reset `last_action` and bump `revision`.
- **deleted** PRDs (file gone from top-level AND gone from `ARCHIVE/`) → mark
  `status: vanished` in manifest; don't actively clean up.
- **archived** PRDs (file gone from top-level but present in `ARCHIVE/`) → mark
  `status: archived`; **never re-queue**. scan-prds.sh now emits ARCHIVE/ entries
  so Phase 1 can distinguish archived from truly-vanished. A manifest entry whose
  scan path contains `/ARCHIVE/` is always treated as archived.

### Phase 2 — Select

Build a candidate pool in priority order:

1. PRDs whose manifest `status` is `in_progress` and `last_action` is
   ≥ 1 hour ago (continue interrupted work).
2. PRDs with `status: queued` (start new work; `build_auto` is no
   longer consulted).
3. None → "nothing to do," log, exit.

**Hard pre-filter (applied before the pool, removes entries that must not run):**
- `status: archived` or `status: vanished` → never selectable; skip silently.
- PRD file is absent from top-level AND present in `ARCHIVE/` → force `status:
  archived` in the manifest right now and skip; do NOT dispatch a cloud agent.
- PRD file is absent from top-level AND absent from `ARCHIVE/` → force `status:
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

### Phase 2.5 — Session warm-up

After selection (Phase 2) and before dispatching branches (Phase 4):

1. **Count cargo-bound PRDs** in the selected set — any PRD whose
   `build_target` is `rust-cli`, `rust-lib`, or `rust-extend` (i.e.,
   it will invoke `cargo` via cloudbuild).
2. **If ≥1 cargo-bound PRD exists**, start a cloudbuild session so all
   branch agents reuse one warm server instead of each spinning up and
   destroying their own:
   ```
   bash ~/.claude/skills/cloudbuild/cloudbuild.sh session-start
   ```
   Log the returned IP and record that the session is active for this tick.
   The session lock at `~/.config/wm-burst/session.lock` causes every
   subsequent `cloudbuild build/test` call in any branch to transparently
   reuse the warm server — no branch-level change needed.
3. **If 0 cargo-bound PRDs**, skip session-start — no server is needed.

This is Phase 2.5 so it runs ONCE in the parent, before fan-out.
The watchdog (`cloudbuild-watchdog.sh`) still kills any server older than 2h
as a safety net if session-end is never reached (crash, OOM-kill, etc.).

### Phase 3 — Classify

Read the PRD. Determine its implementation shape:

- **Rust crate / lib / CLI** → delegate to `/autobuilder`. The PRD is
  the input; the skill runs `/autobuilder` in this conversation with
  the PRD path as the argument, then captures the result repo path and
  acceptance-test verdict.
- **Rust extend** (`build_target: rust-extend`) → the PRD declares an
  existing repo to extend, via `build_into: <abs-path>`. The skill
  validates the target with `scripts/extend-handler.sh validate <slug>`;
  if validation fails, mark `needs_classification` and stop. Otherwise
  set `status: in_progress`, set `output_repo_path` to the validated
  `build_into`, and route to the Phase 4 extend path. NEVER calls
  `gh repo create` for this target type — the repo already exists.
- **Kernel extend** (`build_target: kernel-extend`) → the PRD extends
  one of `~/wintermute/{agentns,memlog,provfs/lsm}` or proposes a new
  kernel feature. `/autobuilder` does NOT handle this — autobuilder is
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
- **Mixed** (Rust + hooks) → do the Rust portion via `/autobuilder` this
  tick; queue the hook portion for the next tick.

If classification is ambiguous, mark the PRD `status: needs_classification`
and emit one line in the journal asking the user to add a hint to the PRD
frontmatter (e.g., `build_target: rust-cli`).

### Phase 4 — Implement (one action per selected PRD)

For each PRD selected in Phase 2, do exactly ONE of the following —
whichever advances that PRD by one well-defined step. The 1..=30 PRDs
in this tick's selection run in parallel via Agent tool calls
(see "Parallelism" below). Each branch stops after its action.

- **iter-1 (scaffold)**: For a Rust target, invoke `/autobuilder` with
  the PRD path. Let autobuilder run its own loop. Capture the result
  in the manifest as `output_repo_path`.
- **iter-1 (extend-scaffold)** [rust-extend only]: invoke
  `/autobuilder --extend <build_into>` with the PRD path. If
  `/autobuilder` doesn't yet support `--extend`, fall back to running
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
  `/autobuilder`. Hand-write the kernel C source per the PRD spec:
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
- **iter-2..N (continue)**: If `/autobuilder` left work, hand the same
  PRD back to it. Each `/autobuilder` invocation IS one tick's action;
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
    `~/wintermute/autobuilder/notes/gossip.md` naming the unit that was
    installed-but-not-restarted. Build still exits 0. Verdict:
    `install-m755-fallback`.
  - If no unit backs the dest: plain `install -m755`, unchanged
    behaviour. Verdict: `install-m755`.
  The chosen verdict is echoed to stderr as `[install-verdict]` for the
  per-tick log. Non-daemon-backed CLIs, libs, hooks, and config targets
  are entirely unaffected — no `rollout` invocation, no behavioural diff.

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
- **publish** [new-repo only — never for rust-extend]: **Org depends on PRD
  provenance — this is a hard safety boundary (guard ported 2026-08-03 from
  ryzen7's build skill; re-scoped the same day when carbon went
  AtScale-primary). The two must never cross.**
  - **AtScale/corporate PRDs (default, sourced from `~/Documents/PRDs/`,
    authored by `/dream-atscale`, or carrying a `build_target`/`build_into`
    field pointing at AtScale work):** publish directly:
    ```
    gh repo create joeyen-atscale/<slug> --private --source=. --remote=origin --push --description="<one line from the PRD>"
    ```
    Log `atscale-publish-direct` to the journal. There's no allow-listed
    wrapper for this path yet (low volume so far) — if it becomes routine,
    build a `wm-publish-atscale` script mirroring `wm-publish`'s guard rails
    (slug-regex, allow-list, origin-exists check) targeting
    `joeyen-atscale --private`.
  - **Personal wintermute PRDs (paused — only relevant if `~/wintermute/PRDs/`
    scanning is re-enabled):** create the GitHub repo via the `wm-publish`
    wrapper:
    ```
    wm-publish --slug <slug> --description "<one line from the PRD>"
    ```
    `wm-publish` (installed at `~/.local/bin/wm-publish`) wraps `gh repo
    create j0yen/<slug> --public --source=. --remote=origin --push
    --description=…` with a slug-regex + allow-list guard, and has a
    settings.json allow rule (`Bash(wm-publish:*)`) so it doesn't trigger
    the auto-mode classifier on every tick. New slugs need to be added to
    the `ALLOW` array near the top of `wm-publish` — keep it in sync with
    `~/wintermute/REPOS.md`.
  - **The guard is bidirectional and must never be crossed**: AtScale PRDs
    never go to `j0yen`; personal PRDs never go to `joeyen-atscale`. If
    provenance is ambiguous, stop and ask rather than guessing. `wm-publish`
    is `j0yen`/public-only — calling it on an AtScale PRD would leak private
    work into a public personal repo.

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
  five must hold) **AND the rebuild gate passes**, update manifest to
  `status: shipped`, then move the PRD file into `ARCHIVE/` and commit +
  push. Path and identity depend on the same provenance guard as publish
  above:
  - **AtScale PRDs (default)** — push to `joeyen-atscale/atscale-prds`:
    ```
    cd ~/Documents/PRDs
    git mv PRD-<slug>.md ARCHIVE/
    git commit -m "archive: <slug> shipped"
    git push
    ```
  - **Personal wintermute PRDs (paused)** — push to `j0yen/autobuilder-private`:
    ```
    cd ~/wintermute/PRDs
    git -c user.name=j0yen -c user.email=jyen.tech@gmail.com mv PRD-<slug>.md ARCHIVE/
    git -c user.name=j0yen -c user.email=jyen.tech@gmail.com commit -m "archive: <slug> shipped"
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
  1. `output_repo_path` exists locally AND `cargo test --release`
     (or the PRD's declared test command) exits 0.
  2. `output_repo_url` is set in the manifest AND `gh repo view
     joeyen-atscale/<slug>` (or `j0yen/<slug>` on the paused personal path)
     succeeds — i.e., the repo is on GitHub, correct visibility for its org
     (private for `joeyen-atscale`, public for `j0yen`), with the latest
     commits pushed.
  3. README.md exists in the repo root, opens with the PRD's TL;DR,
     and contains an Install section.
  4. `~/wintermute/REPOS.md` lists this repo under its category with a
     one-line description.
  5. Every acceptance test the PRD declared (numbered list under
     `## Acceptance` / `## Acceptance tests`) is paired with EITHER:
     - a passing `cargo test` name (real test) or a smoke-test command
       in the manifest `verification` field, OR
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
     hardware-mock convention (see `~/.claude/skills/autobuilder/SKILL.md`
     "Hardware mock convention") with the older `deferred_acs:` escape
     hatch: deferring is honest, but a deferred AC must still take a
     mock-test path or carry a prose justification. It is back-compat —
     already-shipped PRDs whose deferred ACs gain a `mock_unjustified_for:`
     + justification backfill still pass.

  **Verified-completed checklist (rust-extend path):**
  Same as above with three substitutions:
  - Check #2 becomes: remote `origin` exists for `output_repo_path` AND
    the new version-bumped commit is reachable from `origin/main` (or
    the repo's default branch). No `gh repo view` because no new repo
    was created.
  - Check #3 becomes: `CHANGELOG.md` exists in the repo root and has a
    `## v<new-version>` section at the top containing the PRD's TL;DR.
    The repo's existing README.md is NOT required to be regenerated.
  - Check #4 becomes: `~/wintermute/REPOS.md` is unchanged by this
    PRD's tick history (negative AC — the extended repo is already listed).

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
  PRD to PRDs-archive/, the next scan detects it as `vanished` and the
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

- A `/autobuilder` run blocked on a missing primitive → PRD for that
  primitive ("autobuilder needs a JSON-stable receipt for X").
- A wired feature exposed an obvious next step (the existing observer-
  correlation and daemon PRDs are exactly this shape — see them as the
  template).
- A repeated failure pattern across two or more ticks → a PRD
  proposing a guardrail or pattern that prevents it.

Follow-on PRDs go in `~/wintermute/autobuilder/PRD-build-<topic>.md`
with frontmatter `Status: Draft v0.1`. Omit `build_auto` (no longer
parsed). Bump `budget.used.prds_drafted` for telemetry.

**Commit + push the drafted PRD as part of this same tick action.**
Per user instruction 2026-05-27, generated work doesn't accumulate
untracked. Steps:

1. `cd ~/wintermute/autobuilder && git add PRD-build-<topic>.md`
2. `git -c user.email=jyen.tech@gmail.com -c user.name="Joe Yen" commit
   -m "build: draft PRD-build-<topic> (Phase 6 reflect)"` — include a
   one-paragraph body explaining what triggered the reflect.
3. `git push origin main`. Bumps `budget.used.commits` for telemetry.
# After Phase-6 PRD commit: answerable-emit.sh draft <prd-path> "Phase 6 reflect" true

No caps block this action — `budget.caps` are all null.

### Phase 7 — Persist & log

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
  to avoid clobbering.
- Release this branch's `state/prd-<slug>.lock`.

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
- **Session teardown:** if Phase 2.5 started a session, tear it down now:
  ```
  bash ~/.claude/skills/cloudbuild/cloudbuild.sh session-end
  ```
  This destroys the builder server and stops billing. Run this even if some
  branches failed — we want billing to stop regardless. If `session-end`
  fails (network error, server already gone), log it but do not block
  `tick.lock` release.
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
memory grounds.** The box has **15 GB RAM (0 swap), typically ~11 GB
free**. Heavy cargo builds route through cloudbuild (Hetzner), so local
memory pressure is minimal. The real OOM guard is the **≤3 same-target
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

**Cloudbuild (added 2026-06-07, HARDENED 2026-06-16).** All `cargo build`,
`cargo test`, `cargo clippy`, and `cargo deny` invocations inside branch
agents MUST route through cloudbuild. This is non-negotiable per explicit
user instruction 2026-06-16: **local /autobuilder cargo execution is
disabled**. Silent local fallback is not allowed — log it explicitly if
cloudbuild is unavailable and only then proceed locally.

Enforcement: every branch agent MUST export `AUTOBUILDER_CLOUD=1` before
invoking /autobuilder (the autobuilder-cloud fork reads this to activate the
`cargo-cloud` shim). For direct cloudbuild calls:
`bash ~/.claude/skills/cloudbuild/cloudbuild.sh build <crate> -- <args>`.

Before any cargo work: `bash ~/.claude/skills/cloudbuild/cloudbuild.sh status`
— if RUNNING or can be brought up, use cloudbuild. Only skip if status returns
error AND `cloudbuild up` fails after one retry; log "cloudbuild unavailable,
building locally" in that case.

This applies to both new-scaffold and rust-extend branches. Non-cargo work
(Write/Edit, shell scripts, gh, git) stays local. Each agent prompt must
include this directive verbatim: "Export AUTOBUILDER_CLOUD=1 and route all
cargo invocations through cloudbuild. Do NOT run cargo directly on the laptop.
Only fall back to local if cloudbuild.sh status errors AND cloudbuild up fails;
log the fallback explicitly. Do NOT call `cloudbuild session-start` or
`cloudbuild session-end` — the parent tick manages the session lifecycle;
branch agents only call `cloudbuild build` / `cloudbuild test`."

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
- "Return a one-line summary of what you did: `<slug>: <action>
  <outcome>` so the parent's journal sees it."

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
4. **push + cleanup** — after a successful integrate, `wm-push --slug
   <repo>` once, then `worktree-extend.sh cleanup <repo> <slug>
   --drop-branch`. On a deferred branch (dirty target / conflict / red
   gate) run `cleanup` WITHOUT `--drop-branch` so the next tick resumes
   the same branch via `add`.

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

If `/autobuilder` rate-limits parallel invocations (not currently
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
  "path": "/home/jsy/wintermute/autobuilder/PRD-recall-daemon.md",
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
  `/autobuilder` invocation PID for runaway-iteration receipts. Optional;
  useful when a tick advances the same PRD ≥3 times without progress.
- **`ctrace query`** — for post-hoc forensics if a tick writes outside
  its scope-check and the wchg delta isn't enough to explain why.
  Today's session ndjson lives under `~/.cache/ctrace/sessions/`.

The kernel tier (`memlog`, `provfs`, `agentns`) is opt-in at boot via
`linux-wintermute`. Don't depend on it from the tick logic — `provfs`
xattrs and `agentns` session ids are nice-to-have provenance, not
required for any Phase 4 action.
