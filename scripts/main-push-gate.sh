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
#                     [--writer-slug <slug>] [--project-root <rel>]
#
#   <repo>      Absolute path to a build_into repo, or a bare name resolved
#               against ~/wintermute/<name> (the fleet's repo-root
#               convention — same resolution ci-status.sh and REPOS.md use).
#   --gated     The sha the branch gate actually tested. Defaults to the
#               `head` field of <repo>/target/autobuilder/last-verdict.json
#               (extend-gate.sh's own verdict cache — real repos like
#               mcphost already carry `head`/`head_sha` in this file, so no
#               cross-repo receipt-schema change was needed; see the PRD's
#               Technical considerations) — or, when --project-root <rel> is
#               given, <repo>/<rel>/target/autobuilder/last-verdict.json
#               instead (below).
#   --head      The sha about to be pushed. Defaults to <repo>'s current
#               HEAD (git rev-parse HEAD).
#   --changed   Comma- or whitespace-separated list of paths, overriding
#               the `git diff --name-only <gated> <head>` delta computation
#               (requirement 5 — a refresh step that touches generated
#               files not necessarily visible to git in a worktree-relative
#               sense can pass its own `changed: <paths>` stdout line
#               through here instead).
#   --writer-slug   The PRD slug making this push (for the cross-repo-gate
#               journal line's `writer=` field only, PRD-build-cross-repo-
#               commit-gate). Purely cosmetic — omitting it just leaves
#               that field `writer=unknown`; the gated-repo check itself
#               (below) runs regardless.
#   --project-root <rel>   Path, relative to <repo>, of the Cargo crate root
#               when it is nested under a subdirectory (the autobuilder-
#               source-unify-style layout: <repo>/autobuilder/Cargo.toml,
#               not <repo>/Cargo.toml — PRD-build-main-push-gate-nested-
#               project-root). Same spelling/shape as extend-gate.sh's own
#               --project-root. When given, every place this script would
#               read <repo>/target/autobuilder/last-verdict.json (the
#               --gated default AND the gated-repo branch-verdict check
#               below) instead reads <repo>/<rel>/target/autobuilder/
#               last-verdict.json — the path a nested crate's own gate
#               actually writes to. Validated against a Cargo.toml at that
#               path; fails loud (never silently falls back to repo root)
#               if it's missing. Omitted: behavior is byte-identical to
#               before this flag existed (additive only, not a rewrite —
#               this PRD's Non-goals). Does NOT affect
#               <repo>/.buildloop/ci-equivalent.toml resolution, which
#               stays at the repo root regardless (out of this PRD's
#               scope).
#
# Gated-repo branch-verdict check (PRD-build-cross-repo-commit-gate
# requirement 3): when <repo> is registered as some OTHER rust-extend
# PRD's build_into (`gated-targets.sh is-gated`), a green CI-equivalent
# delta alone is not enough — this push also requires a FRESH branch-gate
# verdict (pass/delta-pass, from <repo>/target/autobuilder/last-verdict.json)
# for the EXACT head being pushed. Missing, stale (different head), or
# `block` all refuse (exit 1) with a `cross-repo-gate  refused  (writer=…
# target=… blocking=…)` journal line, BEFORE the CI-equivalent machinery
# below ever runs — never treated as green by omission. A repo that isn't
# a registered gated target is entirely unaffected (this whole check is a
# no-op for it, same as today).
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
# For a push_via_branch=true repo (PRD-build-main-push-gate-pr-path
# requirement 5, AC7), the line instead reads:
#   <ts>  <slug>  main-push  ok|refused  (repo=<repo> via=pr-path
#     gated=<sha> head=<sha> delta=0 [verdict=<v> reason=<r>])
# — full (untruncated) shas, no `check`/`rc`/`wall` fields (no local
# command runs; GitHub's own required checks on the PR are the check).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"

CHECK_TIMEOUT_SECS="${MAIN_PUSH_GATE_TIMEOUT:-900}"   # 15 minutes (AC9)

usage() {
  echo "usage: main-push-gate.sh <repo> [--gated <sha>] [--head <sha>] [--changed <paths>] [--writer-slug <slug>] [--project-root <rel>]" >&2
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
writer_slug=""
project_root_override=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gated)        gated_want="${2:?main-push-gate: --gated needs a value}"; shift 2 ;;
    --head)         head_want="${2:?main-push-gate: --head needs a value}"; shift 2 ;;
    --changed)      changed_override="${2:?main-push-gate: --changed needs a value}"; shift 2 ;;
    --writer-slug)  writer_slug="${2:?main-push-gate: --writer-slug needs a value}"; shift 2 ;;
    --project-root) project_root_override="${2:?main-push-gate: --project-root needs a value}"; shift 2 ;;
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

# --- resolve --project-root (PRD-build-main-push-gate-nested-project-root) ---
# Same explicit-only handling as extend-gate.sh's own --project-root: no
# auto-detection (that's extend-gate.sh's find_cargo_root, a second source
# of truth this PRD deliberately does not duplicate) — just validate the
# given relative path has a Cargo.toml, fail loud if not (AC4), and use it
# to resolve every last-verdict.json read below. Omitted entirely: verdict_dir
# stays "$repo" and every read is byte-identical to before this flag existed.
verdict_dir="$repo"
project_rel="."
if [ -n "$project_root_override" ]; then
  project_abs="$repo/$project_root_override"
  [ -f "$project_abs/Cargo.toml" ] || die 2 "no Cargo.toml at --project-root $project_root_override (looked in $project_abs)"
  verdict_dir="$project_abs"
  project_rel="$project_root_override"
  echo "main-push-gate: project-root: $project_rel (looked in $project_abs)"
fi

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

# --- gated-repo branch-verdict check (PRD-build-cross-repo-commit-gate ---
# requirement 3, P0): when <repo> is itself registered as some OTHER
# rust-extend PRD's build_into (gated-targets.sh is-gated), "CI green" on
# the delta below is not enough — this push also needs a FRESH branch-gate
# verdict (pass/delta-pass) for the EXACT head about to be pushed, read
# from <repo>/target/autobuilder/last-verdict.json (the same cache file
# worktree-extend.sh's cmd_land's gate_cache_transfer writes onto main
# after a gated land — a routed, gated land already leaves this file
# fresh; an unrouted commit, or any push whose last gate ran at a
# different head, leaves it stale or absent). Missing file, mismatched
# head, or a `block` verdict all refuse — never treated as green by
# omission, same principle as the missing-ci-equivalent.toml case below.
# Checked BEFORE the ci-equivalent delta machinery so a gated repo with no
# fresh verdict is refused before spending any wall time on a cargo run.
gated_targets_sh="$SKILL_DIR/scripts/gated-targets.sh"
if [ -x "$gated_targets_sh" ] && "$gated_targets_sh" is-gated "$repo" >/dev/null 2>&1; then
  branch_verdict_file="$verdict_dir/target/autobuilder/last-verdict.json"
  branch_head="" branch_verdict=""
  if [ -f "$branch_verdict_file" ] && command -v jq >/dev/null 2>&1; then
    branch_head="$(jq -r '.head // .head_sha // empty' "$branch_verdict_file" 2>/dev/null)"
    branch_verdict="$(jq -r '.verdict // empty' "$branch_verdict_file" 2>/dev/null)"
  fi
  writer="${writer_slug:-unknown}"
  case "$branch_verdict" in
    pass|delta-pass) branch_ok=true ;;
    *) branch_ok=false ;;
  esac
  if [ "$branch_head" != "$head_now" ] || ! $branch_ok; then
    blocking="unknown"
    if [ -f "$branch_verdict_file" ] && command -v jq >/dev/null 2>&1; then
      blocking="$(jq -r '((.new_blocks // []) + (.inherited_blocks // [])) | map(select(. != "")) | join(",")' "$branch_verdict_file" 2>/dev/null)"
    fi
    [ -n "$blocking" ] || blocking="unknown"
    [ -z "$branch_head" ] && blocking="no-verdict"
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  cross-repo-gate  refused  (writer=$writer target=$slug blocking=$blocking)"
    die 1 "cross-repo-gate refused: $slug has no fresh pass/delta-pass branch-gate verdict for head ${head_now:0:7} (branch_head=${branch_head:-none} verdict=${branch_verdict:-none})"
  fi
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  cross-repo-gate  pass  (writer=$writer target=$slug)"
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
  verdict_file="$verdict_dir/target/autobuilder/last-verdict.json"
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

# --- push_via_branch=true acceptance (PRD-build-main-push-gate-pr-path ---
# requirement 5, P0, AC7): this repo's push target is `loop/<slug>`, not
# main itself — GitHub's OWN required checks on that PR are the
# CI-equivalent (armed by `branch-protection.sh push`), so there is no
# local command this script could usefully run for a delta, and no delta
# is tolerated: the head about to be pushed must be EXACTLY the head
# extend-gate.sh already gated pass/delta-pass (a branch-scope verdict, in
# the shared-target case — gate-then-land.sh's own pre-land intent-card
# refresh already guarantees this by construction; see that script's
# header). Checked BEFORE the identical-sha short-circuit below (this
# check exits either way, itself) and BEFORE the ci-equivalent.toml delta
# machinery (never reached for such a repo) — a repo with no protection
# recorded, or `push_via_branch: false`, is entirely unaffected (falls
# through unchanged, byte-for-byte, to the direct-push logic below).
if [ "$(push_via_branch_for "$slug")" = "true" ]; then
  pvb_verdict_file="$verdict_dir/target/autobuilder/last-verdict.json"
  pvb_verdict_head="" pvb_verdict=""
  if [ -f "$pvb_verdict_file" ] && command -v jq >/dev/null 2>&1; then
    pvb_verdict_head="$(jq -r '.head // .head_sha // empty' "$pvb_verdict_file" 2>/dev/null)"
    pvb_verdict="$(jq -r '.verdict // empty' "$pvb_verdict_file" 2>/dev/null)"
  fi
  # An explicit --gated always wins over the verdict file's own head (same
  # override precedence as the ordinary --gated resolution above).
  pvb_gated="$gated_now"
  case "$pvb_verdict" in
    pass|delta-pass) pvb_ok=true ;;
    *) pvb_ok=false ;;
  esac
  if [ -n "$pvb_gated" ] && [ "$pvb_gated" = "$head_now" ] && $pvb_ok; then
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  main-push  ok  (repo=$slug via=pr-path gated=$pvb_gated head=$head_now delta=0)"
    echo "main-push-gate: ok via=pr-path — $slug gated==head (${head_now:0:7}), delta=0, PR-path required checks stand in for a local re-run"
    exit 0
  fi
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  main-push  refused  (repo=$slug via=pr-path gated=${pvb_gated:-none} head=$head_now verdict=${pvb_verdict:-none} reason=head-mismatch-or-not-gated)"
  die 4 "main-push refused via=pr-path: no fresh branch-scope pass/delta-pass verdict for head $head_now (verdict_head=${pvb_gated:-none} verdict=${pvb_verdict:-none})"
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

# PRD-build-main-push-gate-pr-path requirement 8 / AC11 (P1): this is the
# ONE place that actually execs the resolved command, so cargo resolution
# belongs here, not just in the pre-push hook that calls this script (the
# hook has no idea whether $resolved_cmd even needs cargo). A bare `ssh
# host git push` commonly runs with a PATH that never sourced the login
# shell's rc file, so `~/.cargo/bin` is missing even though cargo is
# installed there (the exact 2026-09-16 defect: `bash -c "cargo test
# --workspace"` under such a PATH fails rc=127, "cargo: command not
# found", which this script previously let through unexamined as an
# ordinary check failure). Only probed when $resolved_cmd actually
# invokes cargo as a command word — never misfires a non-cargo check.
if [[ "$resolved_cmd" =~ (^|[[:space:]])cargo([[:space:]]|$) ]] && ! command -v cargo >/dev/null 2>&1; then
  cargo_bin="${CARGO:-$HOME/.cargo/bin/cargo}"
  if [ -x "$cargo_bin" ]; then
    path_prefix="$(dirname "$cargo_bin"):$path_prefix"
  else
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $slug  main-push  refused  (repo=$slug gated=${gated_now:0:7} head=${head_now:0:7} delta=$delta_n check=\"$resolved_cmd\" reason=cargo-not-found)"
    die 4 "main-push refused reason=cargo-not-found path=$PATH"
  fi
fi

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
