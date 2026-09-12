#!/usr/bin/env bash
# lane-claim.sh — push-wins claim protocol for multi-lane /build (PRD-build-second-lane-carbon).
#
# Two /build lanes (RedBaron + carbon) share one PRD clone. Before a lane
# acts on a PRD it must hold an unexpired claim, recorded IN the PRD's own
# frontmatter (`Status: building` + `Lane: <hostname> <ISO-ts>`) and won by
# git push, not by assumption — see PRD-build-second-lane-carbon P0 "Claim
# protocol, push-wins". This script is the one place that reads/writes that
# claim so both lanes agree on the format and the race resolution.
#
# Subcommands:
#   lane-claim.sh claim <prd-path> [lane-name]
#       Write Status: building + Lane: <lane-name> <iso-ts>, commit (one PRD
#       per commit), push. lane-name defaults to `hostname`.
#       Exit 0  claimed (fresh claim or reclaim of a stale one — reclaim
#               details are printed to stdout as `reclaim-receipt: ...`).
#       Exit 2  held by another lane and not stale (or lost the push race —
#               `lost-race: <other-lane> <other-ts>` printed to stdout).
#       Exit 3  origin unreachable (fetch/pull failed) — lane must idle,
#               never build on an unclaimed PRD.
#       Exit 4  local git state error (dirty tree outside this file, etc).
#   lane-claim.sh release <prd-path>
#       Remove the Lane: line (claim relinquished; Status untouched).
#       Same exit codes as claim, minus 2.
#   lane-claim.sh status <prd-path> [--json]
#       Print the current claim: free, or `<lane> <iso-ts> age=<s>s
#       stale=<yes|no>` (stale threshold 3h). `stale=yes` now means the
#       PRD-build-lane-claim-integrity evidence bar was actually cleared
#       (age past threshold AND no commit/iter_log/pid/journal liveness
#       signal — see claim_state() below), not age alone — an
#       age-exceeded claim with a live signal reads `stale=no` here even
#       though it's also not simply "live" (see --json's `state` field
#       for the long-running/unknown distinction text output doesn't
#       carry). `--json` is built entirely by jq (never string
#       interpolation, so quote/newline/UTF-8 values round-trip) and adds
#       `schema_version`, `prd`, `host`, `state` fields on top of the
#       original `claimed`/`lane`/`ts`/`age_seconds`/`stale` ones
#       (additive — see lane-claim.schema.json). Exit 0 always (read-only).
#   lane-claim.sh --json [--prd-dir <dir>]
#   lane-claim.sh claims [--prd-dir <dir>]
#       Scan build-queue/*.md for every live Lane: claim and print one
#       JSON document: `{schema_version, claims:[{prd, lane, host, ts,
#       age_s, state}, ...]}` — the machine-consumer shape a tick script
#       can pipe straight into `jq .` (see lane-claim.schema.json beside
#       this file). Read-only.
#   lane-claim.sh lint-reclaims <journal-file>
#       Flags any journal line containing "reclaimed" that doesn't also
#       carry "probes:" (Requirement P1 — a reclaim without recorded
#       evidence is a lint failure). Exit 0 clean, N = count of bad lines.
#   lane-claim.sh target-busy <build_into-path> [--lane <name>] [--exclude-prd <path>] [--prd-dir <dir>]
#       Scan build-queue/*.md for a live (non-stale) claim whose build_into
#       matches. A claim held by a DIFFERENT lane than --lane (default
#       `hostname`) blocks immediately: exit 1 + "busy: <slug> <lane>
#       age=<s>s" (cross-lane exclusivity, unconditional). A claim held by
#       the SAME lane does not block on its own — same-lane claims fall
#       through to the ≤3 same-target sub-cap (SKILL.md Selection rules #1):
#       once SAME_LANE_SUBCAP live same-lane claims are found, exit 1 +
#       "sub-cap: <N> same-lane claims already live on <target> (lane=<l>)".
#       Exit 0 + "free" if neither condition trips.
#       **Burst-lane override (PRD-build-burst-lane-ccx53 requirement 7).**
#       <N> above is not always SAME_LANE_SUBCAP: when <build_into-path>
#       looks like a rust crate (Cargo.toml at its root or exactly one
#       level down) AND `burst-lane.sh sub-cap` reports a live session
#       (`sub-cap=<n> local=0 ...`), <N> is that box-computed number
#       instead — "every rust branch runs on the box" only holds if
#       selection actually admits that many concurrent same-target claims.
#       No session, a probe failure, or a non-rust target all fall through
#       to the unchanged local SAME_LANE_SUBCAP. See effective_subcap()
#       below.
#       **Own-claim continuation (PRD-build-claims-resume-not-count).** If
#       `--exclude-prd` itself already carries a live claim held by --lane,
#       that PRD is a continuation of this lane's own prior work (Phase 2
#       bucket 1), not a new selection: it is exempt from the sub-cap check
#       entirely (exit 0 + "resume: own claim on <target> (lane=<l>)") even
#       when SAME_LANE_SUBCAP other same-lane claims are already live. It is
#       still subject to the unconditional cross-lane busy check like any
#       other PRD on the target (Non-goal: cross-lane exclusivity unchanged).
#       Read-only.
#
# Frontmatter forms read/written follow build-contract.md: bullet
# (`- key: value`), bare (`key: value`), bold (`**key:** value`), first 80
# lines, first match wins. This script always WRITES the bullet form
# (`- Status: ...` / `- Lane: ...`) since every PRD observed in this
# workspace uses it; existing bare/bold Status lines are still read and
# updated in place (form preserved) so a foreign-authored PRD isn't
# reformatted.
#
# Coordinator liveness (PRD-build-claims-resume-not-count). A claim's Lane
# line may carry a trailer after the ISO timestamp: `pid=<n> boot=<id>`,
# recorded at claim time from `${BUILD_TICK_PID:-$PPID}` (the tick
# coordinator, not this script's own subshell — branch subshells would
# otherwise mis-identify $PPID) and `/proc/sys/kernel/random/boot_id`. The
# trailer is display-only to the rest of the parser (build-contract.md), so
# it never breaks a foreign reader that only looks at the first two tokens.
# A claim's coordinator is confirmed gone — and the claim stale immediately,
# regardless of age — only when the claim's own lane matches THIS host (PID
# namespaces are host-local; a claim written by another lane cannot be
# liveness-checked from here, so it keeps the plain 3h age rule) and either
# the recorded boot id differs from the current one (PID reused since a
# reboot) or the recorded PID no longer exists. Claims written before this
# PRD carry no trailer and keep the age-only rule (Migration/compatibility).
set -uo pipefail

STALE_SECS=$((3 * 3600))
# Max same-lane live claims on one build_into repo before target-busy blocks
# a further same-lane candidate (SKILL.md Selection rules #1 worktree cap).
SAME_LANE_SUBCAP="${SAME_LANE_SUBCAP:-5}"

# Where a host-local lane's own journal lives, for the journal-activity
# liveness probe (PRD-build-lane-claim-integrity). Overridable so the
# selftest never touches the real journal.
JOURNAL_DIR="${JOURNAL_DIR:-$HOME/brain/journal/build}"

# --json output schema version (PRD-build-lane-claim-integrity P2). Bump
# this and the checked-in schema (lane-claim.schema.json) together.
JSON_SCHEMA_VERSION=1

# PRD-build-burst-lane-ccx53 requirement 7: path to burst-lane.sh, whose
# `sub-cap` subcommand computes the box-wide same-target cap for rust
# targets while a session is up. Overridable so selftests can point this
# at a fake script without a real Hetzner session.
BURST_LANE_SH="${BURST_LANE_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/burst-lane.sh}"
# PRD-build-burst-selftest-isolation: this script never resolves a
# state/journal/box path of its own for the burst-lane call above — it
# only shells out to burst-lane.sh (which owns and guards those paths
# under BURST_LANE_TEST=1, see isolation-guard.sh) and effective_subcap()
# below already fails open on ANY non-zero exit from that call, including
# the guard's own exit 9. A test that sets BURST_LANE_TEST=1 for a
# lane-claim.sh scenario is therefore already isolation-safe by
# delegation: no separate override plumbing needed here.

die() { echo "lane-claim: $*" >&2; exit "${2:-4}"; }

usage() {
  echo "usage: lane-claim.sh {claim|release|status|target-busy|claims|lint-reclaims|--json} ..." >&2
  exit 4
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Extract the "Lane:" value (everything after the colon, trimmed) from the
# first 80 lines of a file, in any of the three forms. Empty output = none.
read_lane_line() {
  local f="$1"
  head -n 80 "$f" | grep -E '^(- *Lane:|Lane:|\*\*Lane:\*\*)' | head -n1 \
    | sed -E 's/^(- *Lane:|Lane:|\*\*Lane:\*\*)[[:space:]]*//'
}

read_build_into() {
  local f="$1"
  head -n 80 "$f" | grep -E '^(- *build_into:|build_into:|\*\*build_into:\*\*)' | head -n1 \
    | sed -E 's/^(- *build_into:|build_into:|\*\*build_into:\*\*)[[:space:]]*//' \
    | sed -E 's/[[:space:]]*#.*$//'
}

# Most recent `iter_log:` value (any of the three frontmatter forms,
# same convention as mark-needs-classification.sh's read_last_iter_log) —
# `<ISO-ts> <free text>`. Empty output = no iter_log line at all.
read_last_iter_log_line() {
  head -n 80 "$1" | grep -E '^(- *iter_log:|iter_log:|\*\*iter_log:\*\*)' | tail -n1 \
    | sed -E 's/^(- *iter_log:|iter_log:|\*\*iter_log:\*\*)[[:space:]]*//'
}

# lane_value -> "lane host" "iso-ts" [pid=<n>] [boot=<id>] — host and ts are
# the first two whitespace-separated tokens; pid/boot are optional trailer
# tokens (absent on claims written before PRD-build-claims-resume-not-count).
lane_host_of() { awk '{print $1}' <<<"$1"; }
lane_ts_of()   { awk '{print $2}' <<<"$1"; }
lane_pid_of()  { awk '{for(i=3;i<=NF;i++) if ($i ~ /^pid=/)  {print substr($i,5); exit}}' <<<"$1"; }
lane_boot_of() { awk '{for(i=3;i<=NF;i++) if ($i ~ /^boot=/) {print substr($i,6); exit}}' <<<"$1"; }

age_seconds() {
  local ts="$1" now_e ts_e
  now_e=$(date -u +%s)
  ts_e=$(date -u -d "$ts" +%s 2>/dev/null) || { echo -1; return; }
  echo $(( now_e - ts_e ))
}

current_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

# Reachability probe for a remote (non-host-local) claim's host (AC5).
# Overridable via LANE_CLAIM_REACHABLE_OVERRIDE ("host=yes|no host2=yes|no
# ..."), so the selftest can pin fleet-hostname reachability deterministically
# instead of depending on real network/DNS state from wherever tests run.
# Echoes yes/no.
host_reachable() {
  local host="$1" pair h v
  if [ -n "${LANE_CLAIM_REACHABLE_OVERRIDE:-}" ]; then
    for pair in $LANE_CLAIM_REACHABLE_OVERRIDE; do
      h="${pair%%=*}"; v="${pair#*=}"
      if [ "$h" = "$host" ]; then echo "$v"; return; fi
    done
  fi
  if command -v ping >/dev/null 2>&1 && ping -c1 -W2 "$host" >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

pid_alive() { local pid="$1"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

# Confirmed-gone check for the coordinator that wrote a claim (Requirement
# P0 #3). Returns 0 (confirmed gone) only when the claim's own lane is THIS
# host (PID namespaces are host-local — a claim from another lane can't be
# liveness-checked here) and a PID was recorded, and either the boot id
# differs (PID reused across a reboot) or the PID no longer exists. Returns
# 1 (cannot confirm — caller falls back to the age rule) for cross-host
# claims and for claims with no PID trailer at all.
coordinator_gone() {
  local host="$1" pid="$2" boot="$3"
  [ -n "$host" ] || return 1
  same_lane "$host" "$(hostname)" || return 1
  [ -n "$pid" ] || return 1
  if [ -n "$boot" ]; then
    local now_boot; now_boot=$(current_boot_id)
    [ -n "$now_boot" ] && [ "$boot" != "$now_boot" ] && return 0
  fi
  pid_alive "$pid" && return 1
  return 0
}

# Journal-activity probe (PRD-build-lane-claim-integrity, host-local only —
# a remote lane's journal lives on that host, not here). Scans
# $JOURNAL_DIR/*.md for any line mentioning $slug whose leading ISO-ts
# token parses to an epoch after $since_epoch. Echoes yes/no.
journal_activity_since() {
  local slug="$1" since_epoch="$2" f line ts_tok epoch found=no
  [ -d "$JOURNAL_DIR" ] || { echo no; return; }
  for f in "$JOURNAL_DIR"/*.md; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      [[ "$line" == *"$slug"* ]] || continue
      ts_tok=$(awk '{print $1}' <<<"$line")
      epoch=$(date -u -d "$ts_tok" +%s 2>/dev/null) || continue
      if [ "$epoch" -gt "$since_epoch" ]; then found=yes; fi
    done < "$f"
  done
  echo "$found"
}

# Evidence-bar staleness (PRD-build-lane-claim-integrity, replaces the old
# age-only is_stale). Sets CS_STATE to one of:
#   live          age < STALE_SECS
#   long-running  age >= STALE_SECS but a liveness probe fired (commit,
#                 iter_log, host-local pid, or host-local journal) — never
#                 reclaimed (Requirement P0 #3)
#   stale         age >= STALE_SECS AND every probe this call could run
#                 came back negative (or the coordinator is confirmed gone,
#                 which is stale at any age — unchanged prior rule) —
#                 reclaimable
#   unknown       remote (non-host-local) claim whose host doesn't answer
#                 a ping — cannot be probed further, so never reclaimed
#                 (AC5 / open-question default)
# CS_PROBES is a human-readable "k=v k=v ..." record of every probe this
# call actually ran, for the reclaim-journal evidence contract
# (Requirement P1). CS_AGE is the claim age in seconds.
CS_STATE=""; CS_PROBES=""; CS_AGE=""
claim_state() {
  local prd="$1" host="$2" ts="$3" pid="${4:-}" boot="${5:-}"
  local age; age=$(age_seconds "$ts")
  CS_AGE="$age"
  if [ "$age" -lt 0 ]; then
    CS_STATE="stale"; CS_PROBES="ts=unparsable"; return
  fi
  if coordinator_gone "$host" "$pid" "$boot"; then
    CS_STATE="stale"; CS_PROBES="coordinator=gone"; return
  fi
  if [ "$age" -lt "$STALE_SECS" ]; then
    CS_STATE="live"; CS_PROBES="age=${age}s(<threshold)"; return
  fi

  local since_epoch; since_epoch=$(date -u -d "$ts" +%s 2>/dev/null) || since_epoch=0

  local commit="no" commit_ts=""
  local latest; latest=$(git -C "$(dirname "$prd")" log -1 --format=%ct -- "$(basename "$prd")" 2>/dev/null)
  if [ -n "$latest" ] && [ "$latest" -gt $((since_epoch + 2)) ]; then
    commit="yes"; commit_ts=$(date -u -d "@$latest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  fi

  local iterlog="no" iterlog_ts=""
  local last_il; last_il=$(read_last_iter_log_line "$prd")
  if [ -n "$last_il" ]; then
    local il_ts; il_ts=$(awk '{print $1}' <<<"$last_il")
    local il_epoch; il_epoch=$(date -u -d "$il_ts" +%s 2>/dev/null)
    if [ -n "$il_epoch" ] && [ "$il_epoch" -gt "$since_epoch" ]; then
      iterlog="yes"; iterlog_ts="$il_ts"
    fi
  fi

  if same_lane "$host" "$(hostname)"; then
    local pidlive="no"
    [ -n "$pid" ] && pid_alive "$pid" && pidlive="yes"
    local journal; journal=$(journal_activity_since "$(slug_of "$prd")" "$since_epoch")
    if [ "$commit" = no ] && [ "$iterlog" = no ] && [ "$pidlive" != yes ] && [ "$journal" != yes ]; then
      CS_STATE="stale"
    else
      CS_STATE="long-running"
    fi
    CS_PROBES="commit=$commit${commit_ts:+@$commit_ts} iter_log=$iterlog${iterlog_ts:+@$iterlog_ts} pid=$pidlive journal=$journal"
    return
  fi

  # Remote claim: no pid/journal probe reachable from here. Check
  # reachability first — an unreachable host is unknown, never stale
  # (AC5), regardless of what commit/iter_log show.
  local reachable; reachable=$(host_reachable "$host")
  if [ "$reachable" != yes ]; then
    CS_STATE="unknown"
    CS_PROBES="reachable=$reachable commit=$commit${commit_ts:+@$commit_ts} iter_log=$iterlog${iterlog_ts:+@$iterlog_ts}"
    return
  fi
  if [ "$commit" = no ] && [ "$iterlog" = no ]; then
    CS_STATE="stale"
  else
    CS_STATE="long-running"
  fi
  CS_PROBES="reachable=$reachable commit=$commit${commit_ts:+@$commit_ts} iter_log=$iterlog${iterlog_ts:+@$iterlog_ts}"
}

# $1=prd $2=host $3=ts $4=pid $5=boot (pid/boot optional). Thin boolean
# wrapper over claim_state for call sites that only need yes/no.
is_stale() {
  claim_state "$1" "$2" "$3" "${4:-}" "${5:-}"
  [ "$CS_STATE" = "stale" ]
}

slug_of() { basename "$1" .md | sed -E 's/^PRD-//'; }

# Lane names are compared case-insensitively (RedBaron == redbaron == REDBARON)
# so a claim written under one casing of `hostname` is still recognized as the
# same lane later — `hostname` itself is lowercase on this box while historical
# claims were written capitalized, and a case-sensitive compare here treated
# every self-reclaim as "held by another lane", deadlocking the whole queue.
same_lane() { [ "${1,,}" = "${2,,}" ]; }

git_repo_root() { git -C "$(dirname "$1")" rev-parse --show-toplevel 2>/dev/null; }

git_pull_or_die() {
  local root="$1"
  # --autostash (PRD-build-archive-atomic-commit): a sibling branch's own
  # in-progress write (e.g. archive-commit.sh mid-commit, or any other
  # branch's uncommitted edit to an unrelated PRD) must not fail this
  # lane's claim pull just because the checkout happens to be dirty at
  # this instant. git stashes the local dirt, rebases, then pops the
  # stash back — so a transiently-dirty checkout now tolerates a pull
  # that used to hard-fail here.
  local pre_head; pre_head="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  if git -C "$root" pull --rebase --autostash -q 2>/tmp/lane-claim.pull.err; then
    # Gotcha (found by fixture, not by reading the docs): `git pull
    # --rebase --autostash` reports SUCCESS even when its own final
    # `stash pop` conflicts — that failure leaves unmerged paths and a
    # retained autostash entry behind but neither a REBASE_HEAD nor a
    # non-zero exit code, so a plain exit-code check here would silently
    # let the caller (cmd_claim) commit on top of unresolved conflict
    # markers. Check for unmerged paths explicitly before trusting a
    # zero exit.
    if [ -z "$(git -C "$root" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      return 0
    fi
  fi
  # A real conflict between the sibling's uncommitted edit and the
  # incoming commit either leaves a rebase in progress, or — the
  # autostash-pop-only case above — leaves the rebase itself complete but
  # the pop conflicted. Both are a busy condition, not an unreachable
  # origin: unwind ALL the way back to the pre-pull HEAD and reapply the
  # sibling's stashed edit exactly as it was, rather than leaving this
  # attempt's incoming commit and a half-resolved conflict in place, then
  # return the existing busy exit code with reason `checkout-conflict`.
  if [ -d "$root/.git/rebase-apply" ] || [ -d "$root/.git/rebase-merge" ]; then
    # rebase --abort restores pre-rebase HEAD and (git >=2.9) re-pops the
    # autostash on its own.
    git -C "$root" rebase --abort 2>/dev/null
  else
    git -C "$root" reset --hard -q "$pre_head" 2>/dev/null
    git -C "$root" stash pop -q 2>/dev/null
  fi
  cat /tmp/lane-claim.pull.err >&2
  die "checkout-conflict: rebase conflict pulling $root; aborted and restored" 2
}

# Write/replace Status + Lane lines in $1 (prd path) to Status: $2, Lane: $3.
# Preserves existing line form for Status if one exists; Lane is always
# written in bullet form directly after the Status line (or, if no Status
# line exists in the first 80, after line 1).
write_claim() {
  local f="$1" status_val="$2" lane_val="$3"
  python3 - "$f" "$status_val" "$lane_val" <<'PYEOF'
import re, sys
f, status_val, lane_val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]

status_re = re.compile(r'^(?P<pre>-\s*Status:|Status:|\*\*Status:\*\*)\s*(?P<val>.*)$')
lane_re = re.compile(r'^(?:-\s*Lane:|Lane:|\*\*Lane:\*\*)\s*.*$')

status_idx = None
lane_idx = None
for i, ln in enumerate(head):
    if status_idx is None and status_re.match(ln.rstrip('\n')):
        status_idx = i
    if lane_idx is None and lane_re.match(ln.rstrip('\n')):
        lane_idx = i

if status_idx is not None:
    m = status_re.match(head[status_idx].rstrip('\n'))
    pre = m.group('pre')
    head[status_idx] = f"{pre} {status_val}\n"
else:
    # No Status line found in first 80 — insert one after the title (line 1).
    head.insert(1, f"- Status: {status_val}\n")
    if lane_idx is not None and lane_idx >= 1:
        lane_idx += 1
    status_idx = 1

lane_line = f"- Lane: {lane_val}\n"
if lane_idx is not None:
    head[lane_idx] = lane_line
else:
    head.insert(status_idx + 1, lane_line)

with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
}

remove_lane_line() {
  local f="$1"
  python3 - "$f" <<'PYEOF'
import re, sys
f = sys.argv[1]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]
lane_re = re.compile(r'^(?:-\s*Lane:|Lane:|\*\*Lane:\*\*)\s*.*$')
head = [ln for ln in head if not lane_re.match(ln.rstrip('\n'))]
with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
}

push_or_resolve_race() {
  # $1 = repo root, $2 = prd path, $3 = our lane, $4 = "claim"|"release"
  local root="$1" prd="$2" our_lane="$3" mode="$4"
  local branch
  branch=$(git -C "$root" symbolic-ref --short HEAD)
  if git -C "$root" push origin "$branch" -q 2>/tmp/lane-claim.push.err; then
    return 0
  fi
  # Rejected — fetch + rebase, then decide.
  if ! git -C "$root" fetch origin -q; then
    die "origin unreachable during push for $root" 3
  fi
  if ! git -C "$root" rebase "origin/$branch" -q 2>/tmp/lane-claim.rebase.err; then
    git -C "$root" rebase --abort >/dev/null 2>&1 || true
    # We lost the race: discard our unpushed, conflicting local commit and
    # land cleanly on the winner's state. Never leave the checkout carrying
    # a dead local commit that would jam every subsequent pull/claim in
    # this clone (Hard Safety Rule: the main checkout is never left dirty
    # or diverged between ticks).
    git -C "$root" reset --hard "origin/$branch" -q
    if [ "$mode" = "claim" ]; then
      local other other_host other_ts
      other=$(read_lane_line "$prd")
      other_host=$(lane_host_of "$other")
      other_ts=$(lane_ts_of "$other")
      echo "lost-race: ${other_host:-unknown} ${other_ts:-unknown}"
    fi
    exit 2
  fi
  # Rebase applied cleanly (no conflicting hunk) — retry push once.
  if git -C "$root" push origin "$branch" -q 2>/tmp/lane-claim.push2.err; then
    return 0
  fi
  cat /tmp/lane-claim.push2.err >&2
  die "push failed after rebase for $root" 3
}

cmd_status() {
  local prd="$1" json=0
  [ "${2:-}" = "--json" ] && json=1
  [ -f "$prd" ] || die "no such file: $prd" 4
  local lane_val host ts pid boot age stale
  lane_val=$(read_lane_line "$prd")
  if [ -z "$lane_val" ]; then
    if [ "$json" = 1 ]; then
      jq -nc --argjson v "$JSON_SCHEMA_VERSION" '{schema_version:$v, claimed:false}'
    else
      echo "free"
    fi
    exit 0
  fi
  host=$(lane_host_of "$lane_val"); ts=$(lane_ts_of "$lane_val")
  pid=$(lane_pid_of "$lane_val"); boot=$(lane_boot_of "$lane_val")
  claim_state "$prd" "$host" "$ts" "$pid" "$boot"
  age="$CS_AGE"
  [ "$CS_STATE" = "stale" ] && stale=yes || stale=no
  if [ "$json" = 1 ]; then
    # Built entirely by jq (never string interpolation) so a host/ts/prd
    # value containing quotes, newlines, or UTF-8 still round-trips —
    # AC1/AC2. `stale` stays the pre-existing bare-word-bug field name but
    # is now a real JSON boolean; `schema_version`/`prd`/`host`/`state`
    # are additive (Migration/compatibility: schema is additive-only).
    jq -nc --argjson v "$JSON_SCHEMA_VERSION" --arg prd "$prd" --arg lane "$host" \
      --arg host "$host" --arg ts "$ts" --argjson age_s "$age" \
      --arg state "$CS_STATE" --arg probes "$CS_PROBES" \
      --argjson stale_bool "$([ "$stale" = yes ] && echo true || echo false)" \
      '{schema_version:$v, claimed:true, prd:$prd, lane:$lane, host:$host, ts:$ts,
        age_seconds:$age_s, age_s:$age_s, state:$state, probes:$probes, stale:$stale_bool}'
  else
    echo "$host $ts age=${age}s stale=$stale"
  fi
}

cmd_claim() {
  local prd="$1" lane="${2:-$(hostname)}"
  [ -f "$prd" ] || die "no such file: $prd" 4
  local root; root=$(git_repo_root "$prd") || die "not a git repo: $prd" 4
  git_pull_or_die "$root"

  local existing host ts pid boot age was_stale=0
  existing=$(read_lane_line "$prd")
  if [ -n "$existing" ]; then
    host=$(lane_host_of "$existing"); ts=$(lane_ts_of "$existing")
    pid=$(lane_pid_of "$existing"); boot=$(lane_boot_of "$existing")
    claim_state "$prd" "$host" "$ts" "$pid" "$boot"
    age="$CS_AGE"
    if ! same_lane "$host" "$lane" && [ "$CS_STATE" != "stale" ]; then
      # long-running/unknown claims are held exactly like a live claim
      # (Requirement P0 #3, AC5) — the state is appended for operator
      # visibility; the `held: $host $ts age=...` prefix that the
      # existing selftest greps for is unchanged.
      echo "held: $host $ts age=${age}s state=$CS_STATE"
      exit 2
    fi
    if ! same_lane "$host" "$lane" && [ "$CS_STATE" = "stale" ]; then
      # Stale-claim recovery receipt: age plus every probe claim_state
      # actually ran, so the journal line names both/all probes and
      # their timestamps (Requirement P1's evidence contract). A
      # gone-coordinator claim is stale at any age (Requirement P0 #3);
      # the receipt still reports the true age for the journal.
      echo "reclaim-receipt: prev_lane=$host prev_ts=$ts age=${age}s probes: $CS_PROBES"
      was_stale=1
    fi
  fi

  local ts_new; ts_new=$(now_iso)
  local my_pid="${BUILD_TICK_PID:-$PPID}" my_boot; my_boot=$(current_boot_id)
  local lane_val_new="$lane $ts_new"
  [ -n "$my_pid" ]  && lane_val_new="$lane_val_new pid=$my_pid"
  [ -n "$my_boot" ] && lane_val_new="$lane_val_new boot=$my_boot"
  write_claim "$prd" "building" "$lane_val_new"
  git -C "$root" add -- "$prd"
  local slug; slug=$(slug_of "$prd")
  local subject="claim: $slug lane=$lane"
  if [ "$was_stale" -eq 1 ]; then
    subject="reclaim: $slug lane=$lane (prev stale)"
  fi
  git -C "$root" -c user.name="Joe Yen" -c user.email=jyen.tech@gmail.com \
    commit -q -m "$subject" -- "$prd"
  push_or_resolve_race "$root" "$prd" "$lane" "claim"
  echo "claimed: $slug lane=$lane ts=$ts_new"
}

cmd_release() {
  local prd="$1"
  [ -f "$prd" ] || die "no such file: $prd" 4
  local root; root=$(git_repo_root "$prd") || die "not a git repo: $prd" 4
  git_pull_or_die "$root"
  local existing; existing=$(read_lane_line "$prd")
  if [ -z "$existing" ]; then
    echo "already-free"
    exit 0
  fi
  remove_lane_line "$prd"
  git -C "$root" add -- "$prd"
  local slug; slug=$(slug_of "$prd")
  git -C "$root" -c user.name="Joe Yen" -c user.email=jyen.tech@gmail.com \
    commit -q -m "release: $slug" -- "$prd"
  push_or_resolve_race "$root" "$prd" "" "release"
  echo "released: $slug"
}

# Cheap, existence-only rust-target detection for effective_subcap() below:
# a Cargo.toml at $1 itself or in exactly one immediate subdirectory
# (mirrors extend-gate.sh's cargo-root resolution, minus its multi-
# candidate disambiguation — a wrong guess here only ever affects which
# cap number applies, never claim correctness).
is_rust_target() {
  local base="$1" d
  [ -f "$base/Cargo.toml" ] && return 0
  for d in "$base"/*/; do
    [ -f "${d}Cargo.toml" ] && return 0
  done
  return 1
}

# Effective same-target fan-out cap for build_into path $1
# (PRD-build-burst-lane-ccx53 requirement 7). Local SAME_LANE_SUBCAP unless
# $1 looks like a rust crate AND `burst-lane.sh sub-cap` reports a live
# session (`sub-cap=<n> local=0 ...`) — then the box-computed <n> wins.
# Any hiccup (no session: `sub-cap=0 local=3 ...`; probe failure:
# `fallback: ...`; script missing; non-rust target) falls straight through
# to the unchanged local number, so behavior off a burst session is
# byte-identical to before this wiring existed.
effective_subcap() {
  local target="$1" cap="$SAME_LANE_SUBCAP"
  if [ -x "$BURST_LANE_SH" ] && is_rust_target "$target"; then
    local out n
    if out=$("$BURST_LANE_SH" sub-cap 2>/dev/null); then
      n="${out#sub-cap=}"; n="${n%% *}"
      case "$n" in [1-9]|[1-9][0-9]) cap="$n" ;; esac
    fi
  fi
  echo "$cap"
}

cmd_target_busy() {
  local target="$1"; shift
  local exclude="" prd_dir="$HOME/Documents/PRDs" query_lane
  query_lane=$(hostname)
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclude-prd) exclude="$2"; shift 2 ;;
      --prd-dir) prd_dir="$2"; shift 2 ;;
      --lane) query_lane="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  # Own-claim continuation (PRD-build-claims-resume-not-count Requirement
  # P0 #1): if the candidate being evaluated (--exclude-prd) already
  # carries a live Lane: line naming the querying lane, it is work this
  # lane already owns — Phase 2 bucket 1, resumed, never a new selection.
  # It is exempt from the sub-cap below no matter how many OTHER same-lane
  # claims are already live; it still can't bypass the unconditional
  # cross-lane busy check applied to every PRD in the loop below.
  local own_continuation=0
  if [ -n "$exclude" ] && [ -f "$exclude" ]; then
    local self_lane_val self_host
    self_lane_val=$(read_lane_line "$exclude")
    if [ -n "$self_lane_val" ]; then
      self_host=$(lane_host_of "$self_lane_val")
      same_lane "$self_host" "$query_lane" && own_continuation=1
    fi
  fi

  # Requirement 7: computed once per call (not per candidate in the loop
  # below) so a live session costs this call one ssh round trip, not one
  # per queued PRD sharing the target.
  local cap; cap="$(effective_subcap "$target")"

  local f bi lane_val host ts pid boot age same_count=0
  for f in "$prd_dir"/build-queue/PRD-*.md; do
    [ -f "$f" ] || continue
    [ -n "$exclude" ] && [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "$(cd "$(dirname "$exclude")" && pwd)/$(basename "$exclude")" ] && continue
    bi=$(read_build_into "$f")
    [ "$bi" = "$target" ] || continue
    lane_val=$(read_lane_line "$f")
    [ -z "$lane_val" ] && continue
    host=$(lane_host_of "$lane_val"); ts=$(lane_ts_of "$lane_val")
    pid=$(lane_pid_of "$lane_val"); boot=$(lane_boot_of "$lane_val")
    age=$(age_seconds "$ts")
    # A long-running or unknown claim is demonstrably (or possibly) still
    # alive — PRD-build-lane-claim-integrity — so it must NOT be skipped
    # here as if reclaimed; only a genuinely stale claim frees the slot.
    is_stale "$f" "$host" "$ts" "$pid" "$boot" && continue
    if ! same_lane "$host" "$query_lane"; then
      # Foreign-lane claim: unconditional block, exactly as before
      # (cross-lane exclusivity is never relaxed).
      echo "busy: $(slug_of "$f") $host age=${age}s"
      exit 1
    fi
    # Same-lane claim: don't block outright — count it toward the
    # ≤SAME_LANE_SUBCAP same-target worktree fan-out cap instead. A
    # continuation candidate (own_continuation=1) is never refused by this
    # count (Requirement P0 #2); a genuinely new candidate still is.
    same_count=$((same_count + 1))
    if [ "$own_continuation" -eq 0 ] && [ "$same_count" -ge "$cap" ]; then
      echo "sub-cap: $cap same-lane claims already live on $target (lane=$query_lane)"
      exit 1
    fi
  done
  if [ "$own_continuation" -eq 1 ]; then
    echo "resume: own claim on $target (lane=$query_lane)"
    exit 0
  fi
  echo "free"
  exit 0
}

# Bulk claims listing (PRD-build-lane-claim-integrity), the `lane-claim.sh
# --json | jq .` shape the lane predicate / any future machine consumer
# wants: one JSON document, `{schema_version, claims:[...]}`, built
# entirely by jq (one object per claim, then `jq -s` to wrap them) so a
# prd path or diagnosis containing quotes/newlines/UTF-8 still round-trips
# — never string interpolation. Each claim: prd, lane, host, ts, age_s,
# state (state per claim_state() above: live/long-running/stale/unknown).
# PRDs with no Lane: line are simply absent from the array (this lists
# claims, not every PRD).
cmd_json_all() {
  local prd_dir="$HOME/Documents/PRDs"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prd-dir) prd_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local f lane_val host ts pid boot
  local tmp; tmp=$(mktemp)
  : > "$tmp"
  for f in "$prd_dir"/build-queue/PRD-*.md; do
    [ -f "$f" ] || continue
    lane_val=$(read_lane_line "$f")
    [ -z "$lane_val" ] && continue
    host=$(lane_host_of "$lane_val"); ts=$(lane_ts_of "$lane_val")
    pid=$(lane_pid_of "$lane_val"); boot=$(lane_boot_of "$lane_val")
    claim_state "$f" "$host" "$ts" "$pid" "$boot"
    jq -nc --arg prd "$f" --arg lane "$host" --arg host "$host" --arg ts "$ts" \
      --argjson age_s "$CS_AGE" --arg state "$CS_STATE" --arg probes "$CS_PROBES" \
      '{prd:$prd, lane:$lane, host:$host, ts:$ts, age_s:$age_s, state:$state, probes:$probes}' >> "$tmp"
  done
  jq -sc --argjson v "$JSON_SCHEMA_VERSION" '{schema_version:$v, claims: .}' "$tmp"
  rm -f "$tmp"
}

# tick lint (Requirement P1 / AC6): a reclaim journal line that doesn't
# name its probes is itself a lint failure. Scans $1 (a journal file) for
# any line containing "reclaimed" and flags the ones missing "probes:".
# Exit 0 clean, N = count of bad lines otherwise (usage errors still 4).
cmd_lint_reclaims() {
  local file="$1"
  [ -f "$file" ] || die "no such file: $file" 4
  local bad=0 line
  while IFS= read -r line; do
    if [[ "$line" == *"reclaimed"* ]] && [[ "$line" != *"probes:"* ]]; then
      echo "FAIL $file: reclaim line missing probes: $line"
      bad=$((bad + 1))
    fi
  done < "$file"
  exit "$bad"
}

main() {
  # `lane-claim.sh --json [--prd-dir <dir>]` — bare top-level flag, no
  # subcommand keyword, matching the lane predicate's own invocation shape.
  if [ "${1:-}" = "--json" ]; then
    shift
    cmd_json_all "$@"
    return
  fi
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    claim)          [ $# -ge 1 ] || usage; cmd_claim "$@" ;;
    release)        [ $# -ge 1 ] || usage; cmd_release "$@" ;;
    status)         [ $# -ge 1 ] || usage; cmd_status "$@" ;;
    target-busy)    [ $# -ge 1 ] || usage; cmd_target_busy "$@" ;;
    claims)         cmd_json_all "$@" ;;
    lint-reclaims)  [ $# -ge 1 ] || usage; cmd_lint_reclaims "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
