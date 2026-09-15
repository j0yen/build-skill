#!/usr/bin/env bash
# gate-launch.sh — launch extend-gate.sh under a systemd --user transient
# unit, so the gate survives the invoking tick's own cgroup teardown.
# PRD-build-gate-launch-survives-tick.
#
# Defect this closes (verified 2026-09-15 16:07Z/16:12Z): a coordinator
# tick that runs `extend-gate.sh` as a background job of its own
# `claude -p` session dies when the tick's transient unit
# (claude-build-work.service) tears down its cgroup on exit — `ps`
# afterwards shows zero extend-gate/cargo processes, and nothing detects
# it (no live-gate marker existed anywhere). `systemd-run --user --collect`
# parents the gate under the user's systemd instance instead of the
# tick's own process tree, so it is unaffected by that teardown.
#
# usage: gate-launch.sh <build_into> --head <sha> --scope main|branch
#                        --slug <slug> [--wait] [-- <extra extend-gate.sh args>]
#
# Any argument not recognized above (e.g. --project-root <rel>) is passed
# straight through to extend-gate.sh unchanged.
#
# PATH the unit runs with: scripts/lib/cargo-route.sh's
# cargo_route_path_prefix() prepended to $PATH when that file exists at
# run time (another coder is adding it in a sibling worktree — this
# script only ever probes for it with `[ -f ]`, never creates or edits
# it); otherwise the current PATH, unchanged.
#
# ~/.config/wm-burst/.env is sourced (`set -a; . <env>; set +a`) inside
# the unit's `bash -c` BEFORE `exec`ing extend-gate.sh, when that file
# exists — plain `bash -c`, never `bash -lc` (a login shell re-sources
# ~/.bashrc and can reorder PATH out from under the prefix above).
#
# Writes state/gate-inflight/<slug>.json = {unit, pid, head, scope, repo,
# started_ts} BEFORE returning, and prints the unit name on stdout.
#
# Idempotent: a unit already active for the same slug+head prints it and
# exits 0, journaling `gate  already-running`. A unit already active for
# the same slug at a DIFFERENT head is refused (exit 2), journaling
# `gate  head-conflict`.
#
# --wait blocks until the unit is inactive and exits with the gate's own
# exit code (`systemctl --user show -p ExecMainStatus --value`).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
INFLIGHT_DIR="$STATE_DIR/gate-inflight"
EXTEND_GATE="${GATE_LAUNCH_EXTEND_GATE:-$HERE/extend-gate.sh}"
CARGO_ROUTE_LIB="${GATE_LAUNCH_CARGO_ROUTE_LIB:-$HERE/lib/cargo-route.sh}"
BURST_ENV="${GATE_LAUNCH_BURST_ENV:-$HOME/.config/wm-burst/.env}"
SYSTEMD_RUN="${GATE_LAUNCH_SYSTEMD_RUN:-systemd-run}"
SYSTEMCTL="${GATE_LAUNCH_SYSTEMCTL:-systemctl}"
JQ="${JQ:-jq}"
journal="${GATE_LAUNCH_JOURNAL:-$HOME/brain/journal/build/$(date -u +%Y-%m-%d).md}"

die() { echo "gate-launch: $2" >&2; exit "${1:-4}"; }
usage() {
  echo "usage: gate-launch.sh <build_into> --head <sha> --scope main|branch --slug <slug> [--wait]" >&2
  exit 4
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
jlog() {
  local slug_for_log="$1" msg="$2"
  mkdir -p "$(dirname "$journal")" 2>/dev/null || true
  printf '%s  %s  gate  %s\n' "$(now_iso)" "$slug_for_log" "$msg" >> "$journal"
}

[ -x "$EXTEND_GATE" ] || die 2 "missing $EXTEND_GATE"

[ $# -ge 1 ] || usage
repo_arg="$1"; shift
[ -n "$repo_arg" ] || usage
repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 1 "no such directory: $repo_arg"

head_sha="" scope="" slug="" wait_flag=0
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head_sha="${2:-}"; shift 2 ;;
    --scope) scope="${2:-}"; shift 2 ;;
    --slug) slug="${2:-}"; shift 2 ;;
    --wait) wait_flag=1; shift ;;
    --) shift; extra+=("$@"); break ;;
    *) extra+=("$1"); shift ;;
  esac
done
[ -n "$head_sha" ] && [ -n "$slug" ] || usage
case "$scope" in
  main|branch) ;;
  *) usage ;;
esac

mkdir -p "$INFLIGHT_DIR"
marker="$INFLIGHT_DIR/$slug.json"
sha7="${head_sha:0:7}"
unit="gate-$slug-$sha7.service"

# --- idempotence / head-conflict -------------------------------------------
if [ -f "$marker" ]; then
  m_unit="$("$JQ" -r '.unit // empty' "$marker" 2>/dev/null)"
  m_head="$("$JQ" -r '.head // empty' "$marker" 2>/dev/null)"
  if [ -n "$m_unit" ] && "$SYSTEMCTL" --user is-active "$m_unit" >/dev/null 2>&1; then
    if [ "$m_head" = "$head_sha" ]; then
      echo "$m_unit"
      jlog "$slug" "already-running (unit=$m_unit head=$head_sha)"
      exit 0
    fi
    jlog "$slug" "head-conflict (active_unit=$m_unit active_head=$m_head requested_head=$head_sha)"
    die 2 "head-conflict: $m_unit already running at $m_head, refusing $head_sha"
  fi
fi

# --- PATH: cargo-route.sh's prefix if present at run time, else unchanged --
path_prefix=""
if [ -f "$CARGO_ROUTE_LIB" ]; then
  # shellcheck source=/dev/null
  source "$CARGO_ROUTE_LIB"
  if command -v cargo_route_path_prefix >/dev/null 2>&1; then
    path_prefix="$(cargo_route_path_prefix)"
  fi
fi
launch_path="${path_prefix:+$path_prefix:}$PATH"

# --- build the unit's command: plain `bash -c`, never `bash -lc` ----------
inner="exec $(printf '%q' "$EXTEND_GATE") $(printf '%q' "$repo") --head $(printf '%q' "$head_sha") --scope $(printf '%q' "$scope") --slug $(printf '%q' "$slug")"
for a in "${extra[@]}"; do
  inner+=" $(printf '%q' "$a")"
done
if [ -f "$BURST_ENV" ]; then
  inner="set -a; . $(printf '%q' "$BURST_ENV"); set +a; $inner"
fi

started_ts="$(now_iso)"

"$SYSTEMD_RUN" --user --unit "$unit" --collect \
  -p WorkingDirectory="$repo" \
  --setenv="PATH=$launch_path" \
  bash -c "$inner" >&2
sr_rc=$?
[ "$sr_rc" -eq 0 ] || die 2 "systemd-run failed to launch $unit (rc=$sr_rc)"

pid="$("$SYSTEMCTL" --user show -p MainPID --value "$unit" 2>/dev/null)"
case "$pid" in ''|*[!0-9]*) pid=0 ;; esac

tmp_marker="$(mktemp "$INFLIGHT_DIR/.${slug}.XXXXXX")"
"$JQ" -n \
  --arg unit "$unit" \
  --argjson pid "$pid" \
  --arg head "$head_sha" \
  --arg scope "$scope" \
  --arg repo "$repo" \
  --arg started_ts "$started_ts" \
  '{unit: $unit, pid: $pid, head: $head, scope: $scope, repo: $repo, started_ts: $started_ts}' \
  > "$tmp_marker"
mv -f "$tmp_marker" "$marker"

echo "$unit"
jlog "$slug" "launched (unit=$unit head=$head_sha scope=$scope)"

if [ "$wait_flag" -eq 1 ]; then
  # Poll via gate-status.sh, not a raw ExecMainStatus read: --collect
  # unloads a finished unit's properties fast enough (observed
  # near-instantly on this host) that a direct `systemctl show` can
  # race and read a lying default (ExecMainStatus=0 for a unit whose
  # LoadState is already `not-found`). gate-status.sh already guards
  # LoadState before trusting ExecMainStatus, and falls back to the
  # repo's receipt/verdict freshness once the unit is truly gone.
  GATE_STATUS="${GATE_LAUNCH_GATE_STATUS:-$HERE/gate-status.sh}"
  while :; do
    st="$("$GATE_STATUS" "$slug")"
    case "$st" in
      running) sleep 1 ;;
      finished:*) exit "${st#finished:}" ;;
      lost) jlog "$slug" "wait-lost (unit=$unit)"; exit 1 ;;
      none|*) jlog "$slug" "wait-marker-vanished (unit=$unit status=$st)"; exit 1 ;;
    esac
  done
fi
exit 0
