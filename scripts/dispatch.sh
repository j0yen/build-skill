#!/usr/bin/env bash
# dispatch.sh — the tick is a program; a model is spent only inside a
# branch (PRD-build-programmatic-dispatch).
#
# Replaces the coordinator's own Phase 0-2 script-reading + Agent-call
# composition with one script: run the same Phase 0-2 scripts tick-run.sh
# always ran anyway, render one self-contained prompt per admitted entry
# from docs/branch-contract.md + the PRD text + the entry's own computed
# fields, launch one `claude -p` per branch under its own systemd unit
# with the PRD lock held by that process (`flock -n` wraps the unit's own
# exec, same as directive 1 already requires of a human-composed branch
# dispatch — an already-held lock now fails the unit fast instead of
# wasting a model call), wait, run the parent steps, and record the tick.
#
# Usage:
#   dispatch.sh [--dry-run] [--pin <slug>[,<slug>...]]
#       Full tick. --dry-run: Phase 0-2 + prompt rendering only, nothing
#       launched (requirement 6 / AC7).
#   dispatch.sh render <entry.json>
#       Prints one branch's rendered prompt to stdout, for audit or reuse
#       by the launch step itself (requirement 2 / AC2, AC3). <entry.json>
#       is one element of select-tick.sh --format json's "admitted" array,
#       written to a file.
#
# Env:
#   BUILD_SKILL_DIR / BUILD_STATE_DIR   same convention as every other
#                     script here (default: this script's own ../, and
#                     <skill-dir>/state).
#   BUILD_MANIFEST    manifest.json path (default $BUILD_STATE_DIR/manifest.json)
#                     — read-only here, for the landing-pending resume check.
#   CLAUDE_BIN        coordinator binary each branch execs (default
#                     ~/.local/bin/claude, same default tick-run.sh uses).
#   BRANCH_MAX_WALL   seconds a launched unit may run before dispatch.sh
#                     stops it and records last_error=branch-wall-exceeded
#                     (default 5400 = 90 min; requirement 4 / AC4).
#   DISPATCH_LANE     lane tag for journal lines (default: hostname).
#   DISPATCH_POLL_INTERVAL  seconds between wait_units polls (default 2;
#                     selftests shrink this).
#   PRD_DIR           PRD root, same convention as scan-prds.sh/manifest-
#                     reconcile.sh (env) and select-tick.sh/manifest-
#                     invariants.sh (--prd-dir); forwarded to all four so
#                     one override isolates the whole Phase 0-2 pipeline
#                     (default $HOME/Documents/PRDs).
#
# Requirement 7 (P1): a quota tier is read before launch IF
# scripts/quota-tier.sh exists (PRD-build-quota-admission's own script —
# not yet landed in this checkout as of this PRD; probed, not assumed, so
# this PRD does not block on that one landing first, and the hook is live
# the moment it does). `paused` -> nothing launches, outcome
# `skipped:quota` (AC8).
#
# Design note on tick-outcome.json (requirement 4's "writes tick-
# outcome.json"): tick-run.sh already writes $BUILD_STATE_DIR/tick-
# outcome.json unconditionally on every coordinator-process exit (its own
# write_tick_outcome(), AFTER this script — now the default coordinator,
# requirement 5 — exits). A second, differently-shaped write to that same
# path from INSIDE this script would race that parent-level write (the
# parent's fires strictly after this process exits, so it would always
# win, silently discarding whatever this script wrote). This script
# therefore writes its own richer per-tick record to a distinct path,
# $BUILD_STATE_DIR/dispatch/last-tick.json (admitted/dispatched/skipped/
# reconciled/healed/alarmed/units[]) — tick-run.sh's --status (this PRD's
# AC6) reads it to print `admitted=<n> dispatched=<n>`, and
# tick-outcome.json itself keeps being written exactly as before, by the
# same wrapper, satisfying AC5's literal text without a two-writer race.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
DISPATCH_STATE_DIR="$STATE_DIR/dispatch"
BRANCH_CONTRACT_MD="${DISPATCH_BRANCH_CONTRACT_MD:-$SKILL_DIR/docs/branch-contract.md}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
# Same convention as scan-prds.sh/manifest-reconcile.sh (PRD_DIR env) and
# select-tick.sh/manifest-invariants.sh (--prd-dir flag) -- threaded
# through to both forms below so one override isolates every Phase 0-2
# script a selftest calls, same as it would for a real alternate PRD root.
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"

TICK_RUN="${DISPATCH_TICK_RUN:-$HERE/tick-run.sh}"
MANIFEST_RECONCILE="${DISPATCH_MANIFEST_RECONCILE:-$HERE/manifest-reconcile.sh}"
SCAN_PRDS="${DISPATCH_SCAN_PRDS:-$HERE/scan-prds.sh}"
MANIFEST_INVARIANTS="${DISPATCH_MANIFEST_INVARIANTS:-$HERE/manifest-invariants.sh}"
SELECT_TICK="${DISPATCH_SELECT_TICK:-$HERE/select-tick.sh}"
MANIFEST_SET="${DISPATCH_MANIFEST_SET:-$HERE/manifest-set.sh}"
VERDICT_RECEIPTS="${DISPATCH_VERDICT_RECEIPTS:-$HERE/verdict-receipts.sh}"
GATE_DEBT="${DISPATCH_GATE_DEBT:-$HERE/gate-debt.sh}"
LANE_STATUS="${DISPATCH_LANE_STATUS:-$HERE/lane-status.sh}"
SERIALIZATION_DIGEST="${DISPATCH_SERIALIZATION_DIGEST:-$HERE/serialization-digest.sh}"
LAND_CONFLICTS_DIGEST="${DISPATCH_LAND_CONFLICTS_DIGEST:-$HERE/land-conflicts-digest.sh}"
QUOTA_TIER="${DISPATCH_QUOTA_TIER:-$HERE/quota-tier.sh}"
DECISIONS="${DISPATCH_DECISIONS:-$HERE/decisions.sh}"

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
SYSTEMD_RUN="${DISPATCH_SYSTEMD_RUN:-systemd-run}"
SYSTEMCTL="${DISPATCH_SYSTEMCTL:-systemctl}"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"
LANE="${DISPATCH_LANE:-$(hostname)}"
BRANCH_MAX_WALL="${BRANCH_MAX_WALL:-5400}"
POLL_INTERVAL="${DISPATCH_POLL_INTERVAL:-2}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
journal="${DISPATCH_JOURNAL:-$(journal_root)/$(date -u +%F).md}"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
die() { echo "dispatch: $2" >&2; exit "${1:-4}"; }
usage() {
  echo "usage: dispatch.sh [--dry-run] [--pin <slug>[,<slug>...]]" >&2
  echo "       dispatch.sh render <entry.json>" >&2
  exit 2
}

jlog() {
  journal_line "$(printf '%s  dispatch  %s' "$(now_iso)" "$1")"
}

# burst_configured() — same predicate directive 3's burst-lane paragraph
# names: BUILD_BURST_ENABLED=1, or a populated ~/.config/wm-burst/.env.
burst_configured() {
  [ "${BUILD_BURST_ENABLED:-0}" = 1 ] && return 0
  local env_file="${DISPATCH_BURST_ENV:-$HOME/.config/wm-burst/.env}"
  [ -s "$env_file" ] && return 0
  return 1
}

# extract_directive <n> — the text of "## <n>. <title>" through (not
# including) the next "## " heading or EOF, from docs/branch-contract.md.
extract_directive() {
  local n="$1"
  awk -v n="$n" '
    $0 ~ ("^## " n "\\. ") { grab=1 }
    grab && /^## / && $0 !~ ("^## " n "\\. ") { exit }
    grab { print }
  ' "$BRANCH_CONTRACT_MD"
}

# filter_burst_paragraph — strips directive 3's "**Burst-lane PATH —
# ONLY when burst_configured() is true**" sub-paragraph (through its own
# "See history.md#burst-lane." line) unless burst_configured() is true.
filter_burst_paragraph() {
  if burst_configured; then
    cat
  else
    awk '
      /^\*\*Burst-lane PATH/ { skip=1 }
      skip && /^See history\.md#burst-lane\./ { skip=0; next }
      skip { next }
      { print }
    '
  fi
}

# ---------------------------------------------------------------------------
# cmd_render <entry.json> — one branch's self-contained prompt.
# ---------------------------------------------------------------------------
cmd_render() {
  local entry_file="$1"
  [ -r "$entry_file" ] || die 2 "no such entry file: $entry_file"
  [ -r "$BRANCH_CONTRACT_MD" ] || die 2 "missing $BRANCH_CONTRACT_MD"

  local slug path build_target build_into model op_auth shared_target
  slug="$("$JQ" -r '.slug' "$entry_file")"
  path="$("$JQ" -r '.path' "$entry_file")"
  build_target="$("$JQ" -r '.build_target // "unknown"' "$entry_file")"
  build_into="$("$JQ" -r '.build_into // "null"' "$entry_file")"
  model="$("$JQ" -r '.model // "sonnet"' "$entry_file")"
  op_auth="$("$JQ" -c '.operator_authorization // null' "$entry_file")"
  shared_target="$("$JQ" -r '.shared_target // false' "$entry_file")"
  [ -n "$slug" ] && [ "$slug" != "null" ] || die 2 "entry missing slug: $entry_file"
  [ -r "$path" ] || die 2 "missing PRD file for $slug: $path"

  # Landing-pending resume (docs/operator.md's "Resuming a landing-pending
  # PRD" runbook, folded in here so the branch never has to go read that
  # doc itself — self-contained per this file's own header promise).
  local last_step="null"
  if [ -r "$MANIFEST" ]; then
    last_step="$("$JQ" -r --arg s "$slug" '.prds[$s].last_step // "null"' "$MANIFEST" 2>/dev/null || echo null)"
  fi

  echo "You are a /build branch agent for the PRD at $path (slug: $slug)."
  echo
  echo "build_target: $build_target"
  echo "build_into: $build_into"
  echo "lane: $LANE"
  echo "model: $model"
  echo

  if [ "$last_step" = "landing-pending" ]; then
    echo "RESUME, not a normal build phase: this PRD's manifest entry carries"
    echo "last_step=landing-pending. Your ONLY job this dispatch is:"
    echo "  1. From $build_into (the main checkout, never a worktree), run:"
    echo "       scripts/landing-resume.sh $build_into $slug"
    echo "  2. Act on its exit code per that script's own header: 0 (merged+"
    echo "     synced) -> resume this PRD's ordinary post-land steps (gate"
    echo "     --scope main --pinned-landing onward, since --pinned-landing"
    echo "     re-resolves the slug's own merge sha durably from"
    echo "     state/landings/<repo>/$slug.json, not the sha landing-resume.sh"
    echo "     printed); 2 (sync-deferred) or 3 (pending) -> no further action"
    echo "     this dispatch, PRD stays in_progress; 4/5/6 -> already blocked"
    echo "     by landing-resume.sh itself, nothing left to do."
    echo "  3. Directives 8, 9, 10, 12 below still apply to this dispatch."
    echo
  else
    echo "Run Phases 3 -> 4 -> 5 -> 7 for this PRD only. Do not invoke /build"
    echo "recursively. Do not touch any other PRD or any other build_into"
    echo "target except as directive 2's cross-repo-write clause allows."
    echo
  fi

  echo "The following numbered directives (from docs/branch-contract.md) are"
  echo "authoritative for this dispatch. Follow them exactly and verbatim."
  echo

  local n
  for n in 1 2; do
    extract_directive "$n"
    echo
  done

  if [ "$shared_target" = "true" ]; then
    echo "Note: build_into=$build_into is shared by more than one admitted"
    echo "entry this tick — expect land contention; retry per directive 2's"
    echo "land exit codes 4/5 (same worktree/branch), do not escalate."
    echo
  fi

  # Directive 3 (cargo execution): cargo-shaped build_target only.
  case "$build_target" in
    rust-extend|kernel-extend|rust-cli|rust-lib)
      extract_directive 3 | filter_burst_paragraph
      echo
      ;;
  esac

  # Directive 4 (operator-authorization): only when parsed.
  if [ "$op_auth" != "null" ]; then
    extract_directive 4
    echo
    echo "This PRD's parsed operator authorization: $op_auth"
    echo
  fi

  for n in 5 6 7 7a 8 9 10 11 12 13 14; do
    extract_directive "$n"
    echo
  done

  echo "Tag your manifest/journal line with prompt-source=branch-contract and"
  echo "lane=$LANE (per directive 8)."
  echo
  echo "Return a one-line summary per directive 10: \`$slug: <action>"
  echo "<outcome>\`, plus how many steps you chained. If no directive covers"
  echo "an action this PRD's acceptance criteria calls for, return"
  echo "\`outcome=needs-judgment\` (reserved word) with the open question"
  echo "instead of guessing."
  echo
  echo "--- PRD text ($path) ---"
  cat "$path"
}

# ---------------------------------------------------------------------------
# write_dispatch_summary — see header's "Design note on tick-outcome.json".
# ---------------------------------------------------------------------------
write_dispatch_summary() {
  local tick="$1" admitted="$2" dispatched="$3" skipped="$4" reconciled="$5" \
        healed="$6" alarmed="$7" outcome="$8" units_json="$9"
  mkdir -p "$DISPATCH_STATE_DIR"
  local tmp
  tmp="$(mktemp "$DISPATCH_STATE_DIR/.last-tick.XXXXXX")" || return 0
  "$JQ" -n \
    --arg ts "$(now_iso)" --arg tick "$tick" \
    --argjson admitted "$admitted" --argjson dispatched "$dispatched" \
    --argjson skipped "$skipped" --argjson reconciled "$reconciled" \
    --argjson healed "$healed" --argjson alarmed "$alarmed" \
    --arg outcome "$outcome" --argjson units "$units_json" \
    '{ts:$ts, tick:$tick, admitted:$admitted, dispatched:$dispatched,
      skipped:$skipped, reconciled:$reconciled, healed:$healed,
      alarmed:$alarmed, outcome:$outcome, units:$units}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$DISPATCH_STATE_DIR/last-tick.json"
}

# ---------------------------------------------------------------------------
# launch_entry <entry_file> <prompt_file> <tick_dir> <unit_var> -> prints unit
# ---------------------------------------------------------------------------
launch_entry() {
  local entry_file="$1" prompt_file="$2" tick_dir="$3"
  local slug model build_into
  slug="$("$JQ" -r '.slug' "$entry_file")"
  model="$("$JQ" -r '.model // "sonnet"' "$entry_file")"
  build_into="$("$JQ" -r '.build_into // empty' "$entry_file")"
  local lockfile="$STATE_DIR/prd-$slug.lock"
  local unit="build-branch-$slug-$TICK.service"
  local out_file="$tick_dir/$slug.out"
  local wd="${build_into:-$HOME}"
  [ -d "$wd" ] || wd="$HOME"

  local prompt
  prompt="$(cat "$prompt_file")"

  "$SYSTEMD_RUN" --user --unit "$unit" --collect \
    -p WorkingDirectory="$wd" \
    -p StandardOutput="file:$out_file" \
    -p StandardError="file:$out_file" \
    -- flock -n "$lockfile" "$CLAUDE_BIN" -p "$prompt" --model "$model" \
       --dangerously-skip-permissions --output-format text >&2
  local sr_rc=$?

  jlog "$(printf '%s  launched (model=%s unit=%s prompt-source=branch-contract lane=%s)' "$slug" "$model" "$unit" "$LANE")"

  printf '%s\t%s\t%s\t%s\n' "$slug" "$unit" "$model" "$(now_epoch)" >> "$tick_dir/launched.tsv"
  [ "$sr_rc" -eq 0 ] || echo "dispatch: systemd-run failed to launch $unit (rc=$sr_rc)" >&2
  echo "$unit"
}

# ---------------------------------------------------------------------------
# wait_units <tick_dir> — polls every launched unit until it is no longer
# active, enforcing BRANCH_MAX_WALL per-unit; writes tick_dir/units-
# result.json ([{slug,unit,model,rc,outcome}]).
# ---------------------------------------------------------------------------
wait_units() {
  local tick_dir="$1"
  local launched="$tick_dir/launched.tsv"
  [ -r "$launched" ] || { echo "[]" > "$tick_dir/units-result.json"; return 0; }

  local -a pending_slugs=() pending_units=() pending_models=() pending_started=()
  while IFS=$'\t' read -r slug unit model started; do
    [ -n "$slug" ] || continue
    pending_slugs+=("$slug"); pending_units+=("$unit")
    pending_models+=("$model"); pending_started+=("$started")
  done < "$launched"

  local -a results=()
  while [ "${#pending_slugs[@]}" -gt 0 ]; do
    local -a still_slugs=() still_units=() still_models=() still_started=()
    local idx=0
    while [ "$idx" -lt "${#pending_slugs[@]}" ]; do
      local slug="${pending_slugs[$idx]}" unit="${pending_units[$idx]}" \
            model="${pending_models[$idx]}" started="${pending_started[$idx]}"
      local active load
      active="$("$SYSTEMCTL" --user show -p ActiveState --value "$unit" 2>/dev/null)"
      load="$("$SYSTEMCTL" --user show -p LoadState --value "$unit" 2>/dev/null)"
      local elapsed=$(( $(now_epoch) - started ))

      if [ "$elapsed" -gt "$BRANCH_MAX_WALL" ] && { [ "$active" = "active" ] || [ "$active" = "activating" ] || [ "$active" = "reloading" ]; }; then
        "$SYSTEMCTL" --user stop "$unit" >/dev/null 2>&1 || true
        jlog "$(printf '%s  wall-exceeded (unit=%s elapsed=%ss ceiling=%ss lane=%s)' "$slug" "$unit" "$elapsed" "$BRANCH_MAX_WALL" "$LANE")"
        if [ -x "$MANIFEST_SET" ]; then
          local patch; patch="$(mktemp "${TMPDIR:-/tmp}/dispatch.$slug.patch.XXXXXX.json")"
          printf '%s' '{"last_error":"branch-wall-exceeded"}' > "$patch"
          "$MANIFEST_SET" "$slug" "$patch" >/dev/null 2>&1 || true
          rm -f "$patch"
        fi
        results+=("$("$JQ" -n --arg slug "$slug" --arg unit "$unit" --arg model "$model" \
          '{slug:$slug, unit:$unit, model:$model, rc:124, outcome:"branch-wall-exceeded"}')")
        idx=$((idx + 1))
        continue
      fi

      if [ "$active" = "active" ] || [ "$active" = "activating" ] || [ "$active" = "reloading" ]; then
        still_slugs+=("$slug"); still_units+=("$unit")
        still_models+=("$model"); still_started+=("$started")
      else
        local rc
        rc="$("$SYSTEMCTL" --user show -p ExecMainStatus --value "$unit" 2>/dev/null)"
        case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
        local outcome_note="exited"
        [ "$load" = "not-found" ] && outcome_note="collected"
        results+=("$("$JQ" -n --arg slug "$slug" --arg unit "$unit" --arg model "$model" \
          --argjson rc "$rc" --arg note "$outcome_note" \
          '{slug:$slug, unit:$unit, model:$model, rc:$rc, outcome:$note}')")
      fi
      idx=$((idx + 1))
    done
    pending_slugs=("${still_slugs[@]}"); pending_units=("${still_units[@]}")
    pending_models=("${still_models[@]}"); pending_started=("${still_started[@]}")
    [ "${#pending_slugs[@]}" -gt 0 ] && sleep "$POLL_INTERVAL"
  done

  local joined="[]"
  local r
  for r in "${results[@]}"; do
    joined="$(printf '%s' "$joined" | "$JQ" -c --argjson e "$r" '. + [$e]')"
  done
  printf '%s' "$joined" > "$tick_dir/units-result.json"
}

# needs-judgment sweep (P2, requirement 8 / AC9): a branch's captured
# stdout containing the reserved outcome=needs-judgment token opens a
# decisions.sh row and parks the PRD, instead of a script guessing.
handle_needs_judgment() {
  local tick_dir="$1"
  [ -x "$DECISIONS" ] || return 0
  local out
  for out in "$tick_dir"/*.out; do
    [ -r "$out" ] || continue
    grep -q 'outcome=needs-judgment' "$out" 2>/dev/null || continue
    local slug; slug="$(basename "$out" .out)"
    local question
    question="$(grep -m1 'outcome=needs-judgment' "$out" | head -c 300)"
    [ -n "$question" ] || question="$slug: outcome=needs-judgment (no detail captured)"
    "$DECISIONS" open "$question" --owner joe --blocks "$slug" >/dev/null 2>&1 || true
    if [ -x "$MANIFEST_SET" ]; then
      local patch; patch="$(mktemp "${TMPDIR:-/tmp}/dispatch.$slug.patch.XXXXXX.json")"
      printf '%s' '{"status":"needs_classification"}' > "$patch"
      "$MANIFEST_SET" "$slug" "$patch" >/dev/null 2>&1 || true
      rm -f "$patch"
    fi
    jlog "$(printf '%s  needs-judgment (decision-opened lane=%s)' "$slug" "$LANE")"
  done
}

run_parent_steps() {
  local tick="$1" admitted="$2" dispatched="$3" skipped="$4" reconciled="$5" \
        healed="$6" alarmed="$7" units_json="$8"
  [ -x "$MANIFEST_SET" ] && "$MANIFEST_SET" --replay-orphans >/dev/null 2>&1
  [ -x "$VERDICT_RECEIPTS" ] && "$VERDICT_RECEIPTS" postflight "$journal" >/dev/null 2>&1
  [ -x "$GATE_DEBT" ] && "$GATE_DEBT" release-check --prd-dir "$PRD_DIR" --journal "$journal" >/dev/null 2>&1
  # PRD-build-host-contract requirement 3: opts the real tick-summary call
  # into lane-status.sh's own host-contract.sh check (default off there —
  # see its header), so the standing lane-health line carries host=ok or
  # host=drift:<csv> without lane-status-selftest.sh's/cargo-budget-
  # selftest.sh's existing exact-string assertions needing a fixture.
  [ -x "$LANE_STATUS" ] && LANE_STATUS_HOST_CONTRACT_CHECK=1 "$LANE_STATUS" tick-summary "$LANE" "$dispatched" "$skipped" "$journal" >/dev/null 2>&1
  [ -x "$SERIALIZATION_DIGEST" ] && "$SERIALIZATION_DIGEST" "$journal" >/dev/null 2>&1
  [ -x "$LAND_CONFLICTS_DIGEST" ] && "$LAND_CONFLICTS_DIGEST" >/dev/null 2>&1
  write_dispatch_summary "$tick" "$admitted" "$dispatched" "$skipped" \
    "$reconciled" "$healed" "$alarmed" "ok" "$units_json"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  case "${1:-}" in
    render) shift; [ $# -eq 1 ] || usage; cmd_render "$1"; exit $? ;;
    -h|--help) usage ;;
  esac

  local dry_run=0 pin=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --pin) [ $# -ge 2 ] || usage; pin="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  TICK="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local tick_dir="$DISPATCH_STATE_DIR/$TICK"
  mkdir -p "$tick_dir"
  : > "$tick_dir/launched.tsv"

  # Phase 0: verify (never acquire) — tick-run.sh's own fd-9 flock already
  # holds tick.lock for this whole process tree by the time it execs this
  # script as its coordinator (requirement 5). Non-fatal: a selftest may
  # invoke dispatch.sh standalone.
  if [ -x "$TICK_RUN" ]; then
    "$TICK_RUN" --check-held >/dev/null 2>&1 || true
  fi

  # Phase 1: budget rollover has no dedicated script in this checkout yet
  # (not in this PRD's own Engineering target list) — recorded as a no-op
  # here rather than invented out of scope. manifest-reconcile.sh +
  # scan-prds.sh + manifest-invariants.sh, in the contract's order.
  local reconciled=0 healed=0 alarmed=0
  if [ -x "$MANIFEST_RECONCILE" ]; then
    local recon_json
    recon_json="$(PRD_DIR="$PRD_DIR" "$MANIFEST_RECONCILE" --format json 2>/dev/null)" || recon_json='{"reconciled":0}'
    reconciled="$(printf '%s' "$recon_json" | "$JQ" -r '.reconciled // 0' 2>/dev/null)"
    case "$reconciled" in ''|*[!0-9]*) reconciled=0 ;; esac
  fi
  [ -x "$SCAN_PRDS" ] && PRD_DIR="$PRD_DIR" "$SCAN_PRDS" >/dev/null 2>&1
  if [ -x "$MANIFEST_INVARIANTS" ]; then
    local inv_json
    inv_json="$("$MANIFEST_INVARIANTS" --format json --prd-dir "$PRD_DIR" 2>/dev/null)" || inv_json='{"heals":[],"alarms":[]}'
    healed="$(printf '%s' "$inv_json" | "$JQ" -r '(.heals // []) | length' 2>/dev/null)"
    alarmed="$(printf '%s' "$inv_json" | "$JQ" -r '(.alarms // []) | length' 2>/dev/null)"
    case "$healed" in ''|*[!0-9]*) healed=0 ;; esac
    case "$alarmed" in ''|*[!0-9]*) alarmed=0 ;; esac
  fi

  # Phase 2: select-tick.sh -> admitted[].
  local -a select_args=(--format json --prd-dir "$PRD_DIR")
  [ -n "$pin" ] && select_args+=(--pin "$pin")
  local select_out
  select_out="$("$SELECT_TICK" "${select_args[@]}" 2>/dev/null)" \
    || select_out='{"admitted":[],"skipped":[],"pinned":[],"counts":{}}'
  local admitted_count skipped_count
  admitted_count="$(printf '%s' "$select_out" | "$JQ" '.admitted | length')"
  skipped_count="$(printf '%s' "$select_out" | "$JQ" '.skipped | length')"

  # Requirement 7 (P1): quota tier, read before launch — see header note.
  local quota_tier="ok"
  if [ -x "$QUOTA_TIER" ]; then
    quota_tier="$("$QUOTA_TIER" status 2>/dev/null | "$JQ" -r '.tier // "ok"' 2>/dev/null)"
    [ -n "$quota_tier" ] || quota_tier="ok"
  fi
  if [ "$quota_tier" = "paused" ]; then
    write_dispatch_summary "$TICK" "$admitted_count" 0 "$skipped_count" \
      "$reconciled" "$healed" "$alarmed" "skipped:quota" "[]"
    jlog "$(printf 'tick  skipped:quota (admitted=%s reconciled=%s healed=%s alarmed=%s lane=%s)' "$admitted_count" "$reconciled" "$healed" "$alarmed" "$LANE")"
    echo "skipped:quota"
    exit 0
  fi

  if [ "$admitted_count" -eq 0 ]; then
    write_dispatch_summary "$TICK" 0 0 "$skipped_count" "$reconciled" "$healed" "$alarmed" "ok" "[]"
    jlog "$(printf 'tick  admitted=0 dispatched=0 (reconciled=%s healed=%s alarmed=%s lane=%s)' "$reconciled" "$healed" "$alarmed" "$LANE")"
    echo "admitted=0 dispatched=0"
    exit 0
  fi

  local i n
  n="$admitted_count"
  i=0
  while [ "$i" -lt "$n" ]; do
    local entry slug entry_file prompt_file
    entry="$(printf '%s' "$select_out" | "$JQ" -c ".admitted[$i]")"
    slug="$(printf '%s' "$entry" | "$JQ" -r '.slug')"
    entry_file="$tick_dir/$slug.entry.json"
    printf '%s' "$entry" > "$entry_file"
    prompt_file="$tick_dir/$slug.prompt"

    if ! cmd_render "$entry_file" > "$prompt_file" 2>"$tick_dir/$slug.render-err"; then
      echo "dispatch: render failed for $slug (see $tick_dir/$slug.render-err)" >&2
      i=$((i + 1))
      continue
    fi

    if [ "$dry_run" -eq 1 ]; then
      echo "=== $slug (model=$("$JQ" -r '.model' "$entry_file")) ==="
      cat "$prompt_file"
      echo
      i=$((i + 1))
      continue
    fi

    launch_entry "$entry_file" "$prompt_file" "$tick_dir" >/dev/null
    i=$((i + 1))
  done

  [ "$dry_run" -eq 1 ] && exit 0

  wait_units "$tick_dir"
  handle_needs_judgment "$tick_dir"

  local units_json dispatched_count
  units_json="$(cat "$tick_dir/units-result.json" 2>/dev/null || echo '[]')"
  dispatched_count="$(printf '%s' "$units_json" | "$JQ" 'length')"

  run_parent_steps "$TICK" "$admitted_count" "$dispatched_count" "$skipped_count" \
    "$reconciled" "$healed" "$alarmed" "$units_json"

  echo "admitted=$admitted_count dispatched=$dispatched_count"
  exit 0
}

main "$@"
