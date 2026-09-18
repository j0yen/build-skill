# Host contract

Every ambient default the loop depends on from the RedBaron host, declared
once here so a break in the host looks like a host break, not a new
component bug (PRD-build-host-contract; grounding: six same-shaped
outages on 2026-09-18 — auth file, dispatch lock, shim PATH order, unit
env inheritance, fixture paths, TMPDIR — each an unowned host default).
`scripts/host-contract.sh check` probes every row below; a fix to a
drifted default is a change to THIS table (plus, for a `self-heal` row,
`host-contract.sh apply <key>`), never a patch to the caller that hit it.

The probe runs only where `lane=redbaron` (carbon/ryzen7 are disabled).

| key | expected | why (incident) | severity | owner |
|---|---|---|---|---|
| `manager-env:CLAUDE_CODE_OAUTH_TOKEN` | present, non-empty in `systemctl --user show-environment` | 2026-09-18 07:51–10:24: reviewer auth outage, 4 wasted gates — token lived only in `environment.d`, never reached the manager env | critical | self-heal |
| `manager-env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` | `=0` in manager env | `tick-run.sh:665` exports this for the tick's own shell; branch units get the user manager env, not the tick's, so they never saw it — two dispatches killed at 600s (R9 lost twice) | critical | self-heal |
| `manager-env:TMPDIR` | `=/mnt/data/tmp`, dir exists, writable, ≥50G free | `TMPDIR` was unset until 2026-09-18 11:40am; `/tmp` hit 100% (51/68 selftest failures, R9 landing aborted) | critical | self-heal |
| `tmp-usage:/tmp` | `< 70%` used | same `/tmp`-full incident above | critical | operator |
| `timer:tmp-scratch-reap.timer` | `active` (systemd --user) | the reaper that would have kept `/tmp` below 70% did not exist before this PRD | critical | self-heal |
| `auth-file:~/.config/environment.d/90-claude-oauth.conf` | token resolves via the reviewer-agent-auth-contract resolver, `claude -p` probe ≤60s, cached 6h | same auth outage as the manager-env token row — this is the file-level source, checked independently of whether the manager env already carries it | critical | operator |
| `path:autobuilder` | exactly one `autobuilder` binary on `$PATH` | a `~/.cargo/bin` 0.9.0 shadow binary has printed a PATH-shadow warning on every gate since 2026-09-17 | warn | operator |
| `path:cargo-shims` | `cargo-budget-bin` ahead of `rustbuild/bin` on `$PATH` | two cargo shims raced in the wrong order; PATH order of two cargo shims was one of the six 2026-09-18 chains | critical | operator |
| `unit-env-inheritance` | a probe unit started via `systemd-run --user` sees `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, `TMPDIR` | the general form of the manager-env rows above — a unit's env silently diverging from the tick's own shell is the actual root cause class | critical | self-heal |
| `lock-protocol` | every `state/prd-*.lock` holder pid is a live `flock` process whose child is a live `claude -p` | 2026-09-18 11:58Z: the dispatch lock protocol itself drifted and every dispatched branch skipped itself (see `docs/branch-contract.md` §1) | critical | operator |
| `disk:/` | `< 90%` used | guardrail — a full root volume takes the whole host down, not just `/tmp` | critical | operator |
| `disk:/mnt/data` | `≥ 200G` free | guardrail — `TMPDIR` and the cargo/rust build cache both live under `/mnt/data` | critical | operator |
| `mount:/tmp` | bind-mounted onto `/mnt/data/tmp` (fstab) | Open question (PRD-build-host-contract): bind-mount at the next idle window vs. one-time operator act — default is this contract key, `warn` until done | warn | operator |

`self-heal` rows are fixed by `host-contract.sh apply <key>`: it writes
the `environment.d` file and runs `systemctl --user set-environment` for
manager-env keys, `systemctl --user enable --now` for the reaper timer,
and `mkdir -p` for `TMPDIR`. It never touches an `operator`-owned key —
`apply` on one prints the exact command to run and changes nothing.

See `docs/history.md#host-contract` for the full grounding and
`docs/branch-contract.md`'s host-contract paragraph for what a branch
agent does when it hits a drifted key mid-dispatch.
