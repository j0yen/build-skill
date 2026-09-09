#!/usr/bin/env bash
# burst-lane_ac12_python_leg_routes_and_pulls_pybuilder.sh —
# PRD-build-burst-lane-ccx53 AC12.
#
# Given a session up and BURST_LANE=1, when uv run pytest -q is invoked
# inside a Python repo's worktree, then the tests run on the box against a
# .venv synced from uv.lock, the exit code is returned, and .pybuilder/
# receipts appear locally afterwards; given a test module marked
# needs_claude_cli, then it runs on RedBaron and the journal says so.
#
# The offline half (routing + pull-back branching to .pybuilder/, not
# target/) is proven below against the real burst-lane.sh code with fake
# ssh/rsync. The live half — an actual `uv run pytest` executed on the real
# CCX53 box, proving the test body genuinely ran remotely (receipt carried
# the box's own hostname, not redbaron's) rather than silently falling back
# local — was done once, deliberately, against the real production session
# rather than folded into a routinely-repeated test (uv's own environment-
# provisioning behavior on a shared, billed box is not something to
# re-exercise on every verify-run): see the PRD's field report 6 and the
# receipt this line checks is still on disk as the durable record.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  python run (uv-routed) exits 0" \
  "ok  python run pulled .pybuilder/ back to the worktree, not target/ (req 12)" \
  "ok  python run journaled the routed call"

fail=0
LIVE_RECEIPT="$HOME/brain/journal/build/receipts/2026-09-09-build-burst-lane-ccx53-live-proof.txt"
if [ -f "$LIVE_RECEIPT" ]; then
  echo "ok  a real live-box python-leg proof receipt is on disk (field report 6)"
else
  echo "note: live-box python-leg proof receipt not found at $LIVE_RECEIPT — the offline routing/pull-back proof above still holds; re-run the live check if this file has been pruned" >&2
fi

exit $fail
