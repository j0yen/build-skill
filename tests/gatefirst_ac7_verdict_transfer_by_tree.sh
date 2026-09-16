#!/usr/bin/env bash
# gatefirst_ac7_verdict_transfer_by_tree.sh — PRD-build-gate-before-land
# AC7.
#
# Given a landed branch whose merge tree equals the gated tree, When
# `extend-gate.sh <build_into> --head <landed sha>` runs, Then it exits
# with the cached verdict, runs no producer, and journals
# (cached tree=... from=branch slug=...); given a merge whose tree
# differs, Then a full main-scope run happens.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_treecache_and_expect_labels \
  "ok  AC7a setup: land exits 0" \
  "ok  AC7a setup: merge tree equals the branch's gated tree" \
  "ok  AC7a: main's cache file was written by land's transfer" \
  "ok  AC7a: transferred cache carries the branch's tree_sha" \
  "ok  AC7a: transferred cache's head_sha was refreshed to the landed sha" \
  "ok  AC7a: transferred cache kept scope=branch" \
  "ok  AC7b: post-land main gate exits 0 (cached pass)" \
  "ok  AC7b: stdout reports (cached)" \
  "ok  AC7b: NO producer output (proof of no real run — audit/intake/etc never printed)" \
  "ok  AC7b: a cache-hit journal line was written" \
  "ok  AC7c: legacy schema has no tree_sha (reads empty, guaranteed miss)" \
  "ok  AC7d: a tree_sha mismatch never prints (cached)"
