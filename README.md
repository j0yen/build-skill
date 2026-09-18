# build-skill

Claude Code skill that continuously implements queued PRDs end-to-end —
scans for new PRDs, builds them (delegating to `/rustbuild` for Rust),
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

## The four-document rule (PRD-build-branch-contract-split)

`SKILL.md` used to be four documents at once — the coordinator's own
procedure, the branch agent's contract, the operator's manual, and the
incident history — and every model touching the loop paid to read all
four, every tick. It is now a ≤200-line index over four separate homes;
new text goes to whichever one it actually is, never back into SKILL.md:

| this is... | goes in | cap |
|---|---|---|
| a directive a dispatched branch agent must follow (Phases 3→4→5→7) | `docs/branch-contract.md` | ≤400 lines, lint-enforced, no dates |
| the coordinator's own phase-by-phase mechanics, or a runbook (manual invocation, re-arm, burst config, status commands) | `docs/operator.md` | none |
| a dated incident, rationale, or "why does the gate do X" | `docs/history.md`, headed with the date + originating PRD slug | none |
| a one-line phase summary, a link, or a script pointer | `SKILL.md` | ≤200 lines, lint-enforced |

`scripts/lint-contract-size.sh` (wired into `scripts/run-selftests.sh
--all`) enforces the two caps; nothing enforces where NEW text lands
beyond this table and reviewer judgment.

## Timer setup

The timer unit is not installed by this script (it lives in
`~/.config/systemd/user/claude-build.timer` on the author's machine and
isn't appropriate for general distribution). To wire up the 5-min cadence
yourself, create a user unit that runs `claude` with a one-shot
`/build` prompt and a 5-minute `OnUnitActiveSec`.

### Dream governor (drafting side)

`scripts/dream-governor.sh` is the drafting-side counterpart:
`claude-build.timer` self-fires `/build` when the queue is non-empty;
`dream-governor.timer` self-fires one headless `/dream` run when the
queue is thin, seeds are pending, and the day's weighted-token headroom
allows it (`scripts/dream-governor.sh check|run|status`; full contract in
the script's own header comment).

The unit ships **disabled** (per PRD-dream-depth-governor: no thresholds
are set yet — `Joe owns DEPTH_MIN/HEADROOM_MAX`). It also refuses on
every fire path until a config file exists at
`state/dream-governor/config` with both set, e.g.:

```
DEPTH_MIN=8
HEADROOM_MAX=500000
```

Once thresholds are set, install and enable with:

```sh
ln -sf ~/.claude/skills/build/systemd/dream-governor.service ~/.config/systemd/user/dream-governor.service
ln -sf ~/.claude/skills/build/systemd/dream-governor.timer ~/.config/systemd/user/dream-governor.timer
systemctl --user daemon-reload
systemctl --user enable --now dream-governor.timer
```

## See also

- [j0yen/dream-skill](https://github.com/j0yen/dream-skill) — the generative
  counterpart that drafts PRDs from vision
- [j0yen/autobuilder](https://github.com/j0yen/autobuilder) — what `/build`
  delegates to for Rust crate/lib/CLI implementations

## License

Dual-licensed: MIT or Apache-2.0 at your option.

## Canonical sources (fleet)

One source per skill, enforced hourly by `fleet-sync` on every node:

| skill | repository | branch | path in repo | clone |
|---|---|---|---|---|
| build | j0yen/build-skill | main | `/` | `~/wintermute/build-skill` |
| pybuild | j0yen/pybuild | main | `skill` | `~/wintermute/pybuild` |
| rustbuild | j0yen/rustbuild | main | `skill` | `~/wintermute/rustbuild` |
| dream | j0yen/vibecode-kit | main | `skills/dream` | `~/wintermute/vibecode-kit` |
| PRD workspace | j0yen/PRDs | main | `/` | `~/Documents/PRDs` |

`~/wintermute` is the repo root for everything the fleet ships or runs.
