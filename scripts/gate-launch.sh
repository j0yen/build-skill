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
#                        --slug <slug> [--wait] [--pinned-landing]
#                        [-- <extra extend-gate.sh args>]
#
# Any argument not recognized above (e.g. --project-root <rel>) is passed
# straight through to extend-gate.sh unchanged.
#
# --pinned-landing (PRD-build-main-verdict-pinned-to-landing R1): for a
# push_via_branch=true repo's post-land re-verify / landing-resume
# resumption / archive main-green question, the caller resolves M (the
# slug's OWN merge sha, via scripts/landing-verdict-resolve.sh) and passes
# it as --head — used here ONLY for the unit's name and the idempotence/
# head-conflict marker, per the usual contract. The unit itself execs
# scripts/main-verdict-pin-gate.sh <build_into> <slug>, which re-resolves
# M independently and gates a DETACHED worktree at it, never the
# checkout's HEAD (--scope main required; --scope branch + --pinned-
# landing is a usage error). This is the fix for the 2026-09-17 05:15:46Z
# regression: a re-verify launched with `--head` computed from the
# checkout's then-current HEAD, one PRD later than the slug's own landing.
# A direct-push repo (no landing record) never passes this flag — see
# SKILL.md's "gate" step and "Resuming a landing-pending PRD" section for
# exactly which callers do.
#
# --main-health (PRD-build-main-verdict-pinned-to-landing R6): the tick's
# "is main green right now" question, independent of any particular PRD's
# landing — bare current HEAD, no PRD card, reviewer-agent and
# intent-card-refresh scope-deferred inside extend-gate.sh, ci-checks read
# straight from Actions runs at HEAD (never a PR's checks, even on a
# push_via_branch=true repo — see extend-gate.sh's own R6 comments).
# Caller resolves the repo's current main HEAD itself and passes it as
# --head (unlike --pinned-landing, this flag does NOT reroute to a
# different entrypoint — it is forwarded straight through to
# extend-gate.sh, same as any other passthrough flag), and defaults
# --slug to the "main-health" sentinel when omitted. Requires --scope
# main; mutually exclusive with --pinned-landing. extend-gate.sh's own
# tree-keyed verdict cache (R4, already generalized past pinned-landing)
# makes a second call at the same tree a fast cache-hit replay rather
# than a full producer run — "once per new sha" falls out of that for
# free, no separate cache needed here.
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
# PRD-build-main-verdict-pinned-to-landing R1 (consumer wiring): with
# --pinned-landing, the unit execs main-verdict-pin-gate.sh <repo> <slug>
# instead of extend-gate.sh <repo> --head ... --scope ... --slug ... —
# main-verdict-pin-gate.sh resolves the slug's OWN merge sha M from its
# landing record itself (never trusts a caller-computed --head for what
# to actually gate), which is the fix for the 2026-09-17 05:15:46Z
# regression: a re-verify that ran at the checkout's current HEAD instead
# of the landed PRD's own merge sha. This still gets the systemd-run
# survive-tick-teardown wrapping below unchanged — only the exec target
# inside the unit changes.
MAIN_VERDICT_PIN_GATE="${GATE_LAUNCH_MAIN_VERDICT_PIN_GATE:-$HERE/main-verdict-pin-gate.sh}"
CARGO_ROUTE_LIB="${GATE_LAUNCH_CARGO_ROUTE_LIB:-$HERE/lib/cargo-route.sh}"
BURST_ENV="${GATE_LAUNCH_BURST_ENV:-$HOME/.config/wm-burst/.env}"
SYSTEMD_RUN="${GATE_LAUNCH_SYSTEMD_RUN:-systemd-run}"
SYSTEMCTL="${GATE_LAUNCH_SYSTEMCTL:-systemctl}"
JQ="${JQ:-jq}"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"
# shellcheck source=lib/repo-slug.sh
source "$HERE/lib/repo-slug.sh"
# PRD-build-flow-ledger requirement 2: this script is the sole writer of
# the ledger's `gate_start` event — every gate run (main-scope, branch-
# scope, pinned-landing, main-health alike) launches through here, so one
# call at the point the unit is actually started, never re-derived later
# from a journal grep. flow_ledger_append never fails the caller.
# shellcheck source=lib/flow-ledger.sh
source "$HERE/lib/flow-ledger.sh"
journal="${GATE_LAUNCH_JOURNAL:-$(journal_root)/$(date -u +%Y-%m-%d).md}"

die() { echo "gate-launch: $2" >&2; exit "${1:-4}"; }
usage() {
  echo "usage: gate-launch.sh <build_into> --head <sha> --scope main|branch --slug <slug> [--wait]" >&2
  exit 4
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# PRD-build-journal-single-writer requirement 1: routed through journal_line
# instead of a private printf >>. GATE_LAUNCH_JOURNAL is now a legacy alias
# journal_line itself understands (scripts/lib/journal.sh), so this still
# honors the same override gate-launch-selftest.sh already sets.
jlog() {
  local slug_for_log="$1" msg="$2"
  journal_line --file "$journal" "$(printf '%s  %s  gate  %s' "$(now_iso)" "$slug_for_log" "$msg")"
}

[ -x "$EXTEND_GATE" ] || die 2 "missing $EXTEND_GATE"

[ $# -ge 1 ] || usage
repo_arg="$1"; shift
[ -n "$repo_arg" ] || usage
repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 1 "no such directory: $repo_arg"

head_sha="" scope="" slug="" wait_flag=0 pinned_landing=0 main_health=0
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head_sha="${2:-}"; shift 2 ;;
    --scope) scope="${2:-}"; shift 2 ;;
    --slug) slug="${2:-}"; shift 2 ;;
    --wait) wait_flag=1; shift ;;
    --pinned-landing) pinned_landing=1; shift ;;
    --main-health) main_health=1; shift ;;
    --) shift; extra+=("$@"); break ;;
    *) extra+=("$1"); shift ;;
  esac
done
# PRD-build-main-verdict-pinned-to-landing R6: a main-health caller has no
# slug of its own (bare-HEAD, "is main green now") — default it to the
# same "main-health" sentinel extend-gate.sh itself defaults to, so the
# inflight marker filename/unit name and journal calls below have
# something non-empty to key on, same as every other caller of this
# script already needs.
if [ "$main_health" -eq 1 ] && [ -z "$slug" ]; then
  slug="main-health"
fi
[ -n "$head_sha" ] && [ -n "$slug" ] || usage
case "$scope" in
  main|branch) ;;
  *) usage ;;
esac
if [ "$pinned_landing" -eq 1 ]; then
  [ "$scope" = main ] || die 4 "--pinned-landing requires --scope main"
  [ -x "$MAIN_VERDICT_PIN_GATE" ] || die 2 "missing $MAIN_VERDICT_PIN_GATE"
fi
if [ "$main_health" -eq 1 ]; then
  [ "$scope" = main ] || die 4 "--main-health requires --scope main"
  [ "$pinned_landing" -eq 0 ] || die 4 "--main-health and --pinned-landing are mutually exclusive"
fi

# PRD-build-skill-instruction-single-source R3: a raw `--scope main --slug
# <slug>` call (the pre-fix form seven SKILL.md sites duplicated in
# prose) is refused for a push_via_branch=true repo once a landing record
# exists for that slug — the caller must resolve --pinned-landing itself
# via archive-gate.sh instead of re-deriving --head from the checkout's
# current HEAD, which may already belong to a LATER-landed PRD (the
# 2026-09-17 05:15:46Z regression this whole PRD chain exists to close).
# --main-health and an explicit --pinned-landing are both exempt above by
# construction (this check only runs for the plain extend-gate.sh form);
# a direct-push repo (push_via_branch=false, no landing record) is
# unaffected. Exit 6 is distinct from every other exit this script uses.
if [ "$scope" = main ] && [ "$pinned_landing" -eq 0 ] && [ "$main_health" -eq 0 ]; then
  repo_slug_pv="$(repo_slug_for_ci "$repo")"
  if [ "$(push_via_branch_for "$repo_slug_pv")" = true ]; then
    record_pv="$(landing_record_path "$repo_slug_pv" "$slug")"
    if [ -f "$record_pv" ]; then
      jlog "$slug" "refused (raw --scope main for push_via_branch=true repo $repo_slug_pv, use archive-gate.sh)"
      die 6 "refusing --scope main --slug $slug without --pinned-landing for push_via_branch=true repo $repo_slug_pv (landing record exists at $record_pv) — call scripts/archive-gate.sh instead"
    fi
  fi
fi

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
# PRD-build-main-verdict-pinned-to-landing R1: --pinned-landing execs
# main-verdict-pin-gate.sh <repo> <slug> instead — it resolves the slug's
# OWN merge sha M and gates a detached worktree at M itself (its own
# header); $head_sha/$scope above were only ever used for this unit's
# name and the idempotence/head-conflict marker check, never passed
# through as what to actually gate.
if [ "$pinned_landing" -eq 1 ]; then
  inner="exec $(printf '%q' "$MAIN_VERDICT_PIN_GATE") $(printf '%q' "$repo") $(printf '%q' "$slug")"
else
  inner="exec $(printf '%q' "$EXTEND_GATE") $(printf '%q' "$repo") --head $(printf '%q' "$head_sha") --scope $(printf '%q' "$scope") --slug $(printf '%q' "$slug")"
  # PRD-build-main-verdict-pinned-to-landing R6: unlike --pinned-landing
  # (which routes to a whole different entrypoint that re-resolves its
  # own head), --main-health is a plain extend-gate.sh flag — this
  # caller already resolved $head_sha itself (the checkout's own current
  # HEAD; R5 in extend-gate.sh refuses anything else), so it is passed
  # straight through, same as any other extend-gate.sh passthrough flag.
  [ "$main_health" -eq 1 ] && inner="$inner --main-health"
fi
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
flow_ledger_append "$slug" "gate_start" --sha "$head_sha" --detail "scope=$scope"

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
      lost)
        # PRD-build-burst-gate-canary-invariant AC1, observed
        # 2026-09-18T04:36:03Z/04Z: a cache-hit-fast gate can complete and
        # get systemd --collect'd, with its receipts landing on disk,
        # inside the same wall-clock second gate-status.sh's very first
        # (and, before this fix, only) poll ran -- the receipts existed
        # one second after started_ts (canary-runs/1789706163-main's
        # 25-file receipt set), yet the single un-retried check still
        # read "lost" and this loop exited terminally on the first
        # sighting, unlike "running" which re-polls. Give the sub-second
        # write-lag one grace re-check before committing to lost.
        sleep "${GATE_LAUNCH_LOST_GRACE_S:-2}"
        st2="$("$GATE_STATUS" "$slug")"
        case "$st2" in
          finished:*) exit "${st2#finished:}" ;;
          *) jlog "$slug" "wait-lost (unit=$unit)"; exit 1 ;;
        esac
        ;;
      none|*) jlog "$slug" "wait-marker-vanished (unit=$unit status=$st)"; exit 1 ;;
    esac
  done
fi
exit 0
