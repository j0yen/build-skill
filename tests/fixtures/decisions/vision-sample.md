# fixture — curated vision sample for decisions-selftest.sh AC6
#
# Same table-under-heading shape as the real visions/buildloop-operations.md
# (see scripts/decisions-vision-extract.py's header for why the parser
# targets this shape), condensed to a handful of rows: eight Joe-owned open
# questions, one RESOLVED Joe-owned row (must be skipped), one non-Joe
# owner row (must be skipped) — enough to exercise both filters while
# staying well over AC6's "at least seven rows" floor.

## Open questions

| question | owner | due |
|---|---|---|
| Daily cost ceiling | Joe | at cost-budget ship |
| ntfy topic for the digest | Joe | at digest ship |
| Should the kit adopt the launcher's guards natively? | Joe | after a second host runs a loop |
| Whether the gate harness should run remotely — RESOLVED 2026-09-10: yes | Joe | done |
| Exclude target/debug/incremental from teardown pulls | build loop | after one week of telemetry |

### Open questions added

| question | owner | due |
|---|---|---|
| `rollback-plan` over eight no-ff merges: fix forward or a rewrite? | Joe | at the backfill's first block |
| Should redeploy record or refuse a binary with no release receipt? | Joe | before the next hand redeploy |
| Whole-card refresh per PRD, or additive per-PRD sections? | Joe | before the next PRD |
| Auto-expire baseline entries the gate no longer blocks on | Joe | after the paydown ships |
| Which small PRD is the first real casper dispatch? | Joe | after volume-id + pull-back |

## Not an open-questions section

| question | owner | due |
|---|---|---|
| This row must never be picked up | Joe | never |
