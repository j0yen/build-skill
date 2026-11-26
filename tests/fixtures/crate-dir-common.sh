#!/usr/bin/env bash
# crate-dir-common.sh — shared fixture for tests/crate_dir_ac*.sh
# (PRD-build-contract-declared-crate-dir). Source it; it mints one mktemp root
# ($CD_ROOT) holding a PRD corpus ($CD_Q = its build-queue/) and a fixture
# Python repo ($CD_PY: root pyproject.toml only, no ledger-read/ yet). Nothing
# outside $CD_ROOT is written; the lint never fetches (no Live AC in a fixture).
set -uo pipefail
CD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CD_REPO="$(cd "$CD_HERE/.." && pwd)"
CD_LINT="$CD_REPO/scripts/prd-lint.sh"
[ -x "$CD_LINT" ] || { echo "FAIL: $CD_LINT not executable" >&2; exit 2; }

CD_ROOT="$(mktemp -d)"
trap 'rm -rf "$CD_ROOT"' EXIT
export PRD_LINT_CACHE="$CD_ROOT/cache"
export BUILD_JOURNAL_ROOT="$CD_ROOT/journal"
mkdir -p "$CD_ROOT/corpus/build-queue" "$CD_ROOT/corpus/built-prds" "$CD_ROOT/corpus/parked" "$CD_ROOT/corpus/visions"
echo "plain vision." > "$CD_ROOT/corpus/visions/plain.md"
CD_Q="$CD_ROOT/corpus/build-queue"
CD_PY="$CD_ROOT/swarm"
mkdir -p "$CD_PY"
printf '[project]\nname = "swarm"\n' > "$CD_PY/pyproject.toml"

cd_fail=0
cd_expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; cd_fail=1; fi
}

# cd_prd <file> <build_target> <build_into> [crate_dir value; "-" = no crate_dir line]
# A queued, grounded, seeded PRD that is otherwise lint-clean, so every finding
# a test sees comes from the substrate/crate_dir checks under test.
cd_prd() {
  local f="$1" target="$2" into="$3" crate="${4:--}"
  {
    printf '# PRD: crate dir fixture\n\n'
    printf -- '- Status: queued\n- build_target: %s\n- build_into: %s\n' "$target" "$into"
    [ "$crate" = "-" ] || printf -- '- crate_dir: %s\n' "$crate"
    printf -- '- build_priority: high\n- Drafted: 2026-11-18\n- Seed: joe:2026-11-18\n'
    printf -- '- Vision: visions/plain.md\n- Grounding: grounded\n\n'
    printf '## Acceptance criteria\n\n1. P0 — Given a fixture, When the crate builds, Then it exits 0.\n'
  } > "$f"
}

# cd_lint <file>: prd-lint --format json; sets $cd_out (the JSON) and $cd_rc (its exit)
cd_lint() { cd_out="$("$CD_LINT" --format json "$1" 2>/dev/null)"; cd_rc=$?; }

# cd_ids <json> <failures|warnings> -> the ids, one per line
cd_ids() { printf '%s' "$1" | python3 -c 'import json,sys; [print(x["id"]) for x in json.load(sys.stdin)[0].get(sys.argv[1], [])]' "$2"; }

# cd_msgs <json> <failures|warnings> <id> -> that id's messages, one per line
cd_msgs() { printf '%s' "$1" | python3 -c 'import json,sys; [print(x["message"]) for x in json.load(sys.stdin)[0].get(sys.argv[1], []) if x["id"] == sys.argv[2]]' "$2" "$3"; }
