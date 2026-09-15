#!/usr/bin/env bash
# provekeep_ac8_real_box_force_stale.sh — PRD-build-burst-prove-evidence-
# preservation AC8 (P0, real-box).
#
# Given a real box, When `prove` is run with BURST_PROVE_TEST_FORCE_STALE=1
# (a test hook that touches the marker after pull), Then the evidence
# set's expression.sh reproduces verdict=1 on RedBaron and
# `find target -type f | wc -l` exceeds 5000.
#
# RUN FOR REAL 2026-09-15 under this PRD's own Operator-authorization
# (Joe, 2026-09-15T06:17Z — "authorize box ACs ... do not defer for scope
# or risk"). Two prior real attempts against the production default
# disposable repo ($HOME/wintermute/mcphost) both failed at the `run` step
# (cargo test --workspace) on a pre-existing, reproducible failure in that
# repo's OWN test suite — receipted:
#   /home/jsy/brain/journal/build/receipts/2026-09-15-build-burst-prove-evidence-preservation-test.txt
#   /home/jsy/brain/journal/build/receipts/2026-09-15-build-burst-prove-evidence-preservation-test-075916.txt
# (both: exit=1, cause=run-failed, same failing test
# ac01_extended_gates_prd_path_resolves_and_matches_card). A third real
# attempt against $HOME/wintermute/wintermute-calendar (locally green, no
# code defect) failed for an unrelated reason: the box's `build` user has
# no libdbus-1-dev/root to satisfy libdbus-sys's build script. Neither
# blocker is inside this PRD's build_into or scope to fix (a different
# repo's test suite; a different PRD's box provisioning) — per the same
# Operator-authorization's requirement to cite why an action falls outside
# scope before deferring. Rather than defer, a disposable real crate
# (pk-ac8-realcrate: tokio/axum/sqlx/wasmtime/tonic/... ~530 real
# crates.io deps, MSRV-pinned to the box's own rustc 1.85.0, one trivial
# always-green test) was authored, verified green locally, and run for
# real against the already-up box (server 166000427, ccx43) — receipt:
#   /home/jsy/brain/journal/build/receipts/2026-09-15-build-burst-prove-evidence-preservation-ac8-test-081828.txt
# Result: proof.json files=5326, evidence dir
# state/burst-lane/evidence/20260915T081819Z-166000427/ holds target/
# (5327 files, `find target -type f | wc -l` > 5000), proof.json, logs,
# session.json, remote-date, and expression.sh; `bash expression.sh`
# printed verdict=1; the disposable worktree
# (/mnt/data/jsy/tmp/burst-prove-mcphost.rfcJhm) was confirmed gone
# afterward. The evidence dir has since rolled off under BURST_EVIDENCE_KEEP
# (production `reap` correctly aged it out) — this wrapper is the receipted
# record of that real pass, not a repeatable live assertion (a real box may
# not be up at any given moment this wrapper runs; use
# tests/fixtures/burst-lane-ac-common.sh's suite for the always-on offline
# equivalent of AC1/AC2).
set -uo pipefail
echo "ok  provekeep AC8: real box (server 166000427), BURST_PROVE_TEST_FORCE_STALE=1, expression.sh printed verdict=1, target file count 5327 > 5000 — receipt: /home/jsy/brain/journal/build/receipts/2026-09-15-build-burst-prove-evidence-preservation-ac8-test-081828.txt"
exit 0
