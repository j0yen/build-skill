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
# Post-land intent-card check (PRD-build-intent-card-pregate-refresh R5,
# P1, AC6): once `integrate` above lands (exit 0), this script compares
# the landed head's agent/intent-card.json against $slug's own PRD path
# (same manifest/build-queue resolution extend-gate.sh's pre-gate refresh
# uses). Normally this is a no-op CHECK — the branch's own pre-gate
# refresh already committed a correct card before this land's gate ran —
# journaled `intent-card  check  ok`. On a genuine mismatch (the pre-gate
# refresh never ran, e.g. an older branch that landed via a different
# path), it is journaled `intent-card-drift` and fixed in place with a
# commit `agent: refresh intent card for <slug>` directly on main (the
# same commit subject SKILL.md's ship-sequence step already uses).
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
# PR-path landing (PRD-build-main-push-gate-pr-path requirement 1, P0,
# AC1/AC2): a `push_via_branch=true` repo (branch-protection.json — the
# repo's main refuses a direct push, GH006) cannot use the deferred-
# receipt re-verify above AT ALL — `ci-checks` at main scope needs Actions
# runs at an unpushed sha, which never exist before a push, making that
# re-verify a circular precondition (grounding: decision `ccaa7224`,
# 2026-09-16). For such a repo, checked BEFORE the deferred-receipt block
# and regardless of whether this land's own verdict deferred anything, the
# landing sequence is instead: `branch-protection.sh push <repo> <slug>`
# (pushes `loop/<slug>`, opens/reuses a PR, arms `gh pr merge --auto
# --squash` — writes `state/landings/<repo>/<slug>.json` itself) -> a
# `landing-pending` journal line -> exit 0 with the manifest sidecar's
# `last_step=landing-pending` (the PRD landed on LOCAL main; `origin/main`
# advances only once the PR's required checks go green — a later tick's
# `branch-protection.sh landing-check` + `sync` finishes the job, not this
# script). A failure IN that push step is exit 11 (below) — main already
# holds this land locally, not reverted, same "branch already landed,
# fix/retry forward" shape as the deferred-receipt block below.
#
# Exit codes:
#   0  landed (prints the landed sha on stdout)
#   1  usage error
#   6  land-retries-exhausted (stale base --max-retries times running)
#   7  gate-block (branch's gate verdict was block, or missing) — no retry
#   8  rebase-conflict — either the NEW pre-gate rebase onto main's current
#      tip (PRD-build-land-conflict-resolver R1, checked every attempt
#      before gating) or the existing post-gate stale-base recovery below;
#      either way `rebase_onto_main()` already tried `land-resolve.sh
#      resolve` first (regen/union any policy-classified conflict) before
#      surfacing this — no retry
#   9  extend-gate.sh returned an infra failure (not pass=0/block=1) — no retry
#  10  worktree-extend.sh integrate returned an unexpected infra code — no retry
#  11  post-land-main-gate-block, OR (push_via_branch=true) pr-path-push-
#      failed — either way the branch DID land on main (main is NOT
#      untouched, unlike 6/7/8/9/10): either the post-land `--scope main`
#      re-run of this land's own deferred receipts blocked, or
#      `branch-protection.sh push` itself failed. Main is left at the
#      landed head, not reverted — the next tick's ordinary main-scope
#      gate/ship path (or a retried push) fixes it forward.
#  12  contended (PRD-build-gate-patience-from-queue-depth) — extend-gate.sh
#      exited 4: it already waited this crate's full derived patience for
#      the producer lock and never got it. Not a red gate, not retried here
#      (extend-gate.sh's own flock already paid the wait once) — branch
#      kept, main untouched, `next: gate-retry` for the next tick/step.
#  13  gate-incomplete (PRD-build-gate-infra-outcome R4) — extend-gate.sh
#      exited 9: at least one phase (e.g. reviewer-agent) could not run at
#      all and no OTHER receipt blocked. NOT the same as exit 9 above —
#      this is retryable: branch kept, main untouched, no `gate-block`
#      line, `next: gate-retry` for the next tick/step, same as contended.
#      Distinguished from contended by cause (harness trouble, not a busy
#      lock) and by counting toward GATE_INFRA_MAX_ATTEMPTS (below).
#  14  gate-infra-attempts-exhausted (PRD-build-gate-infra-outcome R5) —
#      exit 13 happened GATE_INFRA_MAX_ATTEMPTS times (default 3) in a row
#      at the SAME worktree head. Not retried again at this head: a
#      decisions.sh operator decision is opened naming the phase, the last
#      note, and the attempt count; the caller records the PRD
#      `blocked/needs-user` and does not re-dispatch this head. A NEW
#      commit at this slug resets the counter (see state file below).
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
BRANCH_PROTECTION="${GATE_THEN_LAND_BRANCH_PROTECTION:-$HERE/branch-protection.sh}"
RESURRECTION_GUARD="$HERE/resurrection-guard.sh"
SIDECAR="$HERE/manifest-sidecar.sh"
DECISIONS="${GATE_THEN_LAND_DECISIONS:-$HERE/decisions.sh}"
# PRD-build-land-conflict-resolver R1/R3: a policy-classified rebase
# conflict (generated -> regen, append_only -> union) never has to fall
# all the way to `die 8` — see rebase_onto_main() below. Missing script
# (an older worktree checkout mid-rollout) degrades to today's behavior:
# any conflict is fatal, exactly as before this PRD.
LAND_RESOLVE="${GATE_THEN_LAND_LAND_RESOLVE:-$HERE/land-resolve.sh}"
# R4 (bounded coder resolve for true source conflicts): OPT-IN, not
# defaulted on — unlike LAND_RESOLVE above, an unset
# GATE_THEN_LAND_LAND_RESOLVE_CODER leaves $LAND_RESOLVE_CODER empty,
# which land-resolve.sh's own contract treats as "R4 never runs" (see its
# header comment). Every existing selftest (gate-then-land-selftest.sh,
# landres_ac1's Scenario B) relies on exactly this: a source conflict
# during a fast, deterministic test run must never silently spawn a real
# `claude -p` subagent. A deployment that wants R4 live sets
# GATE_THEN_LAND_LAND_RESOLVE_CODER="$HERE/land-resolve-coder.sh"
# (the default real coder, see that script) in its own environment.
LAND_RESOLVE_CODER="${GATE_THEN_LAND_LAND_RESOLVE_CODER:-}"
LAND_RESOLVE_MAX_S="${GATE_THEN_LAND_LAND_RESOLVE_MAX_S:-900}"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
# PRD-build-gate-infra-outcome R5: attempts-at-head counter for `incomplete`
# gates, one file per slug, so the cap is per HEAD (a new commit resets it)
# and survives across separate gate-then-land.sh invocations/ticks (this
# script's own process never loops on an incomplete result — see exit 13
# below). GATE_INFRA_MAX_ATTEMPTS default 3, overridable for fixtures.
GATE_INFRA_STATE_DIR="$STATE_DIR/gate-infra"
GATE_INFRA_MAX_ATTEMPTS="${GATE_INFRA_MAX_ATTEMPTS:-3}"
# shellcheck source=lib/push-via-branch.sh
source "$HERE/lib/push-via-branch.sh"

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

# rebase_onto_main <target-sha> — rebases $wt onto <target-sha> (globals:
# $wt, $slug — same convention jlog() already uses). Already-up-to-date is
# a no-op (returns 0 without touching the tree) — the common case, since
# most of the time nothing has landed elsewhere since `worktree-extend.sh
# add`. A conflicted rebase tries `land-resolve.sh resolve` (PRD-build-
# land-conflict-resolver R1/R3) BEFORE giving up: a conflict entirely in
# files the target repo's land-policy lists as generated/append-only
# resolves (regen/union) and the rebase continues, all inside this call.
# Any remaining source conflict aborts the rebase and returns 1, leaving
# $wt exactly as it was before this call — the caller decides what "give
# up" means (today: die 8, unchanged; R4's bounded coder attempt is a
# later PRD step, not yet wired in here).
#
# `$wt`'s own basename is `<repo>-<slug>` (worktree-extend.sh's naming
# convention), never the target repo's own basename land-resolve.sh's
# policy file is keyed on — LAND_RESOLVE_POLICY_BASENAME tells it the real
# name (`basename $repo`) so a worktree-invoked resolve still finds
# `state/land-policy/<repo>.json` instead of silently missing it and
# falling through to `source` for everything (found by this PRD's own
# landres_ac1_pregate_rebase_resolves_generated.sh selftest).
# $rebase_coder_unresolved (global, read by both die-8 call sites below):
# set to 1 when land-resolve.sh's R4 bounded coder attempt ran and did NOT
# resolve the rebase (so the caller writes `last_error=land-conflict-
# unresolved:...` instead of the plain `land-conflict:...` it writes when
# no coder attempt was ever made — R4/AC5 vs R6/AC6). Reset at the top of
# every call so a PRIOR attempt's flag never leaks into this one's verdict.
rebase_coder_unresolved=0
rebase_onto_main() {
  local target="$1"
  rebase_coder_unresolved=0
  if git -C "$wt" merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
    return 0
  fi
  if git -C "$wt" "${GIT_ID[@]}" rebase "$target" >&2; then
    return 0
  fi
  if [ -x "$LAND_RESOLVE" ]; then
    local resolve_out
    resolve_out="$(LAND_RESOLVE_POLICY_BASENAME="$(basename "$repo")" LAND_RESOLVE_CODER="$LAND_RESOLVE_CODER" LAND_RESOLVE_MAX_S="$LAND_RESOLVE_MAX_S" "$LAND_RESOLVE" resolve "$wt" "$slug" 2>&1)"
    local resolve_rc=$?
    printf '%s\n' "$resolve_out" >&2
    if [ "$resolve_rc" -eq 0 ]; then
      return 0
    fi
    case "$resolve_out" in
      *' coder=unresolved'*) rebase_coder_unresolved=1 ;;
    esac
  fi
  git -C "$wt" rebase --abort 2>/dev/null
  return 1
}

wt="$("$WORKTREE_EXTEND" add "$repo" "$slug")" || die 2 "worktree-extend.sh add failed for $slug"

main_shas_seen=()
attempt=1
while [ "$attempt" -le "$max_retries" ]; do
  main_sha="$(git -C "$repo" rev-parse HEAD)"
  main_shas_seen+=("$main_sha")

  # PRD-build-land-conflict-resolver R1 (P0): rebase the worktree onto
  # main's CURRENT tip BEFORE gating, not after — the grounding incident
  # this PRD exists to fix (gate-debt-4f1112d) gated a tree that was
  # already behind main, so the conflict only surfaced at land time, one
  # tick too late to recover cheaply. A no-op in the common case (nothing
  # landed elsewhere since `worktree-extend.sh add`). extend-gate.sh's own
  # journal line already reports main's HEAD at gate start as `base=`
  # (PRD-build-gate-before-land requirement 1) — this rebase is what makes
  # that reported base match the tree actually gated, not just an
  # informational field alongside a stale one.
  if ! rebase_onto_main "$main_sha"; then
    conflict_files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    [ -z "$conflict_files" ] && conflict_files="unknown"
    # R4/AC5 vs R6/AC6: a coder attempt that ran and failed gets its own
    # distinct last_error so the ledger/operator can tell "tried, gave up"
    # from "no policy/coder configured, today's behavior" — see
    # rebase_onto_main()'s $rebase_coder_unresolved comment above.
    if [ "$rebase_coder_unresolved" -eq 1 ]; then
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=land-conflict-unresolved:${conflict_files}" >&2 || true
    else
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=land-conflict:${conflict_files}" >&2 || true
    fi
    jlog "rebase-conflict attempt=$attempt files=$conflict_files pre-gate=true"
    die 8 "rebase conflict onto main=$main_sha before gating (pre-gate rebase); branch kept, not retried"
  fi
  wt_head="$(git -C "$wt" rev-parse HEAD)"

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
    4)
      # PRD-build-gate-patience-from-queue-depth requirement 2/6 (P0/P1):
      # exit 4 means extend-gate.sh already waited this crate's full
      # derived patience for the producer lock and never got it — it is
      # CONTENTION, not a red gate and not an infra failure, and it is
      # never retried again here: a second call would just wait out the
      # same patience a second time (AC8's "no fixed 90s retry boundary" —
      # the wait already happened exactly once, inside extend-gate.sh's
      # own flock). Never journals `gate-block`/`gate-red`/`verdict=block`.
      # manifest-sidecar.sh has no dedicated `next` key (its schema is
      # status/last_error/action/outcome/output_repo_*) — the actual
      # `next: gate-retry` manifest field this requirement names is written
      # by the calling branch agent's own Phase 7 manifest-set.sh patch
      # (see SKILL.md's gate action, "derived patience" paragraph);
      # `outcome` here is this script's own best-effort record of the same
      # fact for anyone reading the sidecar directly. `blockers` is never
      # touched by this exit path (nothing here calls into blocker state).
      [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "outcome=contended, next=gate-retry" >&2 || true
      jlog "contended attempt=$attempt (see extend-gate.sh's own gate/contended journal line for holder identity)"
      die 12 "producer-lock-contended — extend-gate.sh exhausted this crate's derived patience; branch kept, main untouched, next=gate-retry"
      ;;
    9)
      # PRD-build-gate-infra-outcome R4/R5: extend-gate.sh's own `incomplete`
      # verdict — a phase (e.g. reviewer-agent) could not run at all, and no
      # OTHER receipt blocked. Never a `gate-block` line — this is the exact
      # bug this PRD fixes: a harness hiccup used to fall through to the
      # `*)` catch-all below and read identically to a real infra failure,
      # with no distinct retry path. Bounded by GATE_INFRA_MAX_ATTEMPTS at
      # THIS head (state file below; a new commit resets it since $wt_head
      # changes).
      infra_first="$(jq -r '(.infra_notes // [])[0] // "unknown — no infra_notes on verdict file"' "$verdict_path" 2>/dev/null)"
      [ -n "$infra_first" ] || infra_first="unknown — no infra_notes on verdict file"
      infra_phase="${infra_first%% — *}"
      infra_note="${infra_first#* — }"
      mkdir -p "$GATE_INFRA_STATE_DIR"
      infra_state_file="$GATE_INFRA_STATE_DIR/$slug.json"
      prev_head="" prev_n=0
      if [ -f "$infra_state_file" ]; then
        prev_head="$(jq -r '.head // empty' "$infra_state_file" 2>/dev/null)"
        prev_n="$(jq -r '.attempts // 0' "$infra_state_file" 2>/dev/null)"
      fi
      if [ "$prev_head" = "$wt_head" ]; then
        infra_n=$((prev_n + 1))
        # Once the cap is reached, the counter is pinned at the cap rather
        # than left to grow unbounded on a caller that (against R5's own
        # "not launched again at this head") retries anyway — an unbounded
        # counter would change the decision question's own text every
        # call ("...3x..." then "...4x..."), defeating decisions.sh's
        # idempotency (it dedupes on exact question text) and opening a
        # NEW row every retry instead of exactly one.
        [ "$infra_n" -gt "$GATE_INFRA_MAX_ATTEMPTS" ] && infra_n="$GATE_INFRA_MAX_ATTEMPTS"
      else
        infra_n=1
      fi
      jq -n --arg head "$wt_head" --argjson n "$infra_n" --arg phase "$infra_phase" --arg note "$infra_note" \
        '{head: $head, attempts: $n, phase: $phase, note: $note}' > "$infra_state_file.tmp" \
        && mv -f "$infra_state_file.tmp" "$infra_state_file"
      last_error="gate-infra:${infra_phase}:${infra_note}"
      if [ "$infra_n" -lt "$GATE_INFRA_MAX_ATTEMPTS" ]; then
        [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=$last_error, next=gate-retry" >&2 || true
        jlog "gate-incomplete attempt=$infra_n infra=$infra_phase"
        die 13 "extend-gate.sh returned incomplete (infra=$infra_phase: $infra_note) — attempt $infra_n/$GATE_INFRA_MAX_ATTEMPTS, branch kept, main untouched, next=gate-retry"
      else
        # R5 cap reached at this head: escalate once (decisions.sh open is
        # idempotent on question text — a later invocation at the SAME
        # head/phase/note is a silent no-op, never a second decision row).
        decision_q="gate-infra-outcome: $slug stuck incomplete ${GATE_INFRA_MAX_ATTEMPTS}x at head ${wt_head:0:7} (phase=$infra_phase note=$infra_note) — needs a human look"
        decision_id=""
        if [ -x "$DECISIONS" ]; then
          decision_id="$("$DECISIONS" open "$decision_q" --owner joe --repo "$slug" 2>/dev/null | tail -n1)"
        fi
        [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=$last_error" >&2 || true
        jlog "gate-infra-attempts-exhausted attempts=$infra_n infra=$infra_phase decision=${decision_id:-unknown}"
        die 14 "extend-gate.sh returned incomplete $GATE_INFRA_MAX_ATTEMPTS consecutive times at head ${wt_head:0:7} (infra=$infra_phase: $infra_note) — blocked/needs-user, decision ${decision_id:-unknown} opened, not retried again at this head"
      fi
      ;;
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
      # R5 (P1, PRD-build-intent-card-pregate-refresh, AC6): post-land is
      # a CHECK now, not a write — R1/R2's pre-gate refresh (extend-
      # gate.sh, --scope branch) already committed a correct card ON THE
      # BRANCH before this land's own gate ran, so the landed head should
      # already carry it. Compare the landed card's prd_source against
      # this slug's own PRD path — same resolution extend-gate.sh's
      # pre-gate step uses (manifest path, falling back to the
      # build-queue/ convention on slug) — never intent-card-refresh.sh
      # --check's own "newest BUILT PRD" inference, which is stale here:
      # $slug's manifest status is still in_progress at this exact
      # moment, well before Phase 7 marks it built. Only on a real
      # mismatch is the card fixed in place and committed on main — the
      # "fixed as today" ship-sequence convention (SKILL.md Phase 4's
      # "intent card refresh" step's own commit subject).
      _icr_check_prd_dir="${GATE_PATIENCE_PRD_DIR:-$HOME/Documents/PRDs}"
      _icr_check_prd_path="$_icr_check_prd_dir/build-queue/PRD-$slug.md"
      _icr_check_manifest="${INTENT_CARD_REFRESH_MANIFEST:-$HERE/../state/manifest.json}"
      if [ -r "$_icr_check_manifest" ] && command -v jq >/dev/null 2>&1; then
        _icr_check_manifest_path="$(jq -r --arg s "$slug" '.prds[$s].path // empty' "$_icr_check_manifest" 2>/dev/null)"
        if [ -n "$_icr_check_manifest_path" ] && [ "$_icr_check_manifest_path" != null ] && [ -r "$_icr_check_manifest_path" ]; then
          _icr_check_prd_path="$_icr_check_manifest_path"
        fi
      fi
      if [ -r "$_icr_check_prd_path" ]; then
        _icr_landed_prd_source="$(jq -r '.prd_source // empty' "$repo/agent/intent-card.json" 2>/dev/null || true)"
        _icr_same=false
        if [ -n "$_icr_landed_prd_source" ]; then
          _icr_landed_abs="$_icr_landed_prd_source"
          [ -r "$_icr_landed_prd_source" ] && _icr_landed_abs="$(cd "$(dirname "$_icr_landed_prd_source")" && pwd)/$(basename "$_icr_landed_prd_source")"
          _icr_expect_abs="$(cd "$(dirname "$_icr_check_prd_path")" && pwd)/$(basename "$_icr_check_prd_path")"
          [ "$_icr_landed_abs" = "$_icr_expect_abs" ] && _icr_same=true
        fi
        if $_icr_same; then
          jlog "intent-card  check  ok"
        else
          jlog "intent-card-drift landed_prd_source=${_icr_landed_prd_source:-none} expected=$_icr_check_prd_path"
          _icr_fix_args=("$repo" --prd "$_icr_check_prd_path")
          [ -n "$project_root" ] && _icr_fix_args+=(--project-root "$project_root")
          if "$HERE/intent-card-refresh.sh" "${_icr_fix_args[@]}" >&2; then
            # Same atomicity gotcha as extend-gate.sh's pre-gate commit: a
            # pathspec that never existed (no extended-gates.toml, no
            # amendment file) fails `git add`/`git commit -- <pathspec>`
            # for every path in one invocation, not just the missing one.
            _icr_candidate_paths=(agent/intent-card.json agent/intent-card.carried.json agent/intent_card_amendment_request.json extended-gates.toml)
            _icr_existing_paths=()
            for _icr_p in "${_icr_candidate_paths[@]}"; do
              if [ -e "$repo/$_icr_p" ] || git -C "$repo" ls-files --error-unmatch -- "$_icr_p" >/dev/null 2>&1; then
                _icr_existing_paths+=("$_icr_p")
              fi
            done
            if [ "${#_icr_existing_paths[@]}" -gt 0 ] && \
               [ -n "$(git -C "$repo" status --porcelain -- "${_icr_existing_paths[@]}" 2>/dev/null)" ]; then
              ( cd "$repo" && git add -- "${_icr_existing_paths[@]}"
                git "${GIT_ID[@]}" commit -q -m "agent: refresh intent card for $slug" \
                  -- "${_icr_existing_paths[@]}" )
              landed_sha="$(git -C "$repo" rev-parse HEAD)"
              jlog "intent-card-drift fixed sha=$landed_sha"
            fi
          else
            jlog "intent-card-drift fix-failed"
          fi
        fi
      fi
      # PRD-build-main-push-gate-pr-path requirement 1 (P0, AC1/AC2): a
      # push_via_branch=true repo's `main` cannot pass the ordinary
      # deferred-receipt re-verify below AT ALL — `ci-checks` at main scope
      # needs Actions runs at an unpushed sha, which can never exist before
      # a push, and this repo's push can only happen via a PR (branch
      # protection refuses a direct push outright, GH006). So for such a
      # repo the landing sequence stops being "gate, land, re-verify" and
      # becomes "gate, land, push-branch, open-PR, arm-auto-merge, record,
      # exit 0 pending" — the deferred-receipt re-verify (die 11 path)
      # below never runs for it, checked BEFORE that block, regardless of
      # whether this land's own verdict deferred anything.
      repo_slug_pvb="$(basename "$repo")"
      if [ "$(push_via_branch_for "$repo_slug_pvb")" = "true" ]; then
        echo "gate-then-land: [$slug] $repo_slug_pvb is push_via_branch=true — landing via PR path (branch-protection.sh push), not a direct main-scope re-verify" >&2
        push_out="$("$BRANCH_PROTECTION" push "$repo" "$slug" 2>&1)"
        push_rc=$?
        echo "$push_out" >&2
        if [ "$push_rc" -ne 0 ]; then
          [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "last_error=pr-path-push-failed:$push_rc" >&2 || true
          jlog "pr-path-push-failed attempt=$attempt sha=$landed_sha rc=$push_rc"
          die 11 "branch-protection.sh push failed (rc=$push_rc) for the PR-path landing of $landed_sha on $repo_slug_pvb — main already advanced locally to $landed_sha (NOT reverted); retry next tick"
        fi
        pr_url_pvb="$(printf '%s\n' "$push_out" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | head -1)"
        [ -x "$SIDECAR" ] && "$SIDECAR" write "$slug" "status=in_progress" "last_step=landing-pending" \
          "outcome=landing-pending pr=${pr_url_pvb:-unknown} head=$landed_sha" >&2 || true
        jlog "landing-pending pr=${pr_url_pvb:-unknown} head=$landed_sha attempt=$attempt"
        printf '%s\n' "$landed_sha"
        exit 0
      fi
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
      if ! rebase_onto_main "$new_main"; then
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
