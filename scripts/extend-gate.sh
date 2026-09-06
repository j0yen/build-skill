#!/usr/bin/env bash
# extend-gate.sh — regenerate autobuilder's 25 receipts at HEAD on a
# rust-extend crate's main checkout, so the deploy gate a rust-extend ship
# reads is never bound to a stale commit. PRD-build-extend-gate-receipts.
#
# usage: extend-gate.sh <build_into> [--base <tag>] [--head <sha>] [--dry-run] [--parallelism N]
#
# On a clean main checkout, at HEAD, in this order:
#   scripts/audit.sh                         (if the crate has one)
#   autobuilder loop --project <root> --iteration 0 --head-sha <HEAD> --trace
#   autobuilder vti-plan
#   autobuilder rollback-plan --base <base>
#   autobuilder reviewer-agent prepare --base <base>, then finalize
#     (the binary cannot spawn its own subagent — see
#     autobuilder/src/reviewer.rs — so this script spawns a headless
#     sonnet review via `claude -p` and feeds its JSON to finalize)
#   autobuilder ci-checks
#   ~/.claude/skills/rustbuild/scripts/extended-receipts.sh <root> [parallelism]
#   autobuilder gate --project <root>
# <root> is normally <build_into> itself, but is resolved to the nearest
# subdirectory containing Cargo.toml when <build_into> has none at its own
# root (see "cargo project root resolution" below).
# <base> defaults to the newest `v<major>.<minor>.<patch>` tag reachable
# from HEAD by first-parent (autobuilder's own rollback-plan convention),
# falling back to the crate's initial commit when no such tag exists.
#
# Prints the gate's own summary line (`gate: head=... pass=N block=M
# verdict=...`) and exits with the gate's verdict.
#
# <build_into> is normally both the git repo root and the Cargo project
# root (mcphost, wm-node, adopt) — but that's not universal. When the repo
# root has no Cargo.toml (rustbuild's has always lived one level down, at
# autobuilder/Cargo.toml), immediate subdirectories are searched (depth 1,
# then depth 2 if depth 1 finds nothing — never descending into target/ or
# .git/) for exactly one Cargo.toml, and THAT resolved path is passed to
# every producer below (including extended-receipts.sh's 17) instead of
# the repo root, so cargo-invoking producers stop exiting 101 for "could
# not find Cargo.toml" against a directory that was never the actual
# crate. A repo with a root Cargo.toml AND a nested one keeps the root,
# unchanged (no search triggered). Ambiguous (>1 candidate) or absent (0
# candidates) fails loudly (exit 6) naming what was searched, before any
# producer runs — never a silent 101. PRD-build-extend-gate-nested-crate-project.
#
# Exit codes:
#   0  gate verdict pass (pass=25 block=0)
#   1  gate verdict block (one or more receipts failed)
#   1  usage error (bad/missing arguments)
#   2  a required binary is missing from $PATH (autobuilder, extended-receipts.sh,
#      ship-tag.sh) — cannot even attempt a run
#   3  dirty tree — refused before any producer ran, nothing under
#      target/autobuilder/ changed
#   4  could not acquire the per-repo integration lock within 120s
#   5  --head <sha> does not match actual HEAD — refused before any
#      producer ran
#   6  could not resolve a unique Cargo project root under <build_into>
#      (none found, or more than one candidate) — refused before any
#      producer ran
#
# Never runs `cargo clean` in the crate's own target/ (determinism and
# cold-build-time already build in their own temp target dirs — memory
# rule: never `cargo clean` a crate with receipts).
#
# Takes the SAME per-repo integration lock `worktree-extend.sh integrate`
# takes (`<repo>/.git/autobuilder-integrate.lock`, `flock`), so two PRDs
# landing on one crate in one tick never run producers concurrently — the
# second run waits, then regenerates receipts at the later HEAD only.
#
# --dry-run prints the producer sequence, the resolved base tag, and HEAD;
# writes nothing under target/autobuilder/; never takes the lock; exits 0.
#
# Individual producer steps are run best-effort: a non-zero exit from any
# one of them (rollback-plan finding a non-revert-clean merge, ci-checks
# finding a red workflow, ...) is logged and the run CONTINUES through the
# rest of the sequence, so every receipt gets regenerated at HEAD and the
# final `autobuilder gate` is the single source of truth for pass/block —
# an early abort would leave the receipt set partial and mislead the next
# tick about which check actually failed. Per requirement 7 (resumable): a
# tick that ends mid-gate leaves a partial receipt set, which is never
# read as green; the next tick reruns this script from the start.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

RUSTBUILD_SCRIPTS="$HOME/.claude/skills/rustbuild/scripts"
REVIEWER_PROMPT="$HOME/.claude/skills/rustbuild/prompts/reviewer-agent.md"

die() { echo "extend-gate: $2" >&2; exit "$1"; }

usage() {
  cat <<'EOF'
usage: extend-gate.sh <build_into> [--base <tag>] [--head <sha>] [--dry-run] [--parallelism N]
EOF
}

producers_desc() {
  cat <<'EOF'
scripts/audit.sh (if present)
autobuilder loop --project <root> --iteration 0 --head-sha <HEAD> --trace
autobuilder vti-plan
autobuilder rollback-plan --base <base>
autobuilder reviewer-agent prepare --base <base> ; claude -p (headless sonnet review) ; autobuilder reviewer-agent finalize
autobuilder ci-checks
extended-receipts.sh <root> [parallelism]  (17 extended producers)
autobuilder gate --project <root>
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac
repo_arg="$1"; shift

base_override=""
head_want=""
dry_run=false
parallelism=6

while [ $# -gt 0 ]; do
  case "$1" in
    --base)        base_override="${2:?extend-gate: --base needs a value}"; shift 2 ;;
    --head)        head_want="${2:?extend-gate: --head needs a value}"; shift 2 ;;
    --dry-run)     dry_run=true; shift ;;
    --parallelism) parallelism="${2:?extend-gate: --parallelism needs a value}"; shift 2 ;;
    *) die 1 "unknown argument: $1 (see --help)" ;;
  esac
done

repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 1 "no such directory: $repo_arg"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 1 "not a git repo: $repo"
command -v autobuilder >/dev/null 2>&1 || die 2 "autobuilder not on \$PATH (cargo install --path ~/wintermute/rustbuild/autobuilder --locked)"
[ -x "$RUSTBUILD_SCRIPTS/extended-receipts.sh" ] || die 2 "missing $RUSTBUILD_SCRIPTS/extended-receipts.sh"
[ -x "$RUSTBUILD_SCRIPTS/ship-tag.sh" ] || die 2 "missing $RUSTBUILD_SCRIPTS/ship-tag.sh"

# --- cargo project root resolution (PRD-build-extend-gate-nested-crate-project) ---
# $repo itself wins immediately if it has a Cargo.toml (the common case,
# and the edge case of a repo with both a root AND a nested Cargo.toml —
# root wins, no search performed at all, so byte-identical behavior for
# every already-onboarded crate). Otherwise search one level down, then
# two, for exactly one Cargo.toml, skipping target/ and .git/ at every
# level. Prints the resolved path on success; prints a human-readable
# reason (ambiguous / absent, naming what was searched) on failure.
find_cargo_root() {
  local base="$1"
  if [ -f "$base/Cargo.toml" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  local d b
  local -a d1=()
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    case "$b" in target|.git) continue ;; esac
    [ -f "$d/Cargo.toml" ] && d1+=("${d%/}")
  done
  if [ "${#d1[@]}" -eq 1 ]; then
    printf '%s\n' "${d1[0]}"
    return 0
  elif [ "${#d1[@]}" -gt 1 ]; then
    printf 'ambiguous — multiple Cargo.toml found one level under %s: %s' "$base" "${d1[*]}"
    return 1
  fi
  local d1dir b1 d2dir b2
  local -a d2=()
  for d1dir in "$base"/*/; do
    [ -d "$d1dir" ] || continue
    b1="$(basename "$d1dir")"
    case "$b1" in target|.git) continue ;; esac
    for d2dir in "$d1dir"*/; do
      [ -d "$d2dir" ] || continue
      b2="$(basename "$d2dir")"
      case "$b2" in target|.git) continue ;; esac
      [ -f "$d2dir/Cargo.toml" ] && d2+=("${d2dir%/}")
    done
  done
  if [ "${#d2[@]}" -eq 1 ]; then
    printf '%s\n' "${d2[0]}"
    return 0
  elif [ "${#d2[@]}" -gt 1 ]; then
    printf 'ambiguous — multiple Cargo.toml found two levels under %s: %s' "$base" "${d2[*]}"
    return 1
  fi
  printf 'no Cargo.toml found at %s, in its immediate subdirectories, or two levels down (searched depth-1 and depth-2, excluding target/ and .git/)' "$base"
  return 1
}

project_abs="$(find_cargo_root "$repo")" || die 6 "$project_abs"
project_rel="$(realpath --relative-to="$repo" "$project_abs")"

# --- base resolution ---------------------------------------------------
# Mirrors autobuilder rollback-plan's own default exactly (see
# autobuilder/src/rollback.rs newest_reachable_tag/resolve_default_base):
# walk first-parent history from HEAD backward, take the newest
# v<major>.<minor>.<patch> tag found; else the crate's initial commit.
# Computed here (not just left to rollback-plan's own default) so
# --dry-run can report it without running any producer, and so
# reviewer-agent prepare reviews the SAME range rollback-plan checks
# (user story 5: <last-tag>..HEAD, not a branch that no longer exists).
newest_reachable_tag() {
  local sha tags best
  while read -r sha; do
    [ -n "$sha" ] || continue
    tags="$(git -C "$repo" tag --points-at "$sha" 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    [ -n "$tags" ] || continue
    best="$(printf '%s\n' $tags | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    printf 'v%s\n' "$best"
    return 0
  done < <(git -C "$repo" rev-list --first-parent HEAD 2>/dev/null)
  return 1
}

resolve_base() {
  if [ -n "$base_override" ]; then
    printf '%s\n' "$base_override"
    return 0
  fi
  local t
  if t="$(newest_reachable_tag)"; then
    printf '%s\n' "$t"
    return 0
  fi
  git -C "$repo" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1
}

head_now="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
base_ref="$(resolve_base)"

if $dry_run; then
  echo "extend-gate: dry-run for $repo"
  if [ "$project_rel" = "." ]; then
    echo "  project-root: . (repo root)"
  else
    echo "  project-root: $project_rel (resolved from repo root)"
  fi
  echo "  HEAD: $head_now"
  echo "  base: $base_ref"
  echo "  parallelism: $parallelism"
  echo "  producers, in order:"
  producers_desc | sed 's/^/    - /'
  exit 0
fi

# --- per-repo integration lock ------------------------------------------
# Same lock file/convention as `worktree-extend.sh integrate`
# (<repo>/.git/autobuilder-integrate.lock via flock), so a gate run and an
# integrate on the same crate — or two gate runs — never overlap.
#
# PRD-extend-gate-lock-cloexec (2026-09-05 incident class): every producer
# subshell below closes fd 9 (`9>&-`) before exec'ing its child. Without
# this, a child that outlives the script — cargo autostarting the
# long-lived sccache daemon, or mcphost's bwrap warm-pool sandboxes leaking
# past `cargo test` — inherits fd 9 and keeps the lock held after this
# script exits, timing out the NEXT gate run (exit 4, 120s wait) even
# though the process that opened the lock is long gone. Do not remove the
# `9>&-` from a producer invocation without re-reading this comment.
exec 9>"$repo/.git/autobuilder-integrate.lock"
flock -w 120 9 || die 4 "could not acquire integration lock for $repo (another integrate/gate is running)"

# --- refuse a dirty tree before any producer runs (AC2) ------------------
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
  die 3 "refusing — working tree at $repo is dirty"
fi

# --- refuse a --head that doesn't match actual HEAD, before any producer
#     runs (AC3) --------------------------------------------------------
if [ -n "$head_want" ] && [ "$head_want" != "$head_now" ]; then
  die 5 "refusing — HEAD is $head_now, --head asked for $head_want"
fi

t0=$(date +%s)
blocking_notes=()
note_block() { blocking_notes+=("$1"); echo "extend-gate: $1" >&2; }

echo "extend-gate: $repo head=$head_now base=$base_ref parallelism=$parallelism"
if [ "$project_rel" = "." ]; then
  echo "extend-gate: project-root: . (repo root)"
else
  echo "extend-gate: project-root: $project_rel (resolved from repo root)"
fi

# 1. audit.sh, when the crate has one. Feeds the risk-gate receipt; a
#    non-zero exit here is logged but does not abort the run — the final
#    `autobuilder gate` is authoritative (see file header).
if [ -x "$repo/scripts/audit.sh" ]; then
  ( cd "$repo" && ./scripts/audit.sh ) 9>&- || note_block "risk-gate — scripts/audit.sh exited non-zero (see risk-gate receipt for detail)"
else
  echo "extend-gate: no scripts/audit.sh in $repo — skipping"
fi

# 2. proof receipt + session trace.
( cd "$repo" && autobuilder loop --project "$project_rel" --iteration 0 --head-sha "$head_now" --trace ) 9>&- \
  || note_block "proof-receipt — autobuilder loop --iteration 0 exited non-zero"

# 3. vti-plan.
( cd "$repo" && autobuilder vti-plan --project "$project_rel" --base "$base_ref" ) 9>&- \
  || note_block "vti-plan — autobuilder vti-plan exited non-zero"

# 4. rollback-plan over <base>..HEAD.
( cd "$repo" && autobuilder rollback-plan --project "$project_rel" --base "$base_ref" ) 9>&- \
  || note_block "rollback-plan — commits since $base_ref are not all revert-clean (see target/autobuilder/rollback.md); fix forward, or a human rewrites history and says so — this script never edits history to force a pass"

# 5. reviewer-agent: prepare, spawn the independent review headlessly via
#    `claude -p --model sonnet` (same tier /rustbuild routes it to; the
#    autobuilder binary cannot spawn a Claude subagent itself), finalize.
run_reviewer() {
  ( cd "$repo" && autobuilder reviewer-agent prepare --project "$project_rel" --base "$base_ref" ) 9>&- \
    || { note_block "reviewer-agent — prepare exited non-zero"; return 1; }
  local req="$project_abs/target/autobuilder/review-request.json"
  [ -f "$req" ] || { note_block "reviewer-agent — prepare did not write $req"; return 1; }
  command -v claude >/dev/null 2>&1 \
    || { note_block "reviewer-agent — claude CLI not on \$PATH (needed to spawn the independent review subagent)"; return 1; }
  [ -f "$REVIEWER_PROMPT" ] \
    || { note_block "reviewer-agent — missing prompt $REVIEWER_PROMPT"; return 1; }

  local out="$project_abs/target/autobuilder/review-output.json"
  local raw="$project_abs/target/autobuilder/review-output.raw.txt"
  local prompt
  prompt="$(cat "$REVIEWER_PROMPT")
---
Below is this review's target/autobuilder/review-request.json. The repo is
checked out at HEAD $head_now at $repo — read whatever you need under it.
$(cat "$req")
---
Reply with ONLY one JSON object, no prose, no markdown fences, matching
schema autobuilder.reviewer_agent_receipt.v1:
{\"schema\":\"autobuilder.reviewer_agent_receipt.v1\",\"head_sha\":\"...\",\"intent_card_sha\":\"...\",\"decision\":\"pass|concern|block\",\"block_reasons\":[...],\"concern_reasons\":[{\"id\":\"...\",\"note\":\"...\"}],\"falsification\":{\"test_audit\":\"...\",\"panic_audit\":\"...\",\"unsafe_audit\":\"...\",\"public_api_audit\":\"...\",\"deps_audit\":\"...\",\"drift_audit\":\"...\",\"counter_attack\":{\"description\":\"...\",\"test_skeleton\":\"...\"}}}"

  if ! ( cd "$repo" && claude -p "$prompt" --model sonnet --permission-mode bypassPermissions --output-format text ) 9>&- >"$raw" 2>"$raw.err"; then
    note_block "reviewer-agent — claude -p subagent invocation failed (see $raw.err)"
    return 1
  fi
  if ! python3 -c "
import json, re, sys
raw = open('$raw').read()
m = re.search(r'\{.*\}', raw, re.S)
if not m:
    sys.exit(1)
obj = json.loads(m.group(0))
json.dump(obj, open('$out', 'w'))
" 2>>"$raw.err"; then
    note_block "reviewer-agent — subagent did not return valid JSON (see $raw)"
    return 1
  fi
  ( cd "$repo" && autobuilder reviewer-agent finalize --project "$project_rel" --input "$out" ) 9>&- \
    || { note_block "reviewer-agent — finalize rejected the subagent's output"; return 1; }
}
run_reviewer || true

# 6. ci-checks — needs `gh` authenticated against the pushed HEAD.
if ! command -v gh >/dev/null 2>&1; then
  note_block "ci-checks — gh CLI not on \$PATH (install: https://cli.github.com)"
elif ! gh auth status >/dev/null 2>&1; then
  note_block "ci-checks — gh not authenticated: run 'gh auth login'"
else
  ( cd "$repo" && autobuilder ci-checks --project "$project_rel" ) 9>&- \
    || note_block "ci-checks — workflow(s) on HEAD are not green, or still pending (the next tick retries)"
fi

# 7. the 17 extended-gates producers, in parallel. Passed the RESOLVED
# project path (not $repo) so their receipts land in the same
# target/autobuilder/receipts/ the rest of this script's producers and
# the final `autobuilder gate` read from.
# subshell wraps the direct exec so 9>&- has a scope to apply to — this
# call is not otherwise inside a `( ... )` group.
( "$RUSTBUILD_SCRIPTS/extended-receipts.sh" "$project_abs" "$parallelism" ) 9>&- \
  || note_block "extended-receipts — one or more extended producers did not pass|skip (see output above)"

# 8. the risk gate itself — authoritative pass/block, reads all 25 receipts.
gate_out="$(exec 9>&-; cd "$repo" && autobuilder gate --project "$project_rel" 2>&1)"
gate_rc=$?
printf '%s\n' "$gate_out"
summary="$(printf '%s\n' "$gate_out" | grep -m1 '^gate: ' || true)"

wall=$(( $(date +%s) - t0 ))
crate_name="$(basename "$repo")"
outcome="pass"; [ "$gate_rc" -eq 0 ] || outcome="block"
blockers_csv=""
if [ "${#blocking_notes[@]}" -gt 0 ]; then
  blockers_csv="$(IFS='|'; echo "${blocking_notes[*]}")"
fi

# One journal line per gate run (requirement 8 / AC13): crate, HEAD, base
# tag, pass/block counts, blocking receipt names, wall seconds.
journal="$HOME/brain/journal/build/$(date -u +%Y-%m-%d).md"
mkdir -p "$(dirname "$journal")"
printf '%s  gate  %s  %s  (head=%s base=%s %s blocking=%s wall=%ss)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$crate_name" "$outcome" "$head_now" "$base_ref" \
  "${summary:-gate: no-summary-line}" "${blockers_csv:-none}" "$wall" >>"$journal"

exit "$gate_rc"
