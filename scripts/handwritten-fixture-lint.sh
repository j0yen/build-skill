#!/usr/bin/env bash
# scripts/handwritten-fixture-lint.sh — PRD-build-burst-gate-canary-
# invariant R16/AC19: a selftest under scripts/ or tests/ that hand-types
# a `burst-lane.sh status --json`-shaped JSON literal (an object carrying
# both an "active" key and a "gate_ready" key, typed inline in a printf/
# heredoc/echo) encodes the AUTHOR's assumption about that command's
# shape, not the command's real shape — AC9's own hand-written `width`
# fixture (build-skill df62b99) is the evidence: it encoded a key
# (`width`) the real script no longer emits, undetected for a week. The
# fix (see select-guard-same-target-cap-selftest.sh) is to load
# tests/fixtures/burst-status.json (a recorded REAL output, kept honest by
# tests/canary_ac18_fixture_parity.sh) and override just the field(s)
# under test via jq. This script is the lint that catches a regression
# back to the old pattern.
#
# What counts as a violation: a line containing a JSON object literal with
# both `"active"` and `"gate_ready"` as keys (the two keys every real
# status --json fake in this repo's history has hand-typed together) —
# NOT a bare `.gate_ready` jq path expression, and NOT a session.json-
# shaped fixture (server_id/ip/ttl_hours/... — no top-level "active" key,
# since burst-lane.sh's real session.json never stores one; "active" is
# synthesized by cmd_status itself). tests/fixtures/burst-status.json, the
# one recorded fixture this whole mechanism exists to route selftests
# through, is always exempt.
#
# Usage:
#   handwritten-fixture-lint.sh <path>...   # lint exactly these files
#   handwritten-fixture-lint.sh --all       # scripts/*-selftest.sh,
#                                            # scripts/*_selftest.sh, and
#                                            # every tests/*.sh (excluding
#                                            # tests/fixtures/**)
#
# Exit: 0 no violations | 1 one or more `handwritten-interface-fixture
# <file>:<line>` violations printed to stdout | 2 usage error
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
FIXTURE_REAL="$SKILL_DIR/tests/fixtures/burst-status.json"

usage() { echo "usage: handwritten-fixture-lint.sh <path>... | --all" >&2; exit 2; }

[ "$#" -ge 1 ] || usage

declare -a targets=()
if [ "$1" = "--all" ]; then
  shopt -s nullglob
  for f in "$SKILL_DIR"/scripts/*-selftest.sh "$SKILL_DIR"/scripts/*_selftest.sh; do
    targets+=("$f")
  done
  while IFS= read -r -d '' f; do
    targets+=("$f")
  done < <(find "$SKILL_DIR/tests" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
  shopt -u nullglob
else
  targets=("$@")
fi

violations=0
for f in "${targets[@]}"; do
  [ -f "$f" ] || continue
  # Exempt the canonical recorded fixture itself and anything under
  # tests/fixtures/ — those are the recording, not a fake.
  case "$f" in
    "$FIXTURE_REAL") continue ;;
    */tests/fixtures/*) continue ;;
  esac
  out="$(python3 - "$f" <<'PYEOF'
import re, sys
path = sys.argv[1]
pat_active = re.compile(r'"active"\s*:\s*"?true"?')
pat_gate = re.compile(r'"gate_ready"\s*:')
try:
    with open(path, "r", errors="replace") as fh:
        for i, line in enumerate(fh, start=1):
            if pat_active.search(line) and pat_gate.search(line):
                print(f"{path}:{i}")
except OSError:
    pass
PYEOF
)"
  if [ -n "$out" ]; then
    while IFS= read -r loc; do
      [ -n "$loc" ] || continue
      echo "handwritten-interface-fixture $loc"
      violations=1
    done <<<"$out"
  fi
done

exit "$violations"
