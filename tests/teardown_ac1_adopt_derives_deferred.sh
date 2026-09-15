#!/usr/bin/env bash
# teardown_ac1_adopt_derives_deferred.sh — PRD-build-burst-teardown-evidence
# AC1 (P0).
#
# Given a fake hcloud that lists server 111 created 3h ago and an
# attribution.jsonl with 5 rows for 111, when `up` adopts 111 with no
# session.json, then session.json has create_epoch equal to the fake
# `created`, runs_served 5, and last_routed_run equal to the newest row's
# date.
#
# DEFERRED at build time, with justification (matching this repo's own
# pullback_ac13 precedent for a P0-adjacent gap under real constraints):
# cmd_up's adopt branch — the exact state_write call this AC needs to
# change — was being concurrently edited in the same unisolated checkout by
# a sibling PRD (PRD-build-burst-run-slots-from-box, which added its own
# box_cores/box_mem_gb/box_disk_gb fields to the very same state_write call
# this fix needs) during this PRD's own build window. teardown_decision()
# itself (this PRD's core deliverable) already derives runs_served/
# last_routed_run correctly from attribution.jsonl for every OTHER caller
# (see teardown_ac3/ac4/ac5) — only `up`'s own adopt-time state_write still
# hardcodes runs_served=0/no create_epoch, exactly as before this PRD. This
# is a real, not-yet-closed gap; fixing it safely needs a fresh read of
# cmd_up's current adopt branch (post both PRDs landing) rather than a
# patch written against a body mid-edit by another agent.
set -uo pipefail
echo "FAIL teardown AC1: DEFERRED, out of this pass's safe scope — cmd_up's adopt state_write was concurrently being edited by a sibling PRD (PRD-build-burst-run-slots-from-box) in this same unisolated checkout at build time; fixing runs_served/create_epoch derivation there safely needs a fresh read of the post-merge body. See this file's own header for the full justification. Re-run this wrapper for real once cmd_up's adopt branch is stable." >&2
exit 1
