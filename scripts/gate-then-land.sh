#!/usr/bin/env bash
# gate-then-land.sh — PRD-build-gate-before-land requirement 3 (P0): the
# rebase-and-regate loop that ties together requirement 1's branch-scoped
# gate and requirement 2's land-if-unchanged precondition into the single
# sequence SKILL.md's rust-extend land step now calls (requirement 8):
# gate on branch -> land-if-unchanged -> (on a stale base) rebase, re-gate,
# retry -> (on a gate block) stop, branch kept, main untouched.
#
# usage: gate-then-land.sh <repo> <slug> <bump> <tldr-file>
#                           [--project-root <rel>] [--ensure-main]
#                           [--max-retries N (default 3)]
#
# <repo> is the build_into main checkout (never a worktree); <slug>'s
# worktree is fetched (or created, idempotently) via `worktree-extend.sh
# add`. <bump>/<tldr-file> are threaded straight through to
# `worktree-extend.sh integrate` (rust-extend's version-bump + CHANGELOG
# step) exactly as SKILL.md's Phase 4 integrate call already passes them —
# this script wraps `integrate`, not `land` (python-extend's `land` has no
# gate of its own to loop on; see PRD non-goals).
#
# Loop, up to --max-retries attempts (default 3):
#   1. extend-gate.sh <worktree> --head <worktree HEAD> --scope branch
#      --slug <slug>  (requirement 1) — runs the full producer sequence in
#      the worktree's own off-root target, no crate-wide lock.
#   2. worktree-extend.sh integrate --gated-at <main HEAD at step 1>
#      --verdict <that gate's last-verdict.json> ...  (requirement 2)
#   3. exit 0            -> landed; print the landed sha, done.
#      exit 6 (stale base) -> a sibling landed first. Rebase the worktree
#        onto main's NEW HEAD (`git rebase`; a real conflict here is NOT
#        retried — recorded and this script stops, exit 8), run
#        resurrection-guard.sh (informational, PRD-build-gate-debt-auto-prd
#        requirement 5 — never blocks) over the rebase's own diff, then
#        loop back to step 1 for another attempt.
#      exit 7 (ungated/blocked) -> the branch's own gate verdict is not
#        pass/delta-pass. NOT retried (retrying only helps a STALE base,
#        never a red gate) — recorded, branch kept, main untouched, exit 7.
#      anything else -> an infra failure in gate or land itself (dirty
#        tree, lock contention, merge conflict INSIDE integrate after its
#        own rebase-retry) — recorded, not retried, propagated.
#   After --max-retries consecutive stale-base attempts: blocked, exit 6,
#   with all the main shas seen recorded in the sidecar/journal (AC5).
#
# Post-land deferred re-verification (PRD-build-branch-gate-scope-
# artifacts requirement 5, P0, AC7): a branch-scope verdict can carry
# `deferred_receipts` (rollback-plan's head-untagged, ci-checks'
# no-runs-on-ref — both branch-scope artifacts extend-gate.sh's own
# `--scope branch` post-classifies rather than blocks on, per that PRD's
# requirements 1/2). Those preconditions (a real tag on HEAD, a pushed CI
# run) only become real once the branch is actually ON main — so the
# instant `integrate` above returns 0, and only when this land's own gate
# verdict (at $verdict_path) named at least one deferred receipt, this
# script re-runs the FULL, ordinary `--scope main` gate (unchanged from
# any other main-scope call — no hand-picked subset of producers, and the
# verdict cache can never silently replay a deferred entry regardless —
# see extend-gate.sh's cache-hit guard) against the just-landed head,
# before reporting success. A block there does NOT revert the merge (main
# already advanced; un-landing a fast-forward this script itself just
# made would itself be a destructive git operation this script has no
# other reason to perform) — it is "a normal main-scope block (existing
# path)": main is left gated-red at the landed head, exactly as any other
# main-scope gate failure already leaves it, ready for the next tick to
# fix forward; ship-tag.sh (SKILL.md's separate ship step) only ever runs
# after a `--scope main` gate itself exits 0, so "before any tag is
# created" holds. Exit 11 (below) reports this distinctly from the
# 6/7/8/9/10 family, all of which mean "branch kept, main untouched" —
# that is NOT true here, so no caller may treat 11 as one of those.
#
# Exit codes:
#   0  landed (prints the landed sha on stdout)
#   1  usage error
#   6  land-retries-exhausted (stale base --max-retries times running)
#   7  gate-block (branch's gate verdict was block, or missing) — no retry
#   8  rebase-conflict while recovering from a stale base — no retry
#   9  extend-gate.sh returned an infra failure (not pass=0/block=1) — no retry
#  10  worktree-extend.sh integrate returned an unexpected infra code — no retry
#  11  post-land-main-gate-block — the branch DID land on main (main is NOT
#      untouched, unlike 6/7/8/9/10); the post-land `--scope main` re-run of
#      this land's own deferred receipts blocked. Main is left gated-red at
#      the landed head, not reverted — the next tick's ordinary main-scope
#      gate/ship path fixes it forward like any other main-scope block.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Overridable so tests/ can point at a fixture fake extend-gate.sh — a real
# one means a real cargo/autobuilder producer sequence per attempt (60-90s+,
# and a fixture crate reliably reaching pass/delta-pass takes far more
# scaffolding than exercising THIS script's own retry/rebase/exit-code
# logic needs). worktree-extend.sh stays real by default in every selftest
# — its own land/integrate git mechanics are fast, deterministic, and
# already covered by worktree-extend-gated-land-selftest.sh; this script's
# value-add is the loop around it.
EXTEND_GATE="${GATE_THEN_LAND_EXTEND_GATE:-$HERE/extend-gate.sh}"
WORKTREE_EXTEND="${GATE_THEN_LAND_WORKTREE_EXTEND:-$HERE/worktree-extend.sh}"
RESURRECTION_GUARD="$HERE/resurrection-guard.sh"
SIDECAR="$HERE/manifest-sidecar.sh"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

die() { echo "gate-then-land: $2" >&2; exit "$1"; }
usage() {
  cat <<'EOF' >&2
usage: gate-then-land.sh <repo> <slug> <bump> <tldr-file>
                          [--project-root <rel>] [--ensure-main]
                          [--max-retries N (default 3)]
EOF
}

[ -x "$EXTEND_GATE" ] || die 2 "missing $EXTEND_GATE"
[ -x "$WORKTREE_EXTEND" ] || die 2 "missing $WORKTREE_EXTEND"

project_root="" ensure_main="" max_retries="${GATE_THEN_LAND_MAX_RETRIES:-3}"
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) project_root="${2:?gate-then-land: --project-root needs a value}"; shift 2 ;;
    --ensure-main)  ensure_main=1; shift ;;
    --max-retries)  max_retries="${2:?gate-then-land: --max-retries needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) pos+=("$1"); shift ;;
  esac
done
repo="${pos[0]:-}"; slug="${pos[1]:-}"; bump="${pos[2]:-minor}"; tldr="${pos[3]:-}"
[ -n "$repo" ] && [ -n "$slug" ] || { usage; die 1 "missing <repo>/<slug>"; }
repo="$(cd "$repo" 2>/dev/null && pwd)" || die 1 "no such directory: ${pos[0]:-}"

journal="${GATE_THEN_LAND_JOURNAL:-$HOME/brain/journal/build/$(date -u +%Y-%m-%d).md}"
if [ -r "$HERE/isolation-guard.sh" ]; then
  # shellcheck source=isolation-guard.sh
  source "$HERE/isolation-guard.sh"
  isolation_guard_path "$journal" "gate-then-land.sh"
fi
mkdir -p "$(dirname "$journal")"
jlog() { printf '%s  gate-then-land  %s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$1" >>"$journal"; }

pr_args=(); [ -n "$project_root" ] && pr_args=(--project-root "$project_root")

wt="$("$WORKTREE_EXTEND" add "$repo" "$slug")" || die 2 "worktree-extend.sh add failed for $slug"

main_shas_seen=()
attempt=1
while [ "$attempt" -le "$max_retries" ]; do
  wt_head="$(git -C "$wt" rev-parse HEAD)"
  main_sha="$(git -C "$repo" rev-parse HEAD)"
  main_shas_seen+=("$main_sha")

  echo "gate-then-land: [$slug] attempt $attempt/$max_retries — gating $wt_head against main=$main_sha" >&2
  "$EXTEND_GATE" "$wt" --head "$wt_head" --scope branch --slug "$slug" "${pr_args[@]}" >&2
  gate_rc=$?
  verdict_path="$("$EXTEND_GATE" "$wt" "${pr_args[@]}" --print-verdict-path 2>/dev/null)"
  # requirement 5 / AC7: read BEFORE `integrate` runs, below — a
  # successful land deletes the worktree (and its off-root target dir,
  # where $verdict_path lives) as its own cleanup, so reading this AFTER
  # `integrate` returns 0 silently sees a missing file and never re-runs
  # anything (caught by a manual gate-then-land test that set
  # FAKE_BRANCH_DEFERRED and never saw the re-verification fire).
  deferred_list="$([ -f "$verdict_path" ] && jq -r '(.deferred_receipts // []) | join(",")' "$verdict_path" 2>/dev/null || true)"

  case "$gate_rc" in
    0|1) : ;;   # pass or block — a real verdict, let land's own precondition decide
    *)
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=gate-infra-failure:$gate_rc" >&2 || true
      jlog "gate-infra-failure rc=$gate_rc attempt=$attempt"
      die 9 "extend-gate.sh returned infra failure $gate_rc (not a pass/block verdict) — not retried"
      ;;
  esac

  land_err="$(mktemp "${TMPDIR:-/tmp}/gate-then-land-err.XXXXXX")"
  land_out="$("$WORKTREE_EXTEND" integrate --gated-at "$main_sha" --verdict "$verdict_path" \
    "${pr_args[@]}" ${ensure_main:+--ensure-main} "$repo" "$slug" "$bump" "$tldr" 2>"$land_err")"
  land_rc=$?
  cat "$land_err" >&2
  rm -f "$land_err"

  case "$land_rc" in
    0)
      landed_sha="$(git -C "$repo" rev-parse HEAD)"
      # requirement 5 / AC7 — see file header and $deferred_list's own
      # comment above (captured before `integrate` deleted the worktree
      # this verdict lived in). Only when THIS land's own gate verdict
      # actually deferred something; an ordinary land (no deferrals) pays
      # no extra gate at all, unchanged from before this PRD.
      if [ -n "$deferred_list" ]; then
        echo "gate-then-land: [$slug] verdict carried deferred receipts ($deferred_list) — re-verifying at --scope main on landed head $landed_sha before declaring this land ship-strength-unchanged" >&2
        if ! "$EXTEND_GATE" "$repo" --head "$landed_sha" "${pr_args[@]}" --force >&2; then
          [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=post-land-main-gate-block:${deferred_list}" >&2 || true
          jlog "post-land-main-gate-block attempt=$attempt deferred=${deferred_list} sha=$landed_sha"
          die 11 "post-land main-scope re-verification of deferred receipts ($deferred_list) blocked on $landed_sha — branch already landed on main (NOT reverted); main is gated-red at $landed_sha until fixed forward"
        fi
        jlog "post-land-main-gate-pass attempt=$attempt deferred=${deferred_list} sha=$landed_sha"
      fi
      jlog "landed attempt=$attempt version=$land_out sha=$landed_sha"
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "outcome=landed attempt $attempt/$max_retries" >&2 || true
      printf '%s\n' "$landed_sha"
      exit 0
      ;;
    6)
      # land-stale-base: a sibling landed first. Rebase-and-regate
      # (requirement 3) — NOT a failure, a normal same-target-cap outcome.
      new_main="$(git -C "$repo" rev-parse HEAD)"
      echo "gate-then-land: [$slug] stale base (main advanced to $new_main) — rebasing and re-gating" >&2
      before_wt_head="$(git -C "$wt" rev-parse HEAD)"
      if ! git -C "$wt" "${GIT_ID[@]}" rebase "$new_main" >&2; then
        git -C "$wt" rebase --abort 2>/dev/null
        conflict_files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
        [ -z "$conflict_files" ] && conflict_files="unknown"
        [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=land-conflict:${conflict_files}" >&2 || true
        jlog "rebase-conflict attempt=$attempt files=$conflict_files"
        die 8 "rebase conflict recovering from stale base (main=$new_main); branch kept, not retried"
      fi
      after_wt_head="$(git -C "$wt" rev-parse HEAD)"
      # Informational only (always exits 0, never blocks — see its own
      # header): scans the rebase's own diff for a resurrected unsafe
      # block a prior fix removed, same shape PRD-build-gate-debt-auto-prd
      # requirement 5 already checks for union-resolve merges.
      [ -x "$RESURRECTION_GUARD" ] && JOURNAL="$journal" "$RESURRECTION_GUARD" check "$wt" "$before_wt_head" "$after_wt_head" >&2 || true
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "outcome=land-retry $attempt/$max_retries:stale-base $main_sha->$new_main" >&2 || true
      jlog "stale-base-retry attempt=$attempt gated_at=$main_sha main_now=$new_main"
      attempt=$((attempt + 1))
      continue
      ;;
    7)
      blockers=""
      [ -f "$verdict_path" ] && blockers="$(jq -r '((.new_blocks // []) + (.inherited_blocks // [])) | join(",")' "$verdict_path" 2>/dev/null)"
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=gate-block:branch:${blockers:-unknown}" >&2 || true
      jlog "gate-block attempt=$attempt blockers=${blockers:-unknown}"
      die 7 "land-ungated — branch's own gate verdict was not pass/delta-pass (blockers=${blockers:-unknown}); branch kept, main untouched"
      ;;
    *)
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=land-infra-failure:$land_rc" >&2 || true
      jlog "land-infra-failure rc=$land_rc attempt=$attempt"
      die 10 "worktree-extend.sh integrate returned unexpected exit $land_rc — not retried"
      ;;
  esac
done

# --- max retries exhausted (AC5) ------------------------------------------
shas_csv="$(IFS=,; echo "${main_shas_seen[*]}")"
[ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "status=blocked" "last_error=land-retries-exhausted:${shas_csv}" >&2 || true
jlog "land-retries-exhausted attempts=$max_retries main_shas=$shas_csv"
die 6 "land-retries-exhausted after $max_retries stale-base attempts (main shas seen: $shas_csv)"
