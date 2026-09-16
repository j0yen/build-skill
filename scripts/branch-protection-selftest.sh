#!/usr/bin/env bash
# branch-protection-selftest.sh — offline coverage for branch-protection.sh's
# workflow-name -> terminal-job resolution (PRD-build-main-push-gate
# requirement 6). Never calls `gh` — the GitHub-facing half (enable/status,
# actually setting protection) is verified LIVE, once, against the real
# j0yen/mcphost repo per this PRD's AC6/AC7, journaled separately; a mock
# of GitHub's branch-protection semantics would prove nothing about
# whether GitHub actually blocks/allows a direct push, which is exactly
# the question AC6 exists to answer for real.
#
# This selftest instead locks down the one piece that IS safely fixture-
# testable offline: given a `.github/workflows/*.yml` file, does
# resolve_checks() correctly pick out the workflow's TERMINAL jobs (the
# ones nothing else `needs:`), for both the flow-style (`needs: [a, b]`)
# and block-list (`needs:\n  - a`) YAML forms, and does an unresolvable
# name pass through as a literal context.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

# Extract resolve_checks() verbatim from the real script so this test
# tracks the real implementation rather than a hand-copied duplicate.
RC_FN="$(awk '/^resolve_checks\(\)/,/^}/' "$HERE/branch-protection.sh")"
eval "$RC_FN"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bpselftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/.github/workflows"

cat > "$ROOT/.github/workflows/ci.yml" <<'EOF'
name: ci
on: [push]
jobs:
  gate:
    runs-on: ubuntu-latest
    steps: []
  sandbox:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1, 2]
    steps: []
  sandbox-required:
    name: sandbox suites (all shards)
    needs: sandbox
    if: always()
    runs-on: ubuntu-latest
    steps: []
EOF

cat > "$ROOT/.github/workflows/deploy.yml" <<'EOF'
name: deploy
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps: []
  test:
    needs: [build]
    runs-on: ubuntu-latest
    steps: []
  publish:
    needs:
      - build
      - test
    runs-on: ubuntu-latest
    steps: []
EOF

resolved_ci="$(resolve_checks "$ROOT" ci | sort)"
# gate has no `name:` (falls back to its job key); sandbox-required DOES
# set one -- GitHub's required-status-check contexts match the check
# run's DISPLAY name (the job's `name:` field when set), not the YAML job
# key, so the resolved context here must be "sandbox suites (all
# shards)", never the literal key "sandbox-required" (the real mcphost
# bug this fixture reproduces: a required context of `gate`/
# `sandbox-required` left the AC7 PR permanently BLOCKED even after both
# jobs went green, because neither job posts a check run by that literal
# name).
expect "flow-style needs: ci resolves to gate + sandbox-required's DISPLAY name" \
  '[ "$resolved_ci" = "$(printf "gate\nsandbox suites (all shards)" | sort)" ]'

resolved_deploy="$(resolve_checks "$ROOT" deploy | sort)"
expect "block-list needs: deploy resolves to publish only" \
  '[ "$resolved_deploy" = "publish" ]'

resolved_literal="$(resolve_checks "$ROOT" some-context-name)"
expect "unresolvable name passes through as a literal context" \
  '[ "$resolved_literal" = "some-context-name" ]'

resolved_all="$(resolve_checks "$ROOT" | sort)"
expect "no name given resolves every workflow's terminal jobs (by display name)" \
  '[ "$resolved_all" = "$(printf "gate\npublish\nsandbox suites (all shards)" | sort)" ]'

exit "$fail"
