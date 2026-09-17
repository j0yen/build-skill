#!/usr/bin/env bash
# land-resolve.sh — per-repo land-policy reader + (future) conflict
# resolver. PRD-build-land-conflict-resolver.
#
# Grounding: gate-debt-4f1112d landed a gate `pass`, then lost a shipped
# state to a rebase conflict in a generated file (agent/intent-card.json)
# that the land model had no way to tell apart from hand-written source
# (2026-09-17, see the PRD's Grounding line). This script is the first
# piece: a reader for the per-repo policy file (R2) that classifies a
# conflicted path as `generated`, `append_only`, or `source` — the
# classification gate-then-land.sh and worktree-extend.sh will call
# before treating a rebase conflict as fatal. Regen/union execution (R3),
# the bounded coder resolve (R4), and the ledger (R5) are later steps in
# this same PRD; this step lands only the schema + the classifier, wired
# to nothing yet (Non-goal for THIS step: no caller changed).
#
# Policy file: state/land-policy/<repo-basename>.json
#   {
#     "generated": [{"path": "<repo-relative path or glob>", "regen": "<command, may use {slug}>"}],
#     "append_only": ["<repo-relative path or glob>"]
#   }
# A repo with no policy file classifies every path `source` — R2's
# "missing policy -> today's behavior" (AC6).
#
# Subcommands:
#   land-resolve.sh policy-path <repo>
#       Prints the policy file path for <repo> (exists or not).
#   land-resolve.sh classify <repo> <path> [slug]
#       Prints one line: `class=generated regen=<cmd>` |
#       `class=append_only` | `class=source`. <path> is matched against
#       each policy entry with `case`-style glob matching (so a
#       `tests/suite_*.rs` policy entry matches `tests/suite_foo.rs`).
#       `{slug}` in a regen command is substituted with the optional
#       third argument (empty string if omitted). Exit 0 always for a
#       recognized subcommand with the two required args; malformed JSON
#       in the policy file is treated the same as a path-not-listed
#       (falls through to `source`) rather than a hard failure, since a
#       bad policy file must never block an otherwise-good land — this
#       mirrors AC6's fail-open shape.
#
# Exit: 0 ok | 2 usage error.
set -uo pipefail

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
LAND_POLICY_DIR="${LAND_POLICY_DIR:-$STATE_DIR/land-policy}"

usage() {
  echo "usage: land-resolve.sh policy-path <repo>" >&2
  echo "       land-resolve.sh classify <repo> <path> [slug]" >&2
  exit 2
}

policy_path_for() {
  local repo="$1"
  echo "$LAND_POLICY_DIR/$(basename "$repo").json"
}

# glob_match <path> <pattern> — case-style glob (supports `*`), repo-relative.
glob_match() {
  local path="$1" pattern="$2"
  # shellcheck disable=SC2254 # intentional glob, not literal
  case "$path" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_classify() {
  local repo="${1:-}" path="${2:-}" slug="${3:-}"
  [ -n "$repo" ] && [ -n "$path" ] || usage
  local policy; policy="$(policy_path_for "$repo")"

  if [ ! -f "$policy" ] || ! command -v jq >/dev/null 2>&1; then
    echo "class=source"
    return 0
  fi
  # Malformed JSON fails open to `source` (AC6 shape: a bad/missing policy
  # never blocks land, it just gets today's behavior for that path).
  if ! jq -e . "$policy" >/dev/null 2>&1; then
    echo "class=source"
    return 0
  fi

  local gen_entries; gen_entries="$(jq -r '(.generated // []) | .[] | .path + "\t" + (.regen // "")' "$policy" 2>/dev/null)"
  if [ -n "$gen_entries" ]; then
    while IFS=$'\t' read -r gpath gregen; do
      [ -n "$gpath" ] || continue
      if glob_match "$path" "$gpath"; then
        gregen="${gregen//\{slug\}/$slug}"
        echo "class=generated regen=$gregen"
        return 0
      fi
    done <<<"$gen_entries"
  fi

  local ao_entries; ao_entries="$(jq -r '(.append_only // [])[]' "$policy" 2>/dev/null)"
  if [ -n "$ao_entries" ]; then
    while IFS= read -r apath; do
      [ -n "$apath" ] || continue
      if glob_match "$path" "$apath"; then
        echo "class=append_only"
        return 0
      fi
    done <<<"$ao_entries"
  fi

  echo "class=source"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    policy-path) [ -n "${1:-}" ] || usage; policy_path_for "$1" ;;
    classify)    cmd_classify "${1:-}" "${2:-}" "${3:-}" ;;
    *) usage ;;
  esac
}

main "$@"
