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
# before treating a rebase conflict as fatal. Regen/union execution (R3)
# and this step's ledger (R5) are landed; the bounded coder resolve (R4)
# and wiring this script into gate-then-land.sh/worktree-extend.sh (R1/R8)
# are later steps in this same PRD (Non-goal for THIS step: still no
# caller changed — `resolve` is exercised only by this PRD's own tests).
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
#       a source conflict, left untouched (conflict markers still in the
#       working tree). If zero source conflicts remain, runs
#       `git rebase --continue` and prints `resolved=all`, exit 0. If any
#       source conflicts remain, the rebase is left open (NOT continued —
#       R4's bounded coder step, a later PRD step, owns what happens to
#       those), prints `source_conflicts=<comma-list>`, exit 1. Prints
#       `no-conflict` and exits 3 if <repo> has no conflicted paths at all
#       (nothing to resolve — a caller bug, not a land-resolve failure).
#       Every path this script itself resolves without escalating (i.e.
#       `generated`->regen or `append_only`->union, never `source`) appends
#       one record to the ledger (R5) — see below.
#
# Ledger (R5): state/land-conflicts.jsonl, one JSON record per resolved
# FILE (not per resolve() call — a single conflicted rebase touching two
# files yields two records), append-only, one line per `jq -c` object:
#   {"ts": "<ISO-8601>", "repo": "<basename>", "slug": "<slug>",
#    "file": "<repo-relative path>", "class": "generated"|"append_only",
#    "resolution": "regen"|"union", "wall_seconds": <int>}
# This script only ever writes `class`/`resolution` pairs it can attest to
# directly (regen, union) — `source`/`coder`/`unresolved` records (AC4/AC5)
# belong to R4's bounded-coder step, a later caller that owns the
# succeed/fail/timeout verdict this script has no visibility into (a file
# left as a source conflict here might still be resolved by that coder a
# moment later). `wall_seconds` is elapsed time since this `resolve` call
# started, not a per-file timer — regen/union are near-instant in practice
# and the ledger's purpose is trend visibility (R5's "operator can see
# which files conflict and how often"), not a profiler.
# `scripts/land-conflicts-report.sh` reads this file and prints conflicts
# by frequency.
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

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
LAND_POLICY_DIR="${LAND_POLICY_DIR:-$STATE_DIR/land-policy}"
LAND_CONFLICTS_LEDGER="${LAND_CONFLICTS_LEDGER:-$STATE_DIR/land-conflicts.jsonl}"

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
  line="$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repo "$(basename "$repo")" \
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

  if [ "${#source_files[@]}" -eq 0 ]; then
    if GIT_EDITOR=true git -C "$repo" rebase --continue >&2; then
      echo "resolved=all"
      return 0
    fi
    # rebase --continue itself hit a NEW conflict (e.g. a follow-on commit
    # in the same rebase) — surface it as a source conflict rather than
    # claiming success.
    local newly; newly="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    echo "source_conflicts=${newly:-unknown}"
    return 1
  fi
  printf 'source_conflicts=%s\n' "$(IFS=,; echo "${source_files[*]}")"
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
