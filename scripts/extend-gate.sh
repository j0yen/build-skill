#!/usr/bin/env bash
# extend-gate.sh — regenerate autobuilder's 25 receipts at HEAD on a
# rust-extend crate's main checkout, so the deploy gate a rust-extend ship
# reads is never bound to a stale commit. PRD-build-extend-gate-receipts.
#
# usage: extend-gate.sh <build_into> [--base <tag>] [--head <sha>] [--dry-run]
#                        [--parallelism N] [--record-baseline] [--force]
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
# Delta verdict against a committed baseline (PRD-build-gate-delta-baseline).
# `autobuilder gate`'s own pass/block is not the final word: this script
# additionally diffs the blocking receipt set against
# `<build_into>/agent/gate-baseline.json` AT HEAD (a working-tree-only copy
# never counts — fail closed) via `scripts/gate-delta.sh verdict`, and
# prints its own summary line:
#   extend-gate: delta verdict=pass|delta-pass|block baseline=present|absent new_blocks=<...> inherited_blocks=<...>
# `delta-pass` means block>0 but every blocking receipt name is already in
# the baseline — this script then exits 0 (shippable), same as a plain
# `pass`. `block` means at least one blocking receipt is NOT in the
# baseline (or there is no committed baseline at all — today's behavior,
# preserved byte-for-byte: no baseline means this new summary line and the
# exit code are unaffected by anything above). `--record-baseline` writes
# the baseline from the CURRENT run's blocking set instead of computing a
# verdict against one — see that flag's own note below. A verdict run
# never writes or widens the baseline itself.
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
#   0  gate verdict pass (pass=25 block=0) OR delta-pass (block>0 but every
#      blocking receipt is in the committed baseline) OR a successful
#      `--record-baseline` write (that mode's exit code reports the write,
#      not the underlying pass/block)
#   1  gate verdict block (one or more receipts failed, and at least one
#      of them is not in the committed baseline — or there is no committed
#      baseline at all)
#   1  usage error (bad/missing arguments)
#   2  a required binary is missing from $PATH (autobuilder, extended-receipts.sh,
#      ship-tag.sh, gate-delta.sh, jq) — cannot even attempt a run
#   3  dirty tree — refused before any producer ran, nothing under
#      target/autobuilder/ changed
#   4  could not acquire the per-repo integration lock within 120s
#   5  --head <sha> does not match actual HEAD — refused before any
#      producer ran
#   6  could not resolve a unique Cargo project root under <build_into>
#      (none found, or more than one candidate) — refused before any
#      producer ran
#
# --record-baseline: runs the full producer sequence exactly as a normal
# invocation, then instead of computing a delta verdict, writes
# `<build_into>/agent/gate-baseline.json` from THIS run's blocking receipt
# set (`scripts/gate-delta.sh record`) and prints the recorded document.
# Meant to be committed by the caller (a human, or an explicit gate-debt
# PRD) — this script never commits, and a plain verdict run never widens
# or auto-records a baseline on its own. Bypasses the verdict cache below
# (a recording always reflects a fresh run). Exits 0 on a successful
# write regardless of the underlying pass/block count.
#
# Verdict cache: on a successful (non-dry-run, non-record-baseline) run,
# the computed verdict is cached at
# `<project>/target/autobuilder/last-verdict.json` keyed on (HEAD sha,
# this script's own sha256). A later invocation at the SAME head with an
# UNCHANGED script replays the cached verdict (`extend-gate: verdict=...
# (cached)`, same exit code) instead of regenerating all 25 receipts.
# `--force` bypasses the cache and always runs the full sequence.
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

# Overridable so tests/ can point at a fixture dir of fake binaries
# without touching production behavior (default unchanged).
RUSTBUILD_SCRIPTS="${RUSTBUILD_SCRIPTS:-$HOME/.claude/skills/rustbuild/scripts}"
REVIEWER_PROMPT="${REVIEWER_PROMPT:-$HOME/.claude/skills/rustbuild/prompts/reviewer-agent.md}"
BUILD_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
GATE_DELTA="$BUILD_SCRIPTS/gate-delta.sh"

die() { echo "extend-gate: $2" >&2; exit "$1"; }

usage() {
  cat <<'EOF'
usage: extend-gate.sh <build_into> [--base <tag>] [--head <sha>] [--dry-run]
                       [--parallelism N] [--record-baseline] [--force]
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
record_baseline=false
force=false

while [ $# -gt 0 ]; do
  case "$1" in
    --base)             base_override="${2:?extend-gate: --base needs a value}"; shift 2 ;;
    --head)             head_want="${2:?extend-gate: --head needs a value}"; shift 2 ;;
    --dry-run)          dry_run=true; shift ;;
    --parallelism)      parallelism="${2:?extend-gate: --parallelism needs a value}"; shift 2 ;;
    --record-baseline)  record_baseline=true; shift ;;
    --force)            force=true; shift ;;
    *) die 1 "unknown argument: $1 (see --help)" ;;
  esac
done

repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 1 "no such directory: $repo_arg"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 1 "not a git repo: $repo"
command -v autobuilder >/dev/null 2>&1 || die 2 "autobuilder not on \$PATH (cargo install --path ~/wintermute/rustbuild/autobuilder --locked)"
[ -x "$RUSTBUILD_SCRIPTS/extended-receipts.sh" ] || die 2 "missing $RUSTBUILD_SCRIPTS/extended-receipts.sh"
[ -x "$RUSTBUILD_SCRIPTS/ship-tag.sh" ] || die 2 "missing $RUSTBUILD_SCRIPTS/ship-tag.sh"
[ -x "$GATE_DELTA" ] || die 2 "missing $GATE_DELTA"
command -v jq >/dev/null 2>&1 || die 2 "jq not on \$PATH (needed by gate-delta.sh)"

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

# --- verdict cache (PRD-build-gate-delta-baseline P1) --------------------
# Keyed on (HEAD sha, this script's own sha256) so an edit to extend-gate.sh
# itself (a new producer, a bugfix) always invalidates a stale cached
# verdict even at an unchanged HEAD. `--record-baseline` always runs the
# full sequence (a recording must reflect a fresh run, never a cache);
# `--force` always bypasses the cache. A cache hit never regenerates
# receipts and never re-takes the integration lock's expensive path —
# checked here, after the (cheap) dirty-tree/head-mismatch refusals above,
# so those refusals still apply to a would-be cache hit exactly as they do
# to a full run.
self_hash="$(sha256sum "$0" 2>/dev/null | awk '{print $1}')"
cache_file="$project_abs/target/autobuilder/last-verdict.json"
if ! $record_baseline && ! $force && [ -f "$cache_file" ]; then
  cached_head="$(jq -r '.head_sha // empty' "$cache_file" 2>/dev/null || true)"
  cached_hash="$(jq -r '.script_sha256 // empty' "$cache_file" 2>/dev/null || true)"
  if [ -n "$cached_head" ] && [ "$cached_head" = "$head_now" ] && [ -n "$cached_hash" ] && [ "$cached_hash" = "$self_hash" ]; then
    cached_verdict="$(jq -r '.verdict // empty' "$cache_file" 2>/dev/null || true)"
    cached_rc="$(jq -r '.exit_code // empty' "$cache_file" 2>/dev/null || true)"
    if [ -n "$cached_verdict" ] && [ -n "$cached_rc" ]; then
      echo "extend-gate: verdict=$cached_verdict (cached)"
      exit "$cached_rc"
    fi
  fi
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
blockers_csv=""
if [ "${#blocking_notes[@]}" -gt 0 ]; then
  blockers_csv="$(IFS='|'; echo "${blocking_notes[*]}")"
fi
# Overridable so tests/ never writes into the real journal (default unchanged).
journal="${EXTEND_GATE_JOURNAL:-$HOME/brain/journal/build/$(date -u +%Y-%m-%d).md}"
mkdir -p "$(dirname "$journal")"

# --- record-baseline: write agent/gate-baseline.json from THIS run's
# blocking set, print it, done. Never computes or acts on a delta verdict
# — recording and shipping are separate, deliberate acts (design note:
# "the gate never auto-widens a baseline"). ---------------------------
gate_out_file="$(mktemp "${TMPDIR:-/tmp}/extend-gate-out.XXXXXX")"
printf '%s\n' "$gate_out" > "$gate_out_file"

if $record_baseline; then
  recorded="$("$GATE_DELTA" record "$repo" "$gate_out_file")" || { rm -f "$gate_out_file"; die 2 "gate-delta.sh record failed"; }
  rm -f "$gate_out_file"
  echo "extend-gate: recorded baseline to $repo/agent/gate-baseline.json"
  printf '%s\n' "$recorded"
  printf '%s  gate  %s  record-baseline  (head=%s base=%s %s wall=%ss)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$crate_name" "$head_now" "$base_ref" \
    "${summary:-gate: no-summary-line}" "$wall" >>"$journal"
  exit 0
fi

# --- delta verdict against the committed baseline (PRD-build-gate-delta-baseline) ---
# `gate-delta.sh verdict`'s own exit code already mirrors <gate_rc>
# byte-for-byte whenever there is no committed baseline (see that
# script's header) — using it unconditionally as this script's final
# exit code is what makes the absent-baseline path identical to the
# pre-this-PRD behavior. Only the PRESENT-baseline path prints or
# journals anything new.
delta_out="$("$GATE_DELTA" verdict "$repo" "$gate_out_file" "$gate_rc")"
delta_rc=$?
rm -f "$gate_out_file"
baseline_state="$(printf '%s\n' "$delta_out" | sed -n 's/^baseline=//p')"
delta_verdict="$(printf '%s\n' "$delta_out" | sed -n 's/^verdict=//p')"
new_blocks="$(printf '%s\n' "$delta_out" | sed -n 's/^new_blocks=//p')"
inherited_blocks="$(printf '%s\n' "$delta_out" | sed -n 's/^inherited_blocks=//p')"

final_rc="$delta_rc"
outcome="pass"; [ "$gate_rc" -eq 0 ] || outcome="block"
journal_suffix=""
if [ "$baseline_state" = "present" ]; then
  echo "extend-gate: delta verdict=$delta_verdict baseline=present new_blocks=${new_blocks:-none} inherited_blocks=${inherited_blocks:-none}"
  outcome="$delta_verdict"
  journal_suffix=" verdict=$delta_verdict inherited_blocks=[${inherited_blocks}]"
fi

# One journal line per gate run (requirement 8 / AC13): crate, HEAD, base
# tag, pass/block counts, blocking receipt names, wall seconds. Absent a
# committed baseline, journal_suffix is empty and this line is
# byte-for-byte what it was before this PRD (AC4).
printf '%s  gate  %s  %s  (head=%s base=%s %s blocking=%s wall=%ss)%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$crate_name" "$outcome" "$head_now" "$base_ref" \
  "${summary:-gate: no-summary-line}" "${blockers_csv:-none}" "$wall" "$journal_suffix" >>"$journal"

# --- write the verdict cache (P1) — every full run, pass/delta-pass/block
# alike, so a repeat invocation at the same head + same script replays
# instead of regenerating. ------------------------------------------------
cache_verdict_val="$outcome"
mkdir -p "$(dirname "$cache_file")"
jq -n --arg head "$head_now" --arg hash "$self_hash" --arg verdict "$cache_verdict_val" \
     --argjson rc "$final_rc" --arg new "$new_blocks" --arg inh "$inherited_blocks" '
  {
    head_sha: $head,
    script_sha256: $hash,
    verdict: $verdict,
    exit_code: $rc,
    new_blocks: ($new | if . == "" then [] else split(",") end),
    inherited_blocks: ($inh | if . == "" then [] else split(",") end)
  }
' > "$cache_file" 2>/dev/null || true

exit "$final_rc"
