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
# this step's ledger (R5), the pre-gate rebase wiring (R1), and the
# bounded coder resolve for true source conflicts (R4, below) are landed;
# wiring this into worktree-extend.sh's integrate (R8) is a later step.
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
#   land-resolve.sh resolve <repo> [slug]
#       Requires <repo> to be a worktree mid-rebase with conflicts
#       (`git diff --name-only --diff-filter=U` non-empty) — R3. For each
#       conflicted path: `generated` -> take main's side, run its regen
#       command, `git add`; `append_only` -> three-way union merge via
#       `git merge-file --union`, `git add`; anything else -> collected as
#       a source conflict.
#
#       R4 (bounded coder resolve): if any source conflicts remain AND
#       `$LAND_RESOLVE_CODER` names an executable, ONE bounded attempt runs
#       before giving up — see `try_coder_resolve()` below. Unset/missing
#       `$LAND_RESOLVE_CODER` (the default — nothing sets it in a plain
#       `classify`/`resolve` call or in a test that doesn't opt in) skips
#       this entirely and falls straight to the pre-R4 behavior: source
#       conflicts are left untouched, conflict markers still in the
#       working tree. This keeps `resolve` side-effect-free by default —
#       no test or caller accidentally spawns a real coder subagent.
#
#       If zero source conflicts remain (either none existed, or R4's
#       coder resolved what did), finishes whichever git operation <repo>
#       is actually mid-way through (git_conflict_continue, R8: a real
#       `git rebase --continue`, or — worktree-extend.sh's cmd_land can
#       hit this same conflict as a plain `git merge` directly against
#       the target repo, not a worktree rebase — a `git commit` instead,
#       since no rebase is in progress there) and prints `resolved=all`,
#       exit 0. If source conflicts remain after a coder
#       attempt (or none was attempted), the rebase is left open (NOT
#       continued), prints `source_conflicts=<comma-list>` — with a
#       trailing ` coder=unresolved` when R4's attempt ran and failed, so
#       a caller can distinguish "gave up, no attempt made" (AC6) from
#       "tried the bounded resolve, it didn't pan out" (AC5) — exit 1.
#       Prints `no-conflict` and exits 3 if <repo> has no conflicted paths
#       at all (nothing to resolve — a caller bug, not a land-resolve
#       failure). Every path this script itself resolves without
#       escalating (`generated`->regen, `append_only`->union, or
#       `source`->coder, never a left-as-source file) appends one record
#       to the ledger (R5) — see below.
#
# Ledger (R5): state/land-conflicts.jsonl, one JSON record per resolved
# FILE (not per resolve() call — a single conflicted rebase touching two
# files yields two records), append-only, one line per `jq -c` object:
#   {"ts": "<ISO-8601>", "repo": "<basename>", "slug": "<slug>",
#    "file": "<repo-relative path>", "class": "generated"|"append_only",
#    "resolution": "regen"|"union", "wall_seconds": <int>}
# This script writes every class/resolution pair it can attest to
# directly: `generated`/regen and `append_only`/union always; `source`/
# `coder` (R4 succeeded, verified by the repo's own tests) and `source`/
# `unresolved` (R4 attempted and failed, or timed out) whenever
# `$LAND_RESOLVE_CODER` is set and the resolve loop reaches that file.
# `wall_seconds` is elapsed time since this `resolve` call (or, for a
# coder attempt, since the coder was invoked) started — regen/union are
# near-instant in practice; a coder attempt's wall_seconds is the more
# useful number there and the ledger's purpose is trend visibility (R5's
# "operator can see which files conflict and how often"), not a profiler.
# `scripts/land-conflicts-report.sh` reads this file and prints conflicts
# by frequency.
#
# R4 (bounded coder resolve) — env vars:
#   LAND_RESOLVE_CODER   Path to an executable invoked as
#                         `<coder> <repo> <slug> <file...>` against the
#                         mid-rebase worktree with those files still
#                         showing conflict markers. Expected to resolve
#                         the markers in place and exit 0 when it believes
#                         it has (a non-zero exit or a timeout is treated
#                         as a failed attempt, no test run). Unset (the
#                         default) -> R4 never runs; matches the pre-R4
#                         contract exactly (AC6). A real deployment points
#                         this at a small wrapper around `claude -p ...
#                         --model sonnet` (extend-gate.sh's reviewer-agent
#                         phase uses the same invocation shape); a
#                         selftest points it at a fixture stub.
#   LAND_RESOLVE_MAX_S   Wall-clock bound on the coder invocation, seconds
#                         (default 900 — R4's stated default). Enforced
#                         via `timeout`; exceeding it counts as a failed
#                         attempt (ledger resolution=unresolved), same as
#                         the coder exiting non-zero.
#   LAND_RESOLVE_TEST_CMD The check the coder's claim is verified against,
#                         run from $repo (default: `cargo test --workspace`
#                         when Cargo.toml is present, else
#                         `scripts/run-selftests.sh` when executable, else
#                         `pytest -q` when pyproject.toml is present, else
#                         empty). An empty/unresolvable test command means
#                         a coder's resolution can never be trusted here —
#                         fails closed (resolution=unresolved) rather than
#                         landing an unverified conflict resolution.
# R4 never trusts the coder's own exit code as the verdict — "tests pass"
# (R4's own words: "with the crate's tests as the check") is the only
# thing that turns an attempt into `source`/`coder` instead of
# `source`/`unresolved`. A coder that resolves conflicts but leaves the
# test command failing is recorded exactly like one that gave up outright.
#
#       Stage semantics (confirmed empirically, not just per git's docs,
#       because `git rebase` INVERTS ours/theirs vs a normal merge): during
#       a rebase conflict, index stage 2 (`--ours`) is the branch being
#       rebased ONTO (main/default) and stage 3 (`--theirs`) is the
#       branch's own commit being replayed. R3's prose says "generated ->
#       checkout theirs (main)" in the plain-English sense of "the other
#       branch's tree" — this script implements that as git's literal
#       `--ours` flag / index stage 2, which is actually main's content
#       during a rebase. Get this backwards and a generated-file "fix"
#       regenerates from the BRANCH's stale baseline instead of main's,
#       silently reintroducing exactly the kind of drift this PRD exists
#       to stop.
#
# Exit: 0 ok | 1 source conflicts remain (resolve only) | 2 usage error |
#       3 nothing to resolve (resolve only, no conflicted paths).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/repo-slug.sh
source "$HERE/lib/repo-slug.sh"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
LAND_POLICY_DIR="${LAND_POLICY_DIR:-$STATE_DIR/land-policy}"
LAND_CONFLICTS_LEDGER="${LAND_CONFLICTS_LEDGER:-$STATE_DIR/land-conflicts.jsonl}"
# R4 — see the header comment above for the full contract. Unset
# LAND_RESOLVE_CODER (the default) means R4 never runs.
LAND_RESOLVE_MAX_S="${LAND_RESOLVE_MAX_S:-900}"
# R8: identity used for the `git commit` that finishes a resolved MERGE
# conflict (git_conflict_continue below) — a rebase's `--continue` needs
# no identity of its own (it replays the branch's existing commits), but
# a merge's finishing commit is a new commit. Same literal identity every
# other script here uses (gate-then-land.sh's GIT_ID, worktree-extend.sh's
# GIT_ID) — a plain array, like theirs, not env-overridable (bash arrays
# don't cross a subprocess boundary; a test that needs a different author
# would set repo-local git config instead).
LAND_RESOLVE_GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

usage() {
  echo "usage: land-resolve.sh policy-path <repo>" >&2
  echo "       land-resolve.sh classify <repo> <path> [slug]" >&2
  echo "       land-resolve.sh resolve <repo> [slug]" >&2
  exit 2
}

# ledger_record <repo> <slug> <file> <class> <resolution> <wall_seconds>
# Appends one JSON line to $LAND_CONFLICTS_LEDGER (R5). Never fails the
# caller — a ledger write is telemetry, not a land precondition; a failure
# to `mkdir`/append is logged to stderr and swallowed.
ledger_record() {
  local repo="$1" slug="$2" file="$3" class="$4" resolution="$5" wall="$6"
  if ! command -v jq >/dev/null 2>&1; then
    echo "land-resolve: jq unavailable — skipping ledger record for $file" >&2
    return 0
  fi
  mkdir -p "$(dirname "$LAND_CONFLICTS_LEDGER")" 2>/dev/null || {
    echo "land-resolve: cannot create $(dirname "$LAND_CONFLICTS_LEDGER") — skipping ledger record for $file" >&2
    return 0
  }
  local line
  # Same LAND_RESOLVE_POLICY_BASENAME override policy_path_for() uses (see
  # its comment) — a worktree-invoked resolve should log the real target
  # repo's name, not the worktree directory's own `<repo>-<slug>` name.
  local repo_field="${LAND_RESOLVE_POLICY_BASENAME:-$(repo_slug_for_ci "$repo")}"
  line="$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repo "$repo_field" \
    --arg slug "$slug" \
    --arg file "$file" \
    --arg class "$class" \
    --arg resolution "$resolution" \
    --argjson wall "${wall:-0}" \
    '{ts: $ts, repo: $repo, slug: $slug, file: $file, class: $class, resolution: $resolution, wall_seconds: $wall}')" \
    || { echo "land-resolve: jq failed building ledger record for $file" >&2; return 0; }
  printf '%s\n' "$line" >>"$LAND_CONFLICTS_LEDGER" 2>/dev/null \
    || echo "land-resolve: append to $LAND_CONFLICTS_LEDGER failed for $file" >&2
}

policy_path_for() {
  local repo="$1"
  # LAND_RESOLVE_POLICY_BASENAME (P0 fix, found by
  # landres_ac1_pregate_rebase_resolves_generated.sh): a caller invoking
  # `resolve` against a worktree-extend.sh worktree (e.g. gate-then-land.sh's
  # rebase_onto_main(), R1) passes $wt as <repo> so git operations land on
  # the right checkout — but `basename $wt` is the WORKTREE's own directory
  # name (`<target-repo>-<slug>`, worktree-extend.sh's own convention),
  # never the target repo's own basename the policy file is keyed on. Left
  # unfixed, every real caller silently misses its policy and every
  # conflict falls through to `source` — R1's whole point defeated with no
  # error, just quietly worse classification. Defaults to `basename $repo`
  # (unchanged behavior) when unset, so every existing direct-repo caller
  # (classify/resolve invoked on a real repo, not a worktree) is unaffected.
  local base="${LAND_RESOLVE_POLICY_BASENAME:-$(repo_slug_for_ci "$repo")}"
  echo "$LAND_POLICY_DIR/$base.json"
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

# test_cmd_for <repo> — prints the check R4 verifies a coder resolution
# against (see LAND_RESOLVE_TEST_CMD in the header comment), empty if none
# can be inferred. Never fails.
test_cmd_for() {
  local repo="$1"
  if [ -n "${LAND_RESOLVE_TEST_CMD:-}" ]; then
    printf '%s\n' "$LAND_RESOLVE_TEST_CMD"
  elif [ -f "$repo/Cargo.toml" ]; then
    printf '%s\n' "cargo test --workspace"
  elif [ -x "$repo/scripts/run-selftests.sh" ]; then
    printf '%s\n' "scripts/run-selftests.sh"
  elif [ -f "$repo/pyproject.toml" ]; then
    printf '%s\n' "pytest -q"
  fi
}

# try_coder_resolve <repo> <slug> <file...> — R4's one bounded attempt.
# Returns 0 and stages every file (plus a ledger `source`/`coder` record
# each) only when the coder invocation exits 0 within
# $LAND_RESOLVE_MAX_S AND the repo's test command (test_cmd_for) then
# passes. Any other outcome (coder failure, timeout, no test command
# available, test command fails) returns 1, leaves the files' conflict
# markers exactly as the coder left them (the caller aborts the whole
# rebase on a non-zero return — see cmd_resolve below — which discards
# whatever the coder touched, restoring the pre-attempt state), and
# records one `source`/`unresolved` ledger entry per file.
try_coder_resolve() {
  local repo="$1" slug="$2"; shift 2
  local -a files=("$@")
  local start; start="$(date +%s)"
  local flist; flist="$(IFS=,; echo "${files[*]}")"

  echo "land-resolve: source conflict in $flist — attempting bounded coder resolve via \$LAND_RESOLVE_CODER (max ${LAND_RESOLVE_MAX_S}s)" >&2
  # Capture the REAL exit code directly (not via `if ! cmd; then $?`,
  # which collapses `timeout`'s 124 down to a bare 1 — `!` flips the
  # exit status the `if` sees, and $? afterward reflects that flipped
  # 0/1, not the command's own code. Losing 124 here would silently break
  # the timed-out/failed distinction in the log line below.)
  timeout "${LAND_RESOLVE_MAX_S}s" "$LAND_RESOLVE_CODER" "$repo" "$slug" "${files[@]}"
  local coder_rc=$?
  if [ "$coder_rc" -ne 0 ]; then
    if [ "$coder_rc" -eq 124 ]; then
      echo "land-resolve: coder timed out after ${LAND_RESOLVE_MAX_S}s for $flist" >&2
    else
      echo "land-resolve: coder invocation failed (rc=$coder_rc) for $flist" >&2
    fi
    local f
    for f in "${files[@]}"; do
      ledger_record "$repo" "$slug" "$f" source unresolved "$(( $(date +%s) - start ))"
    done
    return 1
  fi

  local test_cmd; test_cmd="$(test_cmd_for "$repo")"
  if [ -z "$test_cmd" ]; then
    echo "land-resolve: no test command available to verify the coder's resolution of $flist — treating as unresolved" >&2
    local f
    for f in "${files[@]}"; do
      ledger_record "$repo" "$slug" "$f" source unresolved "$(( $(date +%s) - start ))"
    done
    return 1
  fi
  echo "land-resolve: coder claims $flist resolved — verifying with: $test_cmd" >&2
  if ! ( cd "$repo" && eval "$test_cmd" ); then
    echo "land-resolve: post-coder check failed ($test_cmd) for $flist — treating as unresolved" >&2
    local f
    for f in "${files[@]}"; do
      ledger_record "$repo" "$slug" "$f" source unresolved "$(( $(date +%s) - start ))"
    done
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    git -C "$repo" add -- "$f"
    ledger_record "$repo" "$slug" "$f" source coder "$(( $(date +%s) - start ))"
  done
  return 0
}

# git_conflict_continue <repo> — R8: worktree-extend.sh's cmd_land hits a
# conflicted rebase in TWO places (a real `git rebase`, same shape
# gate-then-land.sh's rebase_onto_main already resolves) but ALSO a
# conflicted regular `git merge --no-ff` directly against the main
# checkout ($repo, not a worktree) — `--ours`/stage 2 already means "main"
# there too (HEAD is $default at merge time, no inversion — unlike
# rebase), but finishing the operation is `git commit`, never
# `rebase --continue` (no rebase is in progress; that call would just
# fail with "no rebase in progress"). Detects which operation <repo> is
# actually mid-way through via git's own git-path plumbing and finishes
# it the right way. Returns whatever that finishing command returns;
# non-zero (including "neither a rebase nor a merge is in progress",
# a caller bug this function refuses to guess past) is treated by
# cmd_resolve exactly like a rebase --continue failure always was.
git_conflict_continue() {
  local repo="$1"
  # `--git-path` prints a path RELATIVE TO $repo (not to our own cwd, and
  # not always absolute even under `-C`) — `--absolute-git-dir` is the one
  # call that's unambiguous regardless of where THIS script itself runs
  # from (the exact `--git-path`-vs-cwd bug landres_ac6_resolve_source_
  # conflict_untouched.sh's own comment already warns about for
  # `--git-path` alone; sidestepped here by resolving against the
  # absolute git-dir instead of trusting --git-path's own path shape).
  local gitdir; gitdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)"
  [ -n "$gitdir" ] || { echo "land-resolve: $repo is not a git repo — nothing to continue" >&2; return 1; }
  if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
    GIT_EDITOR=true git -C "$repo" rebase --continue
    return $?
  fi
  if [ -f "$gitdir/MERGE_HEAD" ]; then
    git -C "$repo" "${LAND_RESOLVE_GIT_ID[@]}" commit --no-edit
    return $?
  fi
  echo "land-resolve: neither a rebase nor a merge is in progress at $repo — nothing to continue" >&2
  return 1
}

cmd_resolve() {
  local repo="${1:-}" slug="${2:-}"
  [ -n "$repo" ] || usage
  local resolve_start; resolve_start="$(date +%s)"
  local conflicted; conflicted="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null)"
  if [ -z "$conflicted" ]; then
    echo "no-conflict"
    return 3
  fi

  local -a source_files=()
  local f cls
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cls="$(cmd_classify "$repo" "$f" "$slug")"
    case "$cls" in
      class=generated*)
        local regen_cmd="${cls#class=generated regen=}"
        echo "land-resolve: $f classified generated (regen='$regen_cmd')" >&2
        # Stage 2 / --ours during a rebase == main (see header note).
        if ! git -C "$repo" checkout --ours -- "$f" 2>/dev/null; then
          echo "land-resolve: checkout --ours failed for $f — leaving as source conflict" >&2
          source_files+=("$f")
          continue
        fi
        if [ -n "$regen_cmd" ]; then
          if ! ( cd "$repo" && eval "$regen_cmd" ) >&2 2>&1; then
            echo "land-resolve: regen command failed for $f ($regen_cmd) — leaving as source conflict" >&2
            source_files+=("$f")
            continue
          fi
        fi
        git -C "$repo" add -- "$f"
        ledger_record "$repo" "$slug" "$f" generated regen "$(( $(date +%s) - resolve_start ))"
        ;;
      class=append_only)
        echo "land-resolve: $f classified append_only — union-merging" >&2
        local tmp; tmp="$(mktemp -d)"
        git -C "$repo" show ":1:$f" >"$tmp/base" 2>/dev/null || : >"$tmp/base"
        git -C "$repo" show ":2:$f" >"$tmp/ours" 2>/dev/null || : >"$tmp/ours"
        git -C "$repo" show ":3:$f" >"$tmp/theirs" 2>/dev/null || : >"$tmp/theirs"
        if git merge-file --union "$tmp/ours" "$tmp/base" "$tmp/theirs" >/dev/null 2>&1; then
          cp "$tmp/ours" "$repo/$f"
          git -C "$repo" add -- "$f"
          ledger_record "$repo" "$slug" "$f" append_only union "$(( $(date +%s) - resolve_start ))"
        else
          echo "land-resolve: union merge failed for $f — leaving as source conflict" >&2
          source_files+=("$f")
        fi
        rm -rf "$tmp"
        ;;
      *)
        source_files+=("$f")
        ;;
    esac
  done <<<"$conflicted"

  # R4: one bounded coder attempt at whatever remains classified `source`,
  # only when a caller opted in via $LAND_RESOLVE_CODER. Unset (the
  # default) skips this block entirely — pre-R4 behavior, unchanged.
  local coder_attempted=0
  if [ "${#source_files[@]}" -gt 0 ] && [ -n "${LAND_RESOLVE_CODER:-}" ]; then
    coder_attempted=1
    if try_coder_resolve "$repo" "$slug" "${source_files[@]}"; then
      source_files=()
    fi
  fi

  if [ "${#source_files[@]}" -eq 0 ]; then
    if git_conflict_continue "$repo" >&2; then
      echo "resolved=all"
      return 0
    fi
    # The continue step itself hit a NEW conflict (e.g. a follow-on commit
    # in the same rebase) — surface it as a source conflict rather than
    # claiming success.
    local newly; newly="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    echo "source_conflicts=${newly:-unknown}"
    return 1
  fi
  # A trailing ` coder=unresolved` marks the R4-attempted-and-failed case
  # (AC5) distinctly from the never-attempted case (AC6, coder_attempted=0
  # — $LAND_RESOLVE_CODER unset) so a caller like gate-then-land.sh can
  # choose `last_error=land-conflict-unresolved:...` vs the plain
  # `last_error=land-conflict:...` it already writes.
  if [ "$coder_attempted" -eq 1 ]; then
    printf 'source_conflicts=%s coder=unresolved\n' "$(IFS=,; echo "${source_files[*]}")"
  else
    printf 'source_conflicts=%s\n' "$(IFS=,; echo "${source_files[*]}")"
  fi
  return 1
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    policy-path) [ -n "${1:-}" ] || usage; policy_path_for "$1" ;;
    classify)    cmd_classify "${1:-}" "${2:-}" "${3:-}" ;;
    resolve)     cmd_resolve "${1:-}" "${2:-}" ;;
    *) usage ;;
  esac
}

main "$@"
