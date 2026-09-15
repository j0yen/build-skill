#!/usr/bin/env bash
# provefx_ac17_sigpipe_pipefail_fresh_target.sh — regression for commit
# ac319ac (PRD-build-burst-prove-forensics).
#
# Given a pulled cargo target with 8000 files, all newer than the marker,
# When assert's freshness check runs under `set -uo pipefail`, Then
# routed=true. Before ac319ac, that check was `find -L ... | grep -q .`:
# `grep -q` exits after its first match, `find` takes SIGPIPE (exit 141),
# pipefail fails the pipeline, and the leading `!` turns a genuinely fresh
# target into cause=no-fresh-artifact. Three real boxes (~€0.5) were burned
# on this because every prior fixture's target was too small for `find` to
# ever get killed before `grep` was satisfied — this fixture's 8000 files
# reproduce the race that a handful of files could not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC17: a pulled target with 8000 files newer than the marker asserts routed=true (find must not die of SIGPIPE under pipefail)" \
  "ok  provefx AC17: proof.json routed=true, not no-fresh-artifact"
