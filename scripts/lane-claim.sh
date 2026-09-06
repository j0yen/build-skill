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
#       stale=<yes|no>` (stale threshold 3h, matching the PRD's
#       stale-claim-recovery rule). Exit 0 always (read-only).
#   lane-claim.sh target-busy <build_into-path> [--exclude-prd <path>] [--prd-dir <dir>]
#       Scan build-queue/*.md for a live (non-stale) claim whose build_into
#       matches. Exit 0 + "free" if none; exit 1 + "busy: <slug> <lane>
#       age=<s>s" if one is found. Read-only.
#
# Frontmatter forms read/written follow build-contract.md: bullet
# (`- key: value`), bare (`key: value`), bold (`**key:** value`), first 80
# lines, first match wins. This script always WRITES the bullet form
# (`- Status: ...` / `- Lane: ...`) since every PRD observed in this
# workspace uses it; existing bare/bold Status lines are still read and
# updated in place (form preserved) so a foreign-authored PRD isn't
# reformatted.
set -uo pipefail

STALE_SECS=$((3 * 3600))

die() { echo "lane-claim: $*" >&2; exit "${2:-4}"; }

usage() {
  echo "usage: lane-claim.sh {claim|release|status|target-busy} ..." >&2
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

# lane_value -> "lane host" "iso-ts" split on the last whitespace-separated
# token (the ISO timestamp never contains a space).
lane_host_of() { awk '{print $1}' <<<"$1"; }
lane_ts_of()   { awk '{print $2}' <<<"$1"; }

age_seconds() {
  local ts="$1" now_e ts_e
  now_e=$(date -u +%s)
  ts_e=$(date -u -d "$ts" +%s 2>/dev/null) || { echo -1; return; }
  echo $(( now_e - ts_e ))
}

is_stale() {
  local age="$1"
  [ "$age" -lt 0 ] && return 0   # unparseable timestamp treated as stale
  [ "$age" -ge "$STALE_SECS" ]
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
  if ! git -C "$root" pull --rebase -q 2>/tmp/lane-claim.pull.err; then
    cat /tmp/lane-claim.pull.err >&2
    die "origin unreachable for $root — idling, not claiming" 3
  fi
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
  local lane_val host ts age stale
  lane_val=$(read_lane_line "$prd")
  if [ -z "$lane_val" ]; then
    if [ "$json" = 1 ]; then echo '{"claimed":false}'; else echo "free"; fi
    exit 0
  fi
  host=$(lane_host_of "$lane_val"); ts=$(lane_ts_of "$lane_val")
  age=$(age_seconds "$ts")
  is_stale "$age" && stale=yes || stale=no
  if [ "$json" = 1 ]; then
    printf '{"claimed":true,"lane":"%s","ts":"%s","age_seconds":%s,"stale":%s}\n' \
      "$host" "$ts" "$age" "$stale"
  else
    echo "$host $ts age=${age}s stale=$stale"
  fi
}

cmd_claim() {
  local prd="$1" lane="${2:-$(hostname)}"
  [ -f "$prd" ] || die "no such file: $prd" 4
  local root; root=$(git_repo_root "$prd") || die "not a git repo: $prd" 4
  git_pull_or_die "$root"

  local existing host ts age
  existing=$(read_lane_line "$prd")
  if [ -n "$existing" ]; then
    host=$(lane_host_of "$existing"); ts=$(lane_ts_of "$existing")
    age=$(age_seconds "$ts")
    if ! same_lane "$host" "$lane" && ! is_stale "$age"; then
      echo "held: $host $ts age=${age}s"
      exit 2
    fi
    if ! same_lane "$host" "$lane" && is_stale "$age"; then
      # Stale-claim recovery receipt: age, and a best-effort probe of the
      # claiming host (only meaningful for a fleet hostname on the same
      # tailnet; failure is expected and just means "unreachable", not an
      # error).
      local probe="unreachable"
      if command -v ping >/dev/null 2>&1 && ping -c1 -W2 "$host" >/dev/null 2>&1; then
        probe="reachable"
      fi
      echo "reclaim-receipt: prev_lane=$host prev_ts=$ts age=${age}s probe=$probe"
    fi
  fi

  local ts_new; ts_new=$(now_iso)
  write_claim "$prd" "building" "$lane $ts_new"
  git -C "$root" add -- "$prd"
  local slug; slug=$(slug_of "$prd")
  local subject="claim: $slug lane=$lane"
  [ -n "$existing" ] && is_stale "$(age_seconds "$(lane_ts_of "$existing")")" 2>/dev/null \
    && subject="reclaim: $slug lane=$lane (prev stale)"
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

cmd_target_busy() {
  local target="$1"; shift
  local exclude="" prd_dir="$HOME/Documents/PRDs"
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclude-prd) exclude="$2"; shift 2 ;;
      --prd-dir) prd_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local f bi lane_val host ts age
  for f in "$prd_dir"/build-queue/PRD-*.md; do
    [ -f "$f" ] || continue
    [ -n "$exclude" ] && [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "$(cd "$(dirname "$exclude")" && pwd)/$(basename "$exclude")" ] && continue
    bi=$(read_build_into "$f")
    [ "$bi" = "$target" ] || continue
    lane_val=$(read_lane_line "$f")
    [ -z "$lane_val" ] && continue
    host=$(lane_host_of "$lane_val"); ts=$(lane_ts_of "$lane_val")
    age=$(age_seconds "$ts")
    if ! is_stale "$age"; then
      echo "busy: $(slug_of "$f") $host age=${age}s"
      exit 1
    fi
  done
  echo "free"
  exit 0
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    claim)        [ $# -ge 1 ] || usage; cmd_claim "$@" ;;
    release)      [ $# -ge 1 ] || usage; cmd_release "$@" ;;
    status)       [ $# -ge 1 ] || usage; cmd_status "$@" ;;
    target-busy)  [ $# -ge 1 ] || usage; cmd_target_busy "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
