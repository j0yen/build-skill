#!/usr/bin/env bash
# gate-wedge-remote-probe.sh — one-shot "is the box actually working on
# this worktree" sample for gate-wedge.sh's routed-progress signal
# (requirement 2b). Called at most once per wedge probe (ONE ssh round
# trip), never in a loop of its own.
#
# Usage: gate-wedge-remote-probe.sh <worktree>
# Stdout on success: "<cpu_ticks> <cargo_procs> <marker_age_s>" (a single
# space-separated line; marker_age_s is -1 when target/.burst-run-marker
# does not exist yet) and exit 0. Any failure — no active burst-lane
# session, ssh timeout, box unreachable — prints nothing and exits
# non-zero; gate-wedge.sh treats that as UNKNOWN, never as evidence of a
# wedge on its own.
#
# Reuses burst-lane.sh's own session state (session.json), ssh binary,
# ssh key, session-scoped known_hosts file (session hygiene — never
# ~/.ssh/known_hosts) and remote-path convention by SOURCING burst-lane.sh
# rather than re-deriving any of it — burst-lane.sh already guards its own
# `main "$@"` behind `[ "${BASH_SOURCE[0]}" = "${0}" ]`, so sourcing here
# defines every helper/variable without running the CLI dispatch, taking
# any lock, or touching the network itself.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
BURST_LANE_SH="${GATE_WEDGE_BURST_LANE_SH:-$HERE/burst-lane.sh}"

worktree="${1:-}"
[ -n "$worktree" ] && [ -d "$worktree" ] || exit 1
[ -r "$BURST_LANE_SH" ] || exit 1

# shellcheck source=burst-lane.sh
source "$BURST_LANE_SH"

ip="$(state_read ip 2>/dev/null)"
[ -n "$ip" ] || exit 1
[ "$(state_read verified 2>/dev/null)" = "true" ] || exit 1

worktree_abs="$(cd "$worktree" 2>/dev/null && pwd -P)" || exit 1
sync_root="$worktree_abs"
ws_root="$(workspace_root_for "$worktree_abs" 2>/dev/null || true)"
if [ -n "$ws_root" ] && [ -d "$ws_root" ]; then
  ws_root="$(cd "$ws_root" && pwd -P)"
  case "$worktree_abs" in
    "$ws_root") sync_root="$ws_root" ;;
    "$ws_root"/*) sync_root="$ws_root" ;;
    *) : ;;
  esac
fi
remote_path="$(remote_path_for "$sync_root")"
[ -n "$remote_path" ] || exit 1

remote_script='
import os, time, sys

remote_path = sys.argv[1]
target_env = "CARGO_TARGET_DIR=" + remote_path.rstrip("/") + "/target"

total = 0
procs = 0
for p in os.listdir("/proc"):
    if not p.isdigit():
        continue
    try:
        with open(f"/proc/{p}/comm") as f:
            comm = f.read().strip()
    except OSError:
        continue
    if comm not in ("cargo", "rustc"):
        continue
    try:
        with open(f"/proc/{p}/environ", "rb") as f:
            envs = f.read().split(b"\x00")
    except OSError:
        continue
    if not any(e.decode(errors="replace") == target_env for e in envs):
        continue
    try:
        with open(f"/proc/{p}/stat", "rb") as f:
            data = f.read().decode(errors="replace")
        rp = data.rfind(")")
        after = data[rp + 2:].split()
        total += int(after[11]) + int(after[12])
        procs += 1
    except (OSError, ValueError, IndexError):
        continue

marker = os.path.join(remote_path, "target", ".burst-run-marker")
try:
    age = int(time.time() - os.path.getmtime(marker))
except OSError:
    age = -1

print(f"{total} {procs} {age}")
'

out="$("$SSH_BIN" $(ssh_kh_args) -o ConnectTimeout=8 -o BatchMode=yes -i "$SSH_KEY" \
  "$REMOTE_USER@$ip" "python3 -c '$remote_script' '$remote_path'" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && [ -n "$out" ] || exit 1
printf '%s\n' "$out"
