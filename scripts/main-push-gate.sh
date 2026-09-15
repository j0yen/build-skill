#!/usr/bin/env bash
# main-push-gate.sh — the head the loop pushes to main is the head the
# gate tested (PRD-build-main-push-gate).
#
# The branch gate (extend-gate.sh) proves a worktree HEAD; the intent-card
# refresh then commits a DIFFERENT head on top of it (PRD-build-intent-
# card-refresh), and until this script existed nothing re-tested that new
# head before it was pushed to a repo's main. Two loop commits
# (mcphost bb44d28, 3c11214) broke main this way in three days because the
# refresh's card template drifted from extended-gates.toml. This script is
# the missing check: it diffs the sha the branch gate actually tested
# against the sha about to be pushed, and — for anything other than an
# identical sha — runs the repo's declared CI-equivalent command for that
# delta before the push is allowed to happen.
#
# Usage:
#   main-push-gate.sh <repo> [--gated <sha>] [--head <sha>] [--changed <paths>]
#
#   <repo>      Absolute path to a build_into repo, or a bare name resolved
#               against ~/wintermute/<name> (the fleet's repo-root
#               convention — same resolution ci-status.sh and REPOS.md use).
#   --gated     The sha the branch gate actually tested. Defaults to the
#               `head` field of <repo>/target/autobuilder/last-verdict.json
#               (extend-gate.sh's own verdict cache — real repos like
#               mcphost already carry `head`/`head_sha` in this file, so no
#               cross-repo receipt-schema change was needed; see the PRD's
#               Technical considerations).
#   --head      The sha about to be pushed. Defaults to <repo>'s current
#               HEAD (git rev-parse HEAD).
#   --changed   Comma- or whitespace-separated list of paths, overriding
#               the `git diff --name-only <gated> <head>` delta computation
#               (requirement 5 — a refresh step that touches generated
#               files not necessarily visible to git in a worktree-relative
#               sense can pass its own `changed: <paths>` stdout line
#               through here instead).
#
# Delta -> check resolution: reads <repo>/.buildloop/ci-equivalent.toml,
# a two-table TOML file:
#
#   [delta]
#   "intent-card.json" = "cargo test --test intent_card"
#
#   [default]
#   command = "cargo test --workspace"
#
# When every changed path is a key in [delta] and they all map to the SAME
# command, that command runs (the "card-only delta" fast path this PRD's
# Goals target under 3 minutes). Otherwise [default].command runs. A repo
# with no .buildloop/ci-equivalent.toml at all gets `unknown` (rc 5) with a
# journal line naming the missing file (requirement/AC8) — never treated as
# green by omission.
#
# Exit: 0 ok (including the identical-sha short-circuit, delta=0, no
#         command run — requirement 2)
#       4 refused (the resolved check ran and exited nonzero, and did not
#         time out)
#       5 unknown (no receipt/no --gated resolvable, no ci-equivalent.toml,
#         or the check exceeded the 15-minute timeout — rc=124, AC9)
#       2 usage
#
# Journal (requirement 1): one line per run to the shared build journal
# (scripts/lib/journal.sh) —
#   <ts>  <slug>  main-push  <ok|refused|unknown>  (repo=<repo> gated=<sha7>
#     head=<sha7> delta=<n> check="<cmd>" rc=<n> wall=<s>)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

CHECK_TIMEOUT_SECS="${MAIN_PUSH_GATE_TIMEOUT:-900}"   # 15 minutes (AC9)

usage() {
  echo "usage: main-push-gate.sh <repo> [--gated <sha>] [--head <sha>] [--changed <paths>]" >&2
}

die() {
  local rc="$1"; shift
  echo "main-push-gate: $*" >&2
  exit "$rc"
}

repo_arg=""
gated_want=""
head_want=""
changed_override=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gated)   gated_want="${2:?main-push-gate: --gated needs a value}"; shift 2 ;;
    --head)    head_want="${2:?main-push-gate: --head needs a value}"; shift 2 ;;
    --changed) changed_override="${2:?main-push-gate: --changed needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift ;;
    -*) echo "main-push-gate: unknown flag $1" >&2; usage; exit 2 ;;
    *)
      if [ -z "$repo_arg" ]; then repo_arg="$1"
      else echo "main-push-gate: too many arguments" >&2; usage; exit 2
      fi
      shift ;;
  esac
done
[ -n "$repo_arg" ] || { usage; exit 2; }

# Resolve <repo>: absolute/relative path if it exists, else a bare fleet
# slug under ~/wintermute/<name> (same convention as ci-status.sh's REPOS
# list and REPOS.md). `.git` can be a directory (a real checkout) OR a
# gitfile (a `git worktree` checkout, e.g. worktree-extend.sh's own
# per-slug worktrees) — `git rev-parse --git-dir` is the real test, not a
# hardcoded `-d`.
if git -C "$repo_arg" rev-parse --git-dir >/dev/null 2>&1; then
  repo="$(cd "$repo_arg" && pwd)"
elif git -C "$HOME/wintermute/$repo_arg" rev-parse --git-dir >/dev/null 2>&1; then
  repo="$HOME/wintermute/$repo_arg"
else
  die 2 "not a git repo: $repo_arg (checked as given and as ~/wintermute/$repo_arg)"
fi

slug="$(basename "$repo")"

emit() {
  # emit <outcome> <gated> <head> <delta_n> <check> <rc> <wall>
  local outcome="$1" gated="$2" head="$3" delta_n="$4" check="$5" rc="$6" wall="$7"
  local gated7="${gated:0:7}" head7="${head:0:7}"
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  main-push  $outcome  (repo=$slug gated=${gated7:-none} head=${head7:-none} delta=$delta_n check=\"$check\" rc=$rc wall=${wall}s)"
}

# --- resolve head -------------------------------------------------------
head_now="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || die 5 "cannot resolve HEAD in $repo"
if [ -n "$head_want" ]; then
  head_resolved="$(git -C "$repo" rev-parse --verify "${head_want}^{commit}" 2>/dev/null || true)"
  [ -n "$head_resolved" ] || die 2 "--head $head_want does not resolve to a commit in $repo"
  head_now="$head_resolved"
fi

# --- resolve gated sha ---------------------------------------------------
gated_now=""
if [ -n "$gated_want" ]; then
  gated_now="$(git -C "$repo" rev-parse --verify "${gated_want}^{commit}" 2>/dev/null || true)"
  if [ -z "$gated_now" ]; then
    emit unknown "" "$head_now" "n/a" "n/a" "n/a" 0
    die 5 "--gated $gated_want does not resolve to a commit in $repo"
  fi
else
  verdict_file="$repo/target/autobuilder/last-verdict.json"
  if [ -f "$verdict_file" ]; then
    gated_now="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
h = d.get("head") or d.get("head_sha") or ""
print(h)
' "$verdict_file" 2>/dev/null)"
  fi
  if [ -z "$gated_now" ]; then
    emit unknown "" "$head_now" "n/a" "n/a" "n/a" 0
    die 5 "no --gated given and no head/head_sha found in $verdict_file"
  fi
fi

# --- identical shas: short-circuit ok, delta=0, no command (requirement 2) ---
if [ "$gated_now" = "$head_now" ]; then
  emit ok "$gated_now" "$head_now" 0 "n/a" 0 0
  echo "main-push-gate: ok — $slug gated==head (${head_now:0:7}), delta=0, no check run"
  exit 0
fi

# --- compute delta -------------------------------------------------------
if [ -n "$changed_override" ]; then
  # comma- or whitespace-separated
  # shellcheck disable=SC2206
  changed=(${changed_override//,/ })
else
  mapfile -t changed < <(git -C "$repo" diff --name-only "$gated_now" "$head_now" 2>/dev/null)
fi
delta_n="${#changed[@]}"

# --- read .buildloop/ci-equivalent.toml ----------------------------------
ci_equiv="$repo/.buildloop/ci-equivalent.toml"
if [ ! -f "$ci_equiv" ]; then
  emit unknown "$gated_now" "$head_now" "$delta_n" "n/a" "n/a" 0
  die 5 "missing $ci_equiv — no CI-equivalent command declared for $slug"
fi

resolved="$(python3 - "$ci_equiv" "${changed[@]}" <<'PY'
import sys, tomllib

toml_path = sys.argv[1]
changed = sys.argv[2:]

try:
    with open(toml_path, "rb") as fh:
        data = tomllib.load(fh)
except Exception as exc:
    print(f"MALFORMED\t{exc}")
    sys.exit(0)

delta_map = data.get("delta", {})
default_tbl = data.get("default", {})
default_cmd = default_tbl.get("command") if isinstance(default_tbl, dict) else None

if not default_cmd:
    print("MALFORMED\tno [default].command in ci-equivalent.toml")
    sys.exit(0)

if changed and all(p in delta_map for p in changed):
    mapped = {delta_map[p] for p in changed}
    if len(mapped) == 1:
        print(f"delta\t{mapped.pop()}")
        sys.exit(0)

print(f"default\t{default_cmd}")
PY
)"
resolved_kind="${resolved%%$'\t'*}"
resolved_cmd="${resolved#*$'\t'}"

if [ "$resolved_kind" = "MALFORMED" ]; then
  emit unknown "$gated_now" "$head_now" "$delta_n" "n/a" "n/a" 0
  die 5 "malformed $ci_equiv: $resolved_cmd"
fi

# --- run the resolved check, 15-minute ceiling (AC9) ---------------------
# PRD-build-cargo-concurrency-budget: any cargo invocation this skill makes
# routes through the shared host-wide concurrency budget, same as every
# worktree branch's cargo test/clippy/build/deny/nextest — this is a real
# `cargo test`/`cargo test --workspace` subprocess like any other, and a
# tick that dispatches several PRDs in parallel must not let this script
# add unthrottled cargo load of its own. No-op (empty PATH prefix) when
# the shim directory is absent or the repo has no Cargo.toml.
cargo_budget_bin="$SKILL_DIR/scripts/cargo-budget-bin"
path_prefix=""
[ -f "$repo/Cargo.toml" ] && [ -d "$cargo_budget_bin" ] && path_prefix="$cargo_budget_bin:"

start_epoch="$(date -u +%s)"
( cd "$repo" && PATH="${path_prefix}$PATH" timeout "$CHECK_TIMEOUT_SECS" bash -c "$resolved_cmd" ) >/tmp/main-push-gate.$$.out 2>&1
rc=$?
end_epoch="$(date -u +%s)"
wall=$(( end_epoch - start_epoch ))
rm -f "/tmp/main-push-gate.$$.out"

if [ "$rc" -eq 124 ]; then
  emit unknown "$gated_now" "$head_now" "$delta_n" "$resolved_cmd" "$rc" "$wall"
  die 5 "check exceeded ${CHECK_TIMEOUT_SECS}s timeout: $resolved_cmd"
fi

if [ "$rc" -ne 0 ]; then
  emit refused "$gated_now" "$head_now" "$delta_n" "$resolved_cmd" "$rc" "$wall"
  die 4 "refused — check failed (rc=$rc): $resolved_cmd"
fi

emit ok "$gated_now" "$head_now" "$delta_n" "$resolved_cmd" "$rc" "$wall"
echo "main-push-gate: ok — $slug gated=${gated_now:0:7} head=${head_now:0:7} delta=$delta_n wall=${wall}s"
exit 0
