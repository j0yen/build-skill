#!/usr/bin/env bash
# PRD-build-fail-loud-evidence-kept AC4: cmd_verify's rsync roundtrip
# check, on a real rsync failure, journals a probe-failed line carrying
# err="rsync..." and a log= path that actually exists and contains the
# rsync stderr.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/failloud-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: probe failed line names verify-rsync with rsync err= and a log=" \
  "ok  AC4: the named log file exists and contains the rsync error"
