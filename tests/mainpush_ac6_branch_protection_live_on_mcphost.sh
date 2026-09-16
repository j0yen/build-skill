#!/usr/bin/env bash
# mainpush_ac6_branch_protection_live_on_mcphost.sh — PRD-build-main-push-gate
# AC6: given `branch-protection.sh enable mcphost --check ci`, when
# `status` runs, then GitHub reports the required check; and when a direct
# push of a red (untested) head is attempted from a scratch clone, then
# GitHub refuses it (or the script records push-via-branch=true and AC7
# applies) — live on RedBaron, one run, result journaled.
#
# This is a LIVE check, not a fixture: AC6 is explicitly a one-time
# real-infrastructure verification (branch protection settings on the real
# j0yen/mcphost repo), not something a throwaway git+cargo fixture can
# stand in for — same reasoning as build-contract.md's "real-box" AC
# convention, applied here without that literal marker since this PRD's
# own text predates it. Rather than re-running the live push-refusal
# probe on every archive-gate pass (which would mutate mcphost's PR/branch
# state every time), this re-checks the DURABLE evidence the live run
# left behind: state/branch-protection.json's push_via_branch record,
# cross-checked against GitHub's actual CURRENT protection settings via
# `gh api` (a live read, no mutation) — so a manual `branch-protection.sh
# disable`-equivalent or a settings drift would flip this back to a
# failure, not silently keep reporting a stale pass.
#
# Requires: gh authenticated, network reachable. Skips (exit 0, journaled
# skip) rather than failing when gh is unavailable -- this test verifies
# a LIVE state, and "can't reach GitHub" is an environment gap, not a
# regression in this PRD's own code.
set -uo pipefail

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

STATE_FILE="${BUILD_STATE_DIR:-$HOME/.claude/skills/build/state}/branch-protection.json"

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "SKIP AC6: gh not available/authenticated — cannot verify live GitHub state" >&2
  exit 0
fi

expect "AC6: state/branch-protection.json records mcphost" \
  '[ -f "$STATE_FILE" ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if \"mcphost\" in d else 1)" "$STATE_FILE"'

expect "AC6: recorded push_via_branch=true (the live direct-push refusal this PRD found)" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"mcphost\",{}).get(\"push_via_branch\") is True else 1)" "$STATE_FILE"'

live_contexts="$(gh api repos/j0yen/mcphost/branches/main/protection --jq '.required_status_checks.contexts // [] | join(",")' 2>/dev/null)"
expect "AC6: GitHub currently reports required status checks on mcphost main" \
  '[ -n "$live_contexts" ]'
expect "AC6: live required contexts match the recorded state" \
  'recorded="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(\",\".join(d.get(\"mcphost\",{}).get(\"required_contexts\",[])))" "$STATE_FILE")"; [ "$live_contexts" = "$recorded" ]'

exit "$fail"
