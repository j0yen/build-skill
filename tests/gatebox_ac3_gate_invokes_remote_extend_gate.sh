#!/usr/bin/env bash
# gatebox_ac3_gate_invokes_remote_extend_gate.sh — PRD-build-gate-on-casper AC3.
#
# Given parity ok and a fake session, When `burst-lane.sh gate <repo>
# --head <sha>` runs, Then the fake remote `extend-gate.sh` is invoked once
# with `--head <sha>`, only `target/autobuilder/` and `.gate-burst-host`
# are rsynced back, `last-verdict.json` carries `host: <fake box>`, the
# exit code equals the remote's, and the journal gate line contains
# `host=<fake box>`. Also covers "extend-gate.sh remote-aware invocation":
# the box's redirected journal folds onto RedBaron's own tick journal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC3: gate propagates the remote extend-gate.sh's own exit code" \
  "ok  gatebox AC3: fake extend-gate.sh was invoked with --head <sha>" \
  "ok  gatebox AC3: only target/autobuilder/ and .gate-burst-host were rsynced back (nothing else)" \
  "ok  gatebox AC3: last-verdict.json carries a host field (extend-gate.sh itself never touched)" \
  "ok  gatebox AC3: journal gate line names the verdict, host, and wall time" \
  "ok  gatebox AC3 (extend-gate.sh remote-aware): the box's redirected journal folded onto RedBaron's tick journal" \
  "ok  gatebox AC3 (extend-gate.sh remote-aware): the folded journal was not left behind under target/autobuilder/"
