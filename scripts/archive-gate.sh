#!/usr/bin/env bash
# archive-gate.sh — PRD-build-skill-instruction-single-source R1: the ONE
# executable a branch agent's archive check (or any SKILL.md site that
# used to spell out the main-scope archive/land gate command in prose)
# calls to launch that gate for a landed slug. It decides both the sha
# and the FORM (pinned vs plain) from the repo's push_via_branch state
# and the slug's own landing record, so no caller ever re-derives "which
# sha do I gate" from a paragraph again.
#
# Grounding: at 15:42:50Z on 2026-09-17, agent-wake's agent obeyed
# SKILL.md check #6's then-stale prose and gated mcphost's checkout HEAD
# instead of the slug's own merge sha — `no landing record for mcphost`
# at main scope, one obedient agent, a full gate wall wasted. The command
# was written out seven times in SKILL.md; when the rule changed, one
# copy changed and six did not. This script (plus SKILL.md's single
# canonical section, scripts/skill-prose-lint.sh, and gate-launch.sh's
# own R3 refusal) is the fix: one script decides, prose only points at it.
#
# usage: archive-gate.sh <build_into> <slug> [--wait]
#
# Behavior:
#   push_via_branch=true (state/branch-protection.json):
#     requires state/landings/<repo>/<slug>.json. When absent, reconstructs
#     it from `gh pr view loop/<slug>` of the (expected-merged) PR —
#     pr_url, pr_number, head_sha, merge_sha, armed_at, reconstructed_from
#     — before continuing (R1/AC2). Then:
#       gate-launch.sh <build_into> --head <build_into HEAD> --scope main
#         --slug <slug> --pinned-landing [--wait]
#     --head here is used by gate-launch.sh ONLY for the unit name and
#     idempotence/head-conflict marker; main-verdict-pin-gate.sh (what
#     --pinned-landing routes to) re-resolves the slug's OWN merge sha
#     independently via landing-verdict-resolve.sh and gates THAT, never
#     this value — same contract gate-launch.sh's own header documents.
#
#   push_via_branch=false (or no branch-protection.json entry at all):
#     gate-launch.sh <build_into> --head <landed sha> --scope main --slug
#       <slug> [--wait]
#     where <landed sha> is `git -C <build_into> rev-parse HEAD` — the
#     bump commit right after the push, exactly the derivation SKILL.md's
#     "gate" ship action already documented. This script is now the ONE
#     place that derivation lives.
#
# Prints the exact gate-launch.sh command it ran (one line, to stdout,
# before invoking it) and exits with gate-launch.sh's own exit code.
#
# Exit: whatever gate-launch.sh returns | 1 usage | 2 missing dependency |
#   3 <build_into> not a resolvable git repo | 4 push_via_branch=true, no
#   landing record, and reconstruction failed (no merged loop/<slug> PR)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
GATE_LAUNCH="${ARCHIVE_GATE_GATE_LAUNCH:-$HERE/gate-launch.sh}"
OWNER="${ARCHIVE_GATE_OWNER:-${BRANCH_PROTECTION_OWNER:-j0yen}}"
GH="${ARCHIVE_GATE_GH:-gh}"
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"
journal="${ARCHIVE_GATE_JOURNAL:-$(journal_root)/$(date -u +%Y-%m-%d).md}"

die() { echo "archive-gate: $2" >&2; exit "$1"; }
usage() { echo "usage: archive-gate.sh <build_into> <slug> [--wait]" >&2; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
jlog() {
  local slug_for_log="$1" msg="$2"
  journal_line --file "$journal" "$(printf '%s  %s  archive-gate  %s' "$(now_iso)" "$slug_for_log" "$msg")"
}

[ $# -ge 2 ] || usage
repo_arg="$1" slug="$2"; shift 2
[ -n "$repo_arg" ] && [ -n "$slug" ] || usage
wait_flag=0
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_flag=1; shift ;;
    *) usage ;;
  esac
done

[ -x "$GATE_LAUNCH" ] || die 2 "missing $GATE_LAUNCH"
repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 3 "no such directory: $repo_arg"
repo_slug="$(basename "$repo")"

pvb="$(push_via_branch_for "$repo_slug")"

launch_args=()
if [ "$pvb" = true ]; then
  record="$(landing_record_path "$repo_slug" "$slug")"
  if [ ! -f "$record" ]; then
    # R1/AC2: reconstruct from the merged loop/<slug> PR — one `gh pr
    # view` call, same shape branch-protection.sh's own landing-check
    # already makes, so a lost/never-armed record is not a dead end.
    pr_json="$("$GH" pr view "loop/$slug" --repo "$OWNER/$repo_slug" \
      --json number,url,state,mergeCommit,headRefOid 2>&1)"
    gh_rc=$?
    if [ "$gh_rc" -ne 0 ]; then
      jlog "$slug" "reconstruct-failed (no landing record, gh pr view loop/$slug rc=$gh_rc)"
      die 4 "no landing record for $repo_slug/$slug and gh pr view loop/$slug failed: $pr_json"
    fi
    state_ok="$(printf '%s' "$pr_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    d = {}
print('ok' if d.get('state') == 'MERGED' and (d.get('mergeCommit') or {}).get('oid') else 'no')
")"
    if [ "$state_ok" != ok ]; then
      jlog "$slug" "reconstruct-failed (loop/$slug is not a merged PR)"
      die 4 "no landing record for $repo_slug/$slug and loop/$slug is not a merged PR"
    fi
    mkdir -p "$(dirname "$record")"
    armed_at="$(now_iso)"
    printf '%s' "$pr_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
out = {
    'pr_url': d.get('url', ''),
    'pr_number': d.get('number'),
    'head_sha': d.get('headRefOid', ''),
    'merge_sha': (d.get('mergeCommit') or {}).get('oid', ''),
    'armed_at': sys.argv[1],
    'reconstructed_from': 'archive-gate.sh: gh pr view loop/' + sys.argv[2],
}
with open(sys.argv[3], 'w', encoding='utf-8') as fh:
    json.dump(out, fh, indent=2)
    fh.write('\n')
" "$armed_at" "$slug" "$record"
    jlog "$slug" "reconstructed (record=$record)"
  fi
  head_marker="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  [ -n "$head_marker" ] || die 3 "cannot resolve HEAD in $repo"
  launch_args=("$repo" --head "$head_marker" --scope main --slug "$slug" --pinned-landing)
else
  landed_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  [ -n "$landed_sha" ] || die 3 "cannot resolve HEAD in $repo"
  launch_args=("$repo" --head "$landed_sha" --scope main --slug "$slug")
fi
[ "$wait_flag" -eq 1 ] && launch_args+=(--wait)

printf 'archive-gate: %s' "$GATE_LAUNCH"
printf ' %q' "${launch_args[@]}"
printf '\n'
jlog "$slug" "launch ($(printf '%s ' "${launch_args[@]}"))"
"$GATE_LAUNCH" "${launch_args[@]}"
exit $?
