#!/usr/bin/env bash
# provefx_ac15_assert_diagnosis_fields.sh — PRD-build-burst-prove-forensics
# AC15.
#
# Given a fixture run whose pull lands zero files newer than the pulled
# marker, When assert fails, Then proof.json contains local_target, files,
# newest_mtime, marker_mtime, remote_date, and skew_s, and the journal
# `prove failed` line carries the same fields.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC15: prove exits 1 when the box compiled nothing newer than the marker" \
  "ok  provefx AC15: proof.json cause=no-fresh-artifact" \
  "ok  provefx AC15: proof.json carries the full assert diagnosis" \
  "ok  provefx AC15: the journal failed line carries the same diagnosis fields"
