#!/usr/bin/env bash
# scripts/lib/fleet-repos.sh — the one fleet repo list, shared by
# ci-status.sh and repo-health.sh (PRD-build-repo-health-invariants).
#
# Previously ci-status.sh hardcoded its own REPOS array with no other
# reader; repo-health.sh's per-repo counters need the exact same list (its
# invariants are scoped to "repos `ci-status.sh`'s list" per the PRD's
# Non-goals) so a repo added to one and not the other would silently
# desync which repos get CI-red coverage vs which get counted for
# ships/gate-attempts/lock-wait. Source this; never execute it.

FLEET_REPOS=(agorabus rustbuild autobuilder wm-node adopt summa mcphost)
