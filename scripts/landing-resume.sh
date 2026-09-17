#!/usr/bin/env bash
# landing-resume.sh — PRD-build-main-push-gate-pr-path requirement 6/7
# (P0, AC8/AC9): the TICK-RESUME half of the push-via-branch landing
# sequence `gate-then-land.sh` starts (see that script's own header,
# "PR-path landing"). A PRD whose manifest sidecar carries
# `last_step=landing-pending` already has a `state/landings/<repo>/
# <slug>.json` record written by `branch-protection.sh push` — this
# script is what a LATER tick calls INSTEAD OF dispatching that PRD's
# normal build phases, to find out whether the PR has merged and, if so,
# hand it back to the ordinary post-land path.
#
# Division of labor mirrors gate-then-land.sh's own success contract: on
# a normal land, gate-then-land.sh does not itself mark the PRD `shipped`
# — it prints the landed sha and exits 0, and the CALLER (SKILL.md's
# per-PRD dispatch) runs the remaining main-scope gate + ship-tag +
# manifest steps. This script's `merged`+`sync` success path does exactly
# the same thing: it clears `last_step` (the PRD stops being resume-only)
# and prints the synced sha on stdout — the caller resumes at the SAME
# "gate" [--scope main] step SKILL.md already runs after any other
# successful land, because `origin/main` now genuinely holds a pushed
# sha and the `ci-checks` producer has a real merged-and-green landing
# record to build a `pass` receipt from (extend-gate.sh:1617-1667). This
# script never itself writes `status=shipped`, never itself runs
# extend-gate.sh, and never itself archives the PRD — those stay the
# coordinator's job, unchanged.
#
# Usage: landing-resume.sh <repo> <slug> [--pending-max SECONDS]
#
# <repo> is the build_into main checkout (a real path, already resolved
# by the caller — same contract as gate-then-land.sh's own <repo> arg).
# --pending-max overrides $LANDING_PENDING_MAX (default 21600s / 6h,
# requirement 7).
#
# Makes exactly one `gh` call (via `branch-protection.sh landing-check`,
# itself bounded — see that script's own header) plus, only on a
# `merged` verdict, one `sync` call (local git only, no `gh`).
#
# Exit codes:
#   0  merged + sync ok — `last_step` cleared, synced sha printed on
#      stdout. Caller resumes the ordinary post-land steps from here.
#   1  usage error
#   2  merged, but `sync` refused or failed (tree-diff / dirty /
#      not-on-main / infra) — `last_step=landing-pending` is left AS IS
#      for a retry next tick (this PRD's non-goals exclude auto-merging
#      a diverged tree; `sync`'s own journal line already names why).
#   3  pending, under the bound — no state change, journaled.
#   4  pending, at/over the bound — PRD `blocked`,
#      `last_error=pr-checks-timeout`, a decision opened naming the PR.
#   5  red <check> — PRD `blocked`, `last_error=pr-checks-red:<check>`,
#      the red-gate alarm fires.
#   6  closed — PRD `blocked`, `last_error=pr-closed`.
#   7  `branch-protection.sh landing-check` itself failed unexpectedly
#      (not one of its documented 0/3/4/5 verdicts) — no state change,
#      journaled, safe to retry next tick.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"

BRANCH_PROTECTION="${LANDING_RESUME_BRANCH_PROTECTION:-$HERE/branch-protection.sh}"
SIDECAR="${LANDING_RESUME_SIDECAR:-$HERE/manifest-sidecar.sh}"
ALERT_DELIVER="${LANDING_RESUME_ALERT_DELIVER:-$HERE/alert-deliver.sh}"
DECISIONS="${LANDING_RESUME_DECISIONS:-$HERE/decisions.sh}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"

die() { echo "landing-resume: $2" >&2; exit "$1"; }
usage() { echo "usage: landing-resume.sh <repo> <slug> [--pending-max SECONDS]" >&2; }

pending_max="${LANDING_PENDING_MAX:-21600}"
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pending-max) pending_max="${2:?landing-resume: --pending-max needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) pos+=("$1"); shift ;;
  esac
done
repo="${pos[0]:-}"; slug="${pos[1]:-}"
[ -n "$repo" ] && [ -n "$slug" ] || { usage; die 1 "missing <repo>/<slug>"; }
repo="$(cd "$repo" 2>/dev/null && pwd)" || die 1 "no such directory: ${pos[0]:-}"
repo_slug="$(basename "$repo")"

journal="${LANDING_RESUME_JOURNAL:-$HOME/brain/journal/build/$(date -u +%Y-%m-%d).md}"
if [ -r "$HERE/isolation-guard.sh" ]; then
  # shellcheck source=isolation-guard.sh
  source "$HERE/isolation-guard.sh"
  isolation_guard_path "$journal" "landing-resume.sh"
fi
mkdir -p "$(dirname "$journal")"
jlog() { printf '%s  landing-resume  %s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$1" >>"$journal"; }

record="$(landing_record_path "$repo_slug" "$slug")"
[ -f "$record" ] || die 1 "no landing record at $record — nothing to resume"

armed_at="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    d = {}
print(d.get('armed_at') or '')
" "$record")"

pr_number="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    d = {}
print(d.get('pr_number') or '')
" "$record")"

now_epoch="$(date -u +%s)"
armed_epoch=0
if [ -n "$armed_at" ]; then
  armed_epoch="$(date -u -d "$armed_at" +%s 2>/dev/null || echo 0)"
fi
elapsed=$(( armed_epoch > 0 ? now_epoch - armed_epoch : 0 ))

check_out="$("$BRANCH_PROTECTION" landing-check "$repo" "$slug" 2>&1)"
check_rc=$?

case "$check_rc" in
  0)
    merged_sha="$(printf '%s' "$check_out" | awk '{print $2}')"
    sync_out="$("$BRANCH_PROTECTION" sync "$repo" 2>&1)"
    sync_rc=$?
    echo "$sync_out" >&2
    if [ "$sync_rc" -eq 0 ]; then
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_step=" \
        "outcome=landing-synced merged=$merged_sha" >&2 || true
      rm -f "$record"
      jlog "landing-resolved merged=$merged_sha pr=${pr_number:-unknown}"
      printf '%s\n' "$merged_sha"
      exit 0
    fi
    # sync refused/failed (exit 6 refused, or any other infra rc) — its
    # OWN main-sync-refused/journal line already explains why (cmd_sync
    # journals that itself); `last_step` is left untouched so the next
    # tick's resume tries `sync` again (requirement: "this PRD does not
    # attempt to merge" a genuinely diverged tree — Technical
    # considerations, "Squash sha vs local sha").
    jlog "landing-sync-deferred merged=$merged_sha rc=$sync_rc"
    exit 2
    ;;
  3)
    if [ "$elapsed" -ge "$pending_max" ]; then
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "status=blocked" \
        "last_error=pr-checks-timeout" "outcome=pr-checks-timeout pr=${pr_number:-unknown} elapsed=${elapsed}s" >&2 || true
      if [ -x "$DECISIONS" ]; then
        "$DECISIONS" open "PR #${pr_number:-unknown} for $repo_slug/$slug has been pending required checks for ${elapsed}s (>= ${pending_max}s bound) — landing-resume can no longer wait; needs an operator look at the PR." \
          --owner "Joe Yen" --repo "$repo_slug" --blocks "$slug" >/dev/null 2>&1 || true
      fi
      jlog "pr-checks-timeout pr=${pr_number:-unknown} elapsed=${elapsed}s bound=${pending_max}s"
      exit 4
    fi
    jlog "landing-pending $repo_slug#${pr_number:-unknown} elapsed=${elapsed}s"
    exit 3
    ;;
  4)
    failing_check="$(printf '%s' "$check_out" | cut -d' ' -f2-)"
    [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "status=blocked" \
      "last_error=pr-checks-red:$failing_check" "outcome=pr-checks-red check=$failing_check pr=${pr_number:-unknown}" >&2 || true
    jlog "ALARM pr-checks-red (check=$failing_check repo=$repo_slug pr=${pr_number:-unknown})"
    if [ -x "$ALERT_DELIVER" ]; then
      evidence="$(mktemp "${TMPDIR:-/tmp}/landing-resume-red.XXXXXX")"
      printf 'value=1 -- pr-checks-red check=%s repo=%s pr=%s slug=%s\n' \
        "$failing_check" "$repo_slug" "${pr_number:-unknown}" "$slug" > "$evidence"
      "$ALERT_DELIVER" gate-red build-loop "$evidence" >/dev/null 2>&1 || true
      rm -f "$evidence"
    fi
    exit 5
    ;;
  5)
    [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "status=blocked" \
      "last_error=pr-closed" "outcome=pr-closed pr=${pr_number:-unknown}" >&2 || true
    jlog "pr-closed pr=${pr_number:-unknown}"
    exit 6
    ;;
  *)
    jlog "landing-check-infra-failure rc=$check_rc out=$check_out"
    die 7 "branch-protection.sh landing-check failed unexpectedly (rc=$check_rc): $check_out"
    ;;
esac
