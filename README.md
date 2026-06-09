# build-skill

Claude Code skill that continuously implements queued PRDs end-to-end —
scans for new PRDs, builds them (delegating to `/autobuilder` for Rust),
wires them into the system, publishes them as standalone GitHub repos,
updates Abouts (per-repo READMEs + a `REPOS.md` index), and drafts
follow-on PRDs that expand Claude's own capabilities.

Designed to run every 5 minutes via a systemd-user timer; one PRD-relevant
action per tick at most. The skill is the autonomous self-extension loop
that pairs with [`dream-skill`](https://github.com/j0yen/dream-skill) — where
`/dream` walks ideas to PRDs, `/build` walks PRDs to shipped repos.

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

## License

Dual-licensed: MIT or Apache-2.0 at your option.
