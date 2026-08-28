# /build — PRD intake contract

What this `/build` parses from a PRD. `/dream` reads this file at the start of
every run (Phase −1, build-contract discovery) and writes PRDs to it. Keep it in
step with `scripts/scan-prds.sh`, `scripts/verified-completed.sh`, and the
Phase 3 routing table in `SKILL.md`; a PRD that does not match this contract is
stranded as `needs_classification`.

## Where PRDs live

- Workspace: `~/Documents/PRDs/` = clone of `j0yen/prds` (private, shared
  across machines). Queue: `build-queue/PRD-*.md` — the only directory
  `/build` reads new work from. Done: `built-prds/` (moved there on ship;
  legacy `ARCHIVE/`/`archive/` read as aliases). Parked: `parked/` — never
  scanned; a human moves files in and out.
- Visions: `visions/`. Project profiles: `projects/`. Logs: `notes/`.
- The PRD's frontmatter is the shared state; `manifest.json` is a local cache.
- Filename `PRD-<slug>.md`; slug `^[a-z0-9]+(-[a-z0-9]+)*$`; the slug names the
  repo on publish.

## Frontmatter

First 80 lines. Bullet (`- key: value`), bare (`key: value`), and bold
(`**key:** value`) forms are all read; trailing `# comments` are stripped; lines
inside fenced code blocks are ignored; first match wins.

| key | values | required | notes |
|---|---|---|---|
| `Status` | `queued` (dream) → `building` / `built` / `blocked` (build) | yes | display + lifecycle |
| `build_target` | `rust-cli` `rust-lib` `rust-extend` `kernel-extend` `shell` `hooks` `config` `notebook` `mixed` — and `python-cli` `python-lib` `python-agent` (routes to `/pybuilder`; wiring pending in this skill, see Follow-ups) — `product` is skipped, not built | yes | anything else → `needs_classification` |
| `build_into` | absolute path of the repo to mutate | for `rust-extend`, `kernel-extend`, and any `python-*` that extends an existing repo | must exist locally at build time |
| `build_priority` | `high` `normal` `low` | no | queue order; default `normal` |
| `build_version_bump` | `patch` `minor` `major` | no | `rust-extend` only; default `minor` |
| `deferred_acs` | inline list of bare integers, e.g. `[3, 4]` | no | block-list or `AC3` forms parse to `[]` silently |
| `mock_unjustified_for` / `mock_justifications` | see SKILL.md C5 | with deferred ACs | one sentence per deferred AC |
| `publish` | `j0yen/private` `j0yen/public` `none` | recommended | new key — org + visibility for the shipped repo. Until Phase 4 honours it, `/build` still routes by directory (see Follow-ups) |
| `Vision` | `visions/<slug>.md` | yes | |
| `Depends-on` | `PRD-<slug>.md`, comma-separated | no | reconciler resolves against git |
| `Loop` | `<loop-name>: <metric it moves>` | for loop-ready fleets | read by the buildloop's digest/dream phases, ignored here |

Keys `PM`, `Drafted`, `Owner`, `Date`, `Relates`, `Engineering target`, `Jira`,
`Epic` are display-only.

## Acceptance criteria

Section heading `## Acceptance criteria` (also accepted: `## Acceptance`,
`## Acceptance tests`). Each AC is one line starting `N. ` (digit, dot,
space) — that regex is what `verified-completed.sh` counts. Write the level
inline and keep Given/When/Then on that line:

```
1. P0 — Given an empty document, When a viewer GETs it, Then 200 with empty body.
2. P1 — Given 50 concurrent readers, When ..., Then p95 < 150 ms.
```

`AC-1:` prefixes, tables, or unnumbered prose are not counted; the C5 archive
gate then sees zero ACs.

## Language routing

- `rust-*` → `/autobuilder`, all cargo through `/cloudbuild` (no local cargo).
- `python-*` → `/pybuilder` (planned; today this skill has no python row).
- `shell`/`hooks`/`config` → direct edits. `kernel-extend` → hand-written C.

## Publish (current behaviour, to be changed)

Directory-keyed: PRDs under `~/Documents/PRDs` publish to `joeyen-atscale`
private; PRDs under `~/wintermute/PRDs` (scan paused) publish to `j0yen` public
via `wm-publish`. Neither fits post-AtScale personal work; the `publish` key
above is the intended replacement.

## Follow-ups (tracked, not yet done — 2026-08-27)

1. Honour `publish:` in Phase 4 (default `j0yen/private`); retire the
   `joeyen-atscale` route (org access is gone).
2. Add the `python-*` → `/pybuilder` routing row and C1–C5 substitutions.
3. Accept `archive/` as an alias of `ARCHIVE/` when reading, so kit-style
   workspaces scan cleanly.
