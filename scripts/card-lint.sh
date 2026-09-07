#!/usr/bin/env bash
# card-lint.sh — fast pass/fail validator for a repo's agent/intent-card.json,
# so an over-limit field is caught at write time instead of surfacing later
# as a missing `intake` gate receipt (PRD-fleet-intent-card-conformance: two
# fleet repos' cards silently regrew content-length violations between gate
# runs because nothing linted a card between writes).
#
# Delegates the actual limits to the real `autobuilder intake --validate`
# binary rather than re-deriving `intake.rs`'s ALLOWED_TOP / per-field caps
# here — this script is a thin wrapper, never a second source of truth.
#
# usage: card-lint.sh <repo> [--project-root <rel>] [--card <path>]
#
#   <repo>            Path to the repo to lint.
#   --project-root <rel>
#                     Relative path (from <repo>) to the Cargo project root,
#                     for a repo whose crate lives below the repo root (e.g.
#                     autobuilder's own nested crate at autobuilder/). When
#                     omitted, <repo> itself is used as the project root —
#                     matches extend-gate.sh's --project-root convention.
#   --card <path>     Validate this card file instead of
#                     <repo>/agent/intent-card.json. Used by callers that
#                     validate a not-yet-renamed temp file (write-to-temp,
#                     validate, rename) before it becomes the real card, and
#                     by this repo's own regression test fixtures.
#
# Exit codes:
#   0  card validates; the validator's pass message (and, when --project
#      resolves to a real Cargo project, its receipt-write line) is printed
#   1  card fails validation; the validator's violation message (naming the
#      offending field) is printed to stderr
#   2  a precondition is missing: <repo> not found, no readable card at the
#      resolved path, --project-root names a nonexistent directory, or the
#      `autobuilder` binary is neither on $PATH nor buildable from
#      ~/wintermute/autobuilder/autobuilder
set -uo pipefail

die() { echo "card-lint: $2" >&2; exit "$1"; }

usage() {
  echo "usage: card-lint.sh <repo> [--project-root <rel>] [--card <path>]" >&2
}

repo=""
project_root_rel=""
card_override=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root) project_root_rel="${2:?card-lint: --project-root needs a value}"; shift 2 ;;
    --card)         card_override="${2:?card-lint: --card needs a value}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift ;;
    -*)             echo "card-lint: unknown flag $1" >&2; usage; exit 2 ;;
    *)
      if [ -z "$repo" ]; then repo="$1"
      else echo "card-lint: too many arguments" >&2; usage; exit 2
      fi
      shift ;;
  esac
done

[ -n "$repo" ] || { usage; exit 2; }
[ -d "$repo" ] || die 2 "repo not found: $repo"
repo_abs="$(cd "$repo" && pwd)"

if [ -n "$project_root_rel" ]; then
  project_abs="$repo_abs/$project_root_rel"
  [ -d "$project_abs" ] || die 2 "no directory at --project-root $project_root_rel (looked in $project_abs)"
else
  project_abs="$repo_abs"
fi

card_path="${card_override:-$repo_abs/agent/intent-card.json}"
[ -r "$card_path" ] || die 2 "card not found or unreadable: $card_path"

# Binary discovery: PATH first, then build from the fleet's own autobuilder
# checkout (per this PRD's technical considerations — non-interactive ssh
# lacks ~/.local/bin, so a lane running this over a login shell may need the
# build fallback even when a workstation session would find it on PATH).
AUTOBUILDER_SRC="$HOME/wintermute/autobuilder/autobuilder"
bin=""
if command -v autobuilder >/dev/null 2>&1; then
  bin="autobuilder"
elif [ -x "$AUTOBUILDER_SRC/target/release/autobuilder" ]; then
  bin="$AUTOBUILDER_SRC/target/release/autobuilder"
elif [ -f "$AUTOBUILDER_SRC/Cargo.toml" ]; then
  echo "card-lint: autobuilder not on \$PATH; building release binary from $AUTOBUILDER_SRC" >&2
  if ( cd "$AUTOBUILDER_SRC" && cargo build --release ) >&2; then
    [ -x "$AUTOBUILDER_SRC/target/release/autobuilder" ] && bin="$AUTOBUILDER_SRC/target/release/autobuilder"
  fi
fi
[ -n "$bin" ] || die 2 "autobuilder binary not found on \$PATH and could not be built from $AUTOBUILDER_SRC"

out="$("$bin" intake --validate "$card_path" --project "$project_abs" 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "card-lint: PASS $card_path"
  echo "$out"
  exit 0
fi

echo "card-lint: FAIL $card_path" >&2
echo "$out" >&2
exit 1
