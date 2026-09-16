#!/usr/bin/env bash
# multibox_ac9_reap_orphan_box.sh — PRD-build-burst-state-keyed-by-server-v2
# AC9.
#
# Given a fixture server `wm-burst-lane-9` with no `boxes/` directory, When
# `reap` runs, Then it is deleted with `reap  orphan-box-deleted`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC9 setup: the orphan server has no boxes/<id>/ dir yet" \
  "ok  multibox AC9: the orphan server is gone from hcloud" \
  "ok  multibox AC9: journal has 'reap  orphan-box-deleted' naming the orphan server" \
  "ok  multibox AC9: the legitimate box (has a boxes/<id>/ dir) is untouched"
