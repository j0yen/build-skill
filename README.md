# build-skill

A Claude Code skill that walks a queue of PRDs from "drafted" to "shipped" on its own. Each PRD becomes a real GitHub repo — implemented (Rust via `/autobuilder`), wired into the system, documented, and indexed — and the experience of building it seeds the follow-on PRDs that grow the queue.

This is the back half of a self-extension loop. `dream-skill` walks ideas to PRDs; `build-skill` walks PRDs to repos. Run them on a cadence and the system proposes its own next capability, then builds it. See [`j0yen/dream-skill`](https://github.com/j0yen/dream-skill) for the generative half.

## What a tick does

The skill runs every 5 minutes via a systemd-user timer. Per tick it advances up to 30 PRDs in parallel — at most **one action per PRD**, so a given PRD moves one phase per tick (scan → build → wire → publish → document → seed follow-ons) and never races itself. A `flock` guard keeps two ticks from overlapping. State lives under `state/` (per-PRD status in `manifest.json`, telemetry in `budget.json`) and is preserved across re-installs.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/j0yen/build-skill/main/install.sh | bash
```

The installer self-clones the repo into `~/.local/share/build-skill/` and
symlinks `~/.claude/skills/build/` to it. Re-running picks up new commits.
Existing runtime state (`state/manifest.json`, `state/budget.json`) is
rescued across re-installs.

## Repo layout

```
.
├── SKILL.md         # the spec Claude loads
├── install.sh       # mode-1 (local) and mode-2 (curl|bash) installer
├── scripts/
│   ├── scan-prds.sh              # emit JSON describing every PRD
│   ├── clear-stale-blockers.sh   # remove resolved version-collision blockers
│   ├── extend-handler.sh         # rust-extend path helpers
│   ├── manifest-sidecar.sh       # branch Phase-7 sidecar writer (no shared-file race)
│   └── manifest-merge-sidecars.sh# parent post-collection sidecar merger
├── tests/
│   ├── manifest-write-durability.sh  # stress: 12 concurrent writers × 20 runs
│   └── ...
├── state/           # runtime — gitignored
│   ├── manifest.json
│   ├── status/      # ephemeral per-PRD sidecars written by branches
│   └── budget.json
├── LICENSE-MIT
└── LICENSE-APACHE
```

## Timer setup

The timer unit is not installed by this script (it lives in
`~/.config/systemd/user/claude-build.timer` on the author's machine and
isn't appropriate for general distribution). To wire up the 5-min cadence
yourself, create a user unit that runs `claude` with a one-shot
`/build` prompt and a 5-minute `OnUnitActiveSec`.

## See also

- [j0yen/dream-skill](https://github.com/j0yen/dream-skill) — the generative
  counterpart that drafts PRDs from vision
- [j0yen/autobuilder](https://github.com/j0yen/autobuilder) — what `/build`
  delegates to for Rust crate/lib/CLI implementations

## Scope

This is the author's own self-extension loop, not a turnkey product. It reads PRDs from `~/wintermute/PRDs/`, publishes to specific GitHub orgs, and runs fully autonomously — no per-action confirmation gate. Read `SKILL.md` (the spec Claude loads) before pointing it at your own queue, and adjust the paths and publish targets to your setup.

## License

Dual-licensed: MIT or Apache-2.0 at your option.
