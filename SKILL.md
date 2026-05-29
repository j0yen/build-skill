---
name: build
description: Continuously implement queued PRDs end-to-end — scan for new PRDs, build them (delegating to /autobuilder for Rust), wire them into the system, publish them as standalone GitHub repos under j0yen, update Abouts (per-repo READMEs + wintermute REPOS.md), and draft follow-on PRDs that expand Claude's own capabilities. Runs every 5 minutes via systemd-user timer; up to 5 PRDs advanced in parallel per tick (one action per PRD). Use when the user says /build, when the SessionStart hook reports a queued PRD, or when the user asks Claude to "make progress on the queue" or "build the next thing."
---

# /build — continuous PRD implementation loop

`/build` is the autonomous self-extension loop. It looks at the PRDs Claude
and the user have written under `~/wintermute/autobuilder/` and walks each
one from "drafted" through "shipped" — implementing, wiring, publishing,
documenting, then drafting whatever follow-on PRDs the experience made
obvious.

Cadence is **every 5 minutes** (systemd-user timer `claude-build.timer`).
Per tick, the skill advances **up to 5 PRDs in parallel** — one action
per PRD, dispatched as parallel Agent (subagent) tool calls in a single
tool-use message, then collected. The per-PRD one-action invariant is
preserved; only fan-out per tick changed (2026-05-28: 1 → 5 per user
request). Worst-case blast radius is 5×288 = 1440 small changes/day,
still bounded and each independently revertable. See the "Parallelism"
section for selection, dispatch, locking, and failure isolation.

**Auto-publish is the default, no opt-outs, no daily caps (updated
2026-05-27).** Every PRD is buildable — `build_auto` is no longer
parsed; the parser treats every PRD as auto-buildable regardless of
frontmatter. Notebook PRDs included. External state mutations (new
GitHub repo creation, push, settings.json edit, hook install,
follow-on PRD commit+push) are all on. Daily budget caps are set to
null (unlimited); `budget.json` still records `used[k]` counters as
telemetry but never blocks an action.

User explicitly authorized (2026-05-25, expanded 2026-05-27):
- Public GitHub repos under `j0yen/<slug>`
- `~/.local/bin/` binary install
- `~/.claude/scripts/` hook symlinks
- `~/.claude/settings.json` edits (with timestamped backups)
- Follow-on PRD authorship into `~/wintermute/autobuilder/`
- New tool/mechanism vectors as needed

## Inputs

- **PRDs:** `~/wintermute/autobuilder/PRD-*.md` (excluding `PRDs-archive/`).
- **Manifest:** `~/.claude/skills/build/state/manifest.json` — per-PRD
  status, last_action timestamp, blockers, output repo URL when published.
- **Budget:** `~/.claude/skills/build/state/budget.json` — per-day caps
  on net-external actions (defaults: 1 new repo/day, 5 commits/day,
  1 follow-on PRD/day).
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

Run `scripts/scan-prds.sh`. This emits a JSON list of
`{path, slug, status, build_auto, last_modified}` for every PRD under
`~/wintermute/autobuilder/` (top-level only). Diff against `manifest.json`:

- **new** PRDs → add to manifest with `status: queued`, log "discovered
  PRD-<slug>".
- **modified** PRDs → reset `last_action` and bump `revision`.
- **deleted** PRDs (file gone) → mark `status: vanished` in manifest;
  don't actively clean up.

### Phase 2 — Select

Build a candidate pool in priority order:

1. PRDs whose manifest `status` is `in_progress` and `last_action` is
   ≥ 1 hour ago (continue interrupted work).
2. PRDs with `status: queued` (start new work; `build_auto` is no
   longer consulted).
3. None → "nothing to do," log, exit.

Within both buckets, sort by `build_priority` descending
(`high` > `normal` > `low`; null counts as `normal`), then by
`last_modified` ascending (oldest queued first within a priority).
PRDs the user has explicitly bumped to `build_priority: high` get
picked before their normal-priority siblings.

Then pick **up to 5 PRDs** from the pool that mutually satisfy the
parallel-dispatch rules in the "Parallelism" section (no shared
`build_into`, ≤1 kernel-extend, ≤1 reflect-eligible). Fewer than 5 is
fine; the cap is 5, the floor is whatever the queue admits after
conflict-pruning. If the pool yields zero, exit clean.

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
whichever advances that PRD by one well-defined step. The 1..=5 PRDs
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
  manifest. **If this branch shares `build_into` with another branch
  this tick, cwd is the worktree from `worktree-extend.sh add <build_into>
  <slug>`, NOT `build_into` itself** (see "Worktree isolation").
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
- **push** [rust-extend only]: `wm-push --slug <slug>` from inside
  `<build_into>`. `wm-push` (installed at `~/.local/bin/wm-push` per
  PRD-build-push-allowlist) wraps `git push origin <branch>` with a
  slug-regex + allow-list + origin-URL match + branch-equals-current
  + fast-forward + ≥1-commit-ahead guard, and has a settings.json
  allow rule (`Bash(wm-push:*)`) so it doesn't trigger the auto-mode
  classifier on every tick. If `wm-push` is not on `$PATH`, log
  `wm-push-missing` to the journal and set the manifest entry's
  `next: interactive-push` so a human can finish. Same `next:
  investigate-push-guard-failure` shape if `wm-push` exits 2 with a
  guard rejection (distinguish from classifier blocks). New slugs
  need to be added to the `ALLOW` array near the top of `wm-push` —
  keep it in sync with `wm-publish`'s ALLOW and `~/wintermute/REPOS.md`.
  Counts as one tick action and bumps `budget.used.commits`.
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
- **publish** [new-repo only — never for rust-extend]: Create the GitHub repo via the `wm-publish` wrapper:
  ```
  wm-publish --slug <slug> --description "<one line from the PRD>"
  ```
  `wm-publish` (installed at `~/.local/bin/wm-publish` per
  PRD-build-publish-allowlist) wraps `gh repo create j0yen/<slug>
  --public --source=. --remote=origin --push --description=…` with a
  slug-regex + allow-list guard, and has a settings.json allow rule
  (`Bash(wm-publish:*)`) so it doesn't trigger the auto-mode
  classifier on every tick. If `wm-publish` is not on `$PATH`, log
  `wm-publish-missing` to the journal and skip the publish step (the
  PRD stays `in_progress` for the next reflect). New slugs need to be
  added to the `ALLOW` array near the top of `wm-publish` — keep it
  in sync with `~/wintermute/REPOS.md`.

  After the publish lands, write the initial `README.md` from the
  PRD's TL;DR + acceptance tests + an "Install" block. Update
  `~/wintermute/REPOS.md` with a one-line entry under the appropriate
  category section. Bump `budget.used.repos_created`.
- **archive**: When the PRD passes the **verified-completed** checklist
  (all five must hold), move the PRD to
  `~/wintermute/autobuilder/PRDs-archive/` via `git mv`, update manifest
  to `status: shipped`, commit with the Joe Yen identity
  (`git -c user.email=jyen.tech@gmail.com -c user.name="Joe Yen"`).
  The commit message must include a `Verified-completed:` trailer
  listing the five checks that passed.

  **Verified-completed checklist (new-repo path):**
  1. `output_repo_path` exists locally AND `cargo test --release`
     (or the PRD's declared test command) exits 0.
  2. `output_repo_url` is set in the manifest AND `gh repo view <slug>`
     succeeds (i.e., the repo is on GitHub, public, with the latest
     commits pushed).
  3. README.md exists in the repo root, opens with the PRD's TL;DR,
     and contains an Install section.
  4. `~/wintermute/REPOS.md` lists this repo under its category with a
     one-line description.
  5. Every acceptance test the PRD declared (numbered list under
     `## Acceptance` / `## Acceptance tests`) is paired with either a
     passing `cargo test` name or a smoke-test command in the manifest
     `verification` field. If any AC has no paired evidence, the PRD
     is NOT verified-completed — leave `status: in_progress` and
     surface the gap in the next reflect cycle.

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

No caps block this action — `budget.caps` are all null.

### Phase 7 — Persist & log

Each branch (per selected PRD) persists its own work:

- Acquire `state/manifest.lock` (blocking flock, sub-second hold);
  read `manifest.json`, update only this branch's slug entry,
  atomic-write (tempfile + rename); release `manifest.lock`.
- Append a one-line summary to `~/brain/journal/build/YYYY-MM-DD.md`:
  `<ISO-ts>  <slug>  <action>  <outcome>  (<key=value...>)`. The
  journal append is naturally serial — each branch appends its own
  line. Use `>>` to avoid clobbering.
- Release this branch's `state/prd-<slug>.lock`.

After all parallel branches return, the parent releases `tick.lock`.

## Parallelism (per-tick fan-out, added 2026-05-28)

Each tick advances **up to 5 PRDs in parallel**. The per-PRD
constraint (one action per PRD per tick) is preserved unchanged;
only the per-tick fan-out grew (1 → 5). User instruction
2026-05-28: "this laptop can handle it."

### Selection rules (extends Phase 2)

After the existing priority sort, pick up to 5 PRDs that mutually
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
2. **≤1 `build_target: kernel-extend` per tick** — the kernel
   `makepkg` build saturates the box (load avg ≥ 10 single-threaded);
   running two in parallel triples wall time without finishing faster.
3. **≤1 Phase-6-eligible reflect candidate per tick** — the
   daily-reflect cap still applies (once per day across all branches).
   If two candidates would otherwise both trigger reflect, designate
   one as reflect-eligible and the other skips Phase 6.

Fewer than 5 is fine. Selection is greedy — walk the sorted candidate
pool, admit each PRD that doesn't violate a rule against already-
admitted ones, stop at 5 or end-of-pool.

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
(this skill, selecting/dispatching/journaling) stays on the session model
(Opus) — it makes the judgment calls. **Escalate a branch to
`model: "opus"`** when any of:
- the PRD declares `build_priority: high` AND its shape is architectural /
  ambiguous (new subsystem, cross-cutting design), not a mechanical extend;
- `build_target: kernel-extend` (hand-written C, subtle, no autobuilder
  gate — wants the stronger model);
- the PRD's manifest entry shows it failed or stalled on a prior tick
  (`last_error` set, or `ticks_invested ≥ 3` with no status change) —
  retry one tier up before giving up.
Pass the chosen model via the Agent call's `model` field. When unsure,
default to Sonnet; the escalation list is the only reason to go Opus.

Each agent prompt must include, self-contained:

- The PRD's absolute path.
- The PRD's slug.
- "You are advancing ONE PRD as part of a parallel /build tick.
  Run Phases 3 → 4 → 5 → 7 for this PRD only. Do not invoke /build
  recursively. Do not touch any PRD other than this one."
- "Acquire `~/.claude/skills/build/state/prd-<slug>.lock` via
  `flock -n` before any state mutation. If you can't acquire it,
  log `prd-lock-held` and exit."
- "When persisting in Phase 7, acquire `state/manifest.lock`
  (blocking), do a read-modify-write of your slug's entry only,
  release. Do NOT rewrite other slugs' entries."
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
- `state/manifest.lock` — held briefly (sub-second) by each branch
  around manifest read-modify-write. `flock` blocking.
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
3. **integrate (serial, locked)** — `worktree-extend.sh integrate <repo>
   <slug> <bump> <tldr-file>` takes the per-repo integration lock,
   **refuses if the target's main tree is dirty (exit 3 → leave PRD
   in_progress, surface `target-dirty`)**, merges `autobuilder/<slug>`
   into `main` (`--no-ff`; exit 4 on conflict → defer, branch kept),
   then bumps the version and prepends the CHANGELOG via
   `extend-handler.sh`, committing with the Joe Yen identity. Because the
   bump happens here under the lock, sequential branches increment
   cleanly (e.g. recall 0.5→0.6→0.7 across three branches in one tick).
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
├── manifest.json        # { prds: { "<slug>": { status, revision, ... } } }
├── budget.json          # { date: "YYYY-MM-DD", caps: {...}, used: {...} }
├── tick.lock            # parent flock; held for the whole tick
├── manifest.lock        # briefly held around manifest read-modify-write
└── prd-<slug>.lock      # one per in-flight PRD branch; ephemeral
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
  "blockers": []
}
```

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
