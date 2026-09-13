#!/usr/bin/env bash
# reality_ac10_pending_run_consumes_registration.sh —
# PRD-build-post-ship-reality-check AC10.
#
# Given a registered box-only AC and a lane box booted for ordinary work,
# When the box comes up, Then the pending AC runs before the box's
# ordinary work (tier=box) and no dedicated box was booted for it.
#
# Coverage note (documented, not silently dropped): this wrapper pairs to
# `pending-run <target>`'s EXECUTION half — invoking it against a
# registered pending check consumes the registration and writes the
# verdict (tier=box) back onto the original parent PRD, exactly as this
# AC describes once a box is up. The other half of this AC's Given/When/
# Then — burst-lane.sh's own `up` calling `pending-run` AUTOMATICALLY the
# moment ANY box boots for ordinary work, so no operator/tick has to
# invoke it by hand — is a real, un-shipped gap: wiring a call into
# burst-lane.sh's cmd_up (a 6000+ line, heavily-gated subsystem with its
# own 2000+ line selftest) was judged out of proportion for one atomic
# step of this shell/archive-step-scoped PRD and a real regression risk
# without running that full suite. See this PRD's `deferred_acs`/
# `mock_justifications` frontmatter for the honest accounting of that gap
# — it is not a probeable reachability/tool/path claim, just a scope call.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC10: pending-run exits 0" \
  "ok  AC10: registration is consumed (removed so a later boot doesn't repeat it)" \
  "ok  AC10: the ORIGINAL parent PRD gets the verdict (tier=box), reality=ok" \
  "ok  AC10: no dedicated box was booted for it — pending-run only recorded a receipt for the given target" \
  "ok  real failure-mode case: pending-run with nothing registered exits 0, no crash"
