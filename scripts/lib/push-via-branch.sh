#!/usr/bin/env bash
# lib/push-via-branch.sh — PRD-build-main-push-gate-pr-path shared helper.
#
# `push_via_branch_for <repo_slug>` was originally a private function
# inside branch-protection.sh (PRD-build-main-push-gate AC6/AC7); this
# PRD's landing sequence needs the SAME answer in gate-then-land.sh
# (requirement 1/AC1-AC2: skip the direct-push post-land re-verify for a
# protected repo) and main-push-gate.sh (requirement 5/AC7: accept a
# branch-scope verdict via the PR path) — factored out here so all three
# callers read one state file with one piece of logic, rather than three
# copies drifting apart. `landing_record_path` is the second thing every
# caller of the landing record (branch-protection.sh's own push/landing-
# check/sync, plus gate-then-land.sh and the tick resume path) needs to
# agree on byte-for-byte.
#
# Must be sourced (not executed) with $STATE_DIR already set by the
# caller (every caller in this repo resolves `${BUILD_STATE_DIR:-<skill>/
# state}` before sourcing this file — see branch-protection.sh,
# gate-then-land.sh, main-push-gate.sh).
#
# push_via_branch_for <repo_slug> -> "true"/"false" (default "false" —
# never assume the branch-only path for a repo `enable` never ran
# against).
push_via_branch_for() {
  local repo_slug="$1" state_file="${STATE_DIR:?push_via_branch_for: STATE_DIR not set}/branch-protection.json"
  [ -f "$state_file" ] || { echo false; return; }
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        state = json.load(fh)
except (OSError, json.JSONDecodeError):
    state = {}
rec = state.get(sys.argv[2]) or {}
print('true' if rec.get('push_via_branch') else 'false')
" "$state_file" "$repo_slug"
}

# landing_record_path <repo_slug> <slug> — state/landings/<repo>/<slug>.json,
# one file per in-flight landing (Technical considerations). Written by
# branch-protection.sh's `push` once a PR is opened/reused and auto-merge
# armed; read by `landing-check`/`sync` and by the tick resume path.
landing_record_path() {
  local repo_slug="$1" slug="$2"
  echo "${STATE_DIR:?landing_record_path: STATE_DIR not set}/landings/$repo_slug/$slug.json"
}
