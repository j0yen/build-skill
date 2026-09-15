#!/usr/bin/env bash
# dream-governor.sh — fires /dream when the queue thins and the budget
# allows, and refuses (never on a default) otherwise (PRD-dream-depth-
# governor). Mirrors claude-build.path's self-triggering pattern for the
# drafting side of the loop: the build side already fires itself when the
# queue is non-empty; nothing refilled the queue until this existed.
#
# Usage:
#   dream-governor.sh check     Evaluate the gates, print `fire` or
#                                `refuse:<gate>=<value>` to stdout, append
#                                one journal line. NEVER launches /dream —
#                                this is the read-only probe (status-line /
#                                cron dry-run consumer).
#   dream-governor.sh run       Same evaluation as `check`; on `fire`,
#                                additionally launches one headless /dream
#                                invocation under `systemd-run --user`
#                                (--wait, RuntimeMaxSec cap), then lints
#                                every PRD it drafted and drops (with a
#                                corrective commit) any that fail
#                                prd-lint.sh, before appending the journal
#                                line. On a refusal, identical to `check`
#                                (no launch).
#   dream-governor.sh status    Print the last journaled decision plus the
#                                CURRENT live gate values. Read-only: never
#                                appends to the journal.
#
# Gates, in evaluation order:
#   config   $DREAM_GOVERNOR_CONFIG must exist and set BOTH DEPTH_MIN and
#            HEADROOM_MAX (KEY=VALUE lines, positive integers) ->
#            refuse:config=absent otherwise. Checked FIRST even though the
#            PRD's requirement list enumerates it 5th: gates `depth` and
#            `headroom` need these thresholds to evaluate at all, so an
#            absent/incomplete config is a precondition failure, not one
#            more gate in a chain that could reach it 5th. Never a
#            default — an absent config always refuses, it never falls
#            back to a hardcoded DEPTH_MIN/HEADROOM_MAX.
#   depth    queued count, from a live `prd-pipeline.sh --json` invocation
#            (PRD-prd-pipeline-telemetry) < DEPTH_MIN ->
#            refuse:depth=<queued>. This call also (re)writes today's
#            telemetry JSON sidecar as its normal side effect, which the
#            `headroom` gate below then reads.
#   seeds    `seed-collect.sh list --pending` (PRD-prd-seed-inbox) has
#            >=1 line -> refuse:seeds=0.
#   headroom today's weighted-token total, read from the telemetry JSON
#            sidecar `depth` just (re)wrote, < HEADROOM_MAX ->
#            refuse:headroom=<value>. A missing sidecar, or a sidecar
#            whose `weighted` field is a non-numeric `na:*` sentinel
#            (token-ledger has no row for today — see DEVIATION below),
#            is refuse:headroom=no-data — fail-closed per the PRD's
#            Migration section, never treated as "headroom is fine."
#   lock     no dream run already live
#            ($DREAM_GOVERNOR_LOCK, flock-based) -> refuse:lock=held.
#            `check` only ever PROBES this (open, try, release — never
#            blocks a live run). `run` probes it here for the journaled
#            value, then takes the REAL, TOCTOU-safe flock immediately
#            before it would otherwise launch (see `cmd_run`).
#   fires_week (P2, optional — only evaluated when $MAX_FIRES_WEEK is set)
#            a second budget belt: refuse:fires_week=<n> once this many
#            `decision=fire`-tagged... journal lines have landed in the
#            trailing 7 days. Unset (default) = no cap, and this gate is
#            simply skipped — it is additive, never required, so it can
#            never explain a refusal in the PRD's own five-gate ACs.
#
# DEVIATION FROM PRD TEXT (documented per this codebase's convention —
# see prd-pipeline.sh's own DEVIATION note): the PRD's requirement 3 reads
# "day's weighted tokens from the telemetry JSON < HEADROOM_MAX" as if the
# sidecar already carried a raw daily-weighted field. As shipped,
# prd-pipeline.sh's --json sidecar only exposed `wtok_per_ship`
# (weighted / shipped) — on a day the governor itself fires drafting
# without anything shipping, that reads `na:no-ships` and would silently
# defeat the exact runaway this gate exists to catch (2026-09-11: one
# session, 2/3 of a week's weighted budget, zero ships). Added a
# `weighted` field to prd-pipeline.sh's `write_json` (additive; no
# existing key renamed or removed; no selftest asserts a closed key set —
# verified via `tests/pipeline_*` before landing) so this gate reads the
# real per-day total. The `na:no-ledger` sentinel (no ledger row yet for
# today) is treated identically to a wholly-absent sidecar: both mean "no
# usable headroom data," which is exactly the fail-closed case the PRD's
# Migration section calls out for this gate specifically (and only this
# gate — `depth` has no such sentinel because it is always computable
# straight from build-queue/*.md, no ledger dependency).
#
# Journal: one line per `check`/`run` decision, ALWAYS carrying all five
# (six, when MAX_FIRES_WEEK is set) gate values regardless of which gate
# decided it — $DREAM_GOVERNOR_JOURNAL (default
# ~/brain/journal/dream-governor.log; deliberately its OWN file, not the
# shared ~/brain/journal/build/<date>.md, per the PRD's Technical
# Considerations: "writes only journal + dream run's own outputs").
#
# Env (testable overrides, same convention as prd-pipeline.sh / burst-lane.sh):
#   BUILD_SKILL_DIR              skill root (default: this script's parent dir)
#   BUILD_STATE_DIR              state dir (default $BUILD_SKILL_DIR/state)
#   DREAM_GOVERNOR_PRDS_DIR      PRDs clone (default ~/Documents/PRDs);
#                                forwarded to prd-pipeline.sh / seed-collect.sh
#                                as PRD_PIPELINE_PRDS_DIR / SEED_PRD_DIR.
#   DREAM_GOVERNOR_CONFIG        config file (default
#                                $BUILD_STATE_DIR/dream-governor/config)
#   DREAM_GOVERNOR_JOURNAL       decision journal (default
#                                ~/brain/journal/dream-governor.log)
#   DREAM_GOVERNOR_LOCK          lockfile (default
#                                $BUILD_STATE_DIR/dream-governor/run.lock)
#   DREAM_GOVERNOR_TIMEOUT_S     systemd-run RuntimeMaxSec cap for `run`'s
#                                dream launch (default 3600)
#   DREAM_GOVERNOR_CLAUDE_BIN    coordinator binary (default `claude`)
#   DREAM_GOVERNOR_DREAM_ARGS    the slash-command text passed as ONE `-p`
#                                argument to the coordinator (default
#                                `/dream`) — used to build the default
#                                launch command `$CLAUDE_BIN -p "$DREAM_ARGS"`.
#   DREAM_GOVERNOR_DREAM_CMD     when SET, replaces the default launch
#                                command entirely (space-split — no
#                                complex-quoting support; for selftests to
#                                substitute a stub script, not for a
#                                slash-command string with embedded spaces).
#   DREAM_GOVERNOR_TOKEN_LEDGER_DIR  forwarded to prd-pipeline.sh as
#                                TOKEN_LEDGER_STATE_DIR when set (test
#                                isolation only; unset = prd-pipeline.sh's
#                                own default).
#   DREAM_GOVERNOR_PRD_PIPELINE  prd-pipeline.sh path override (default
#                                sibling script)
#   DREAM_GOVERNOR_SEED_COLLECT  seed-collect.sh path override (default
#                                sibling script)
#   DREAM_GOVERNOR_PRD_LINT      prd-lint.sh path override (default
#                                sibling script)
#   MAX_FIRES_WEEK               P2 weekly firing cap (optional; unset =
#                                no cap, gate skipped)
#
# Exit: 0 for check/status/run in every case (the decision — fire or a
#       refusal — is the stdout token, not the exit code; a refusal is a
#       successful, correct outcome) | 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
PRDS_DIR="${DREAM_GOVERNOR_PRDS_DIR:-$HOME/Documents/PRDs}"
CONFIG_FILE="${DREAM_GOVERNOR_CONFIG:-$STATE_DIR/dream-governor/config}"
JOURNAL="${DREAM_GOVERNOR_JOURNAL:-$HOME/brain/journal/dream-governor.log}"
LOCKFILE="${DREAM_GOVERNOR_LOCK:-$STATE_DIR/dream-governor/run.lock}"
TIMEOUT_S="${DREAM_GOVERNOR_TIMEOUT_S:-3600}"
CLAUDE_BIN="${DREAM_GOVERNOR_CLAUDE_BIN:-claude}"
DREAM_ARGS="${DREAM_GOVERNOR_DREAM_ARGS:-/dream}"
PRD_PIPELINE_BIN="${DREAM_GOVERNOR_PRD_PIPELINE:-$HERE/prd-pipeline.sh}"
SEED_COLLECT_BIN="${DREAM_GOVERNOR_SEED_COLLECT:-$HERE/seed-collect.sh}"
PRD_LINT_BIN="${DREAM_GOVERNOR_PRD_LINT:-$HERE/prd-lint.sh}"
MAX_FIRES_WEEK="${MAX_FIRES_WEEK:-}"

usage() {
  echo "usage: dream-governor.sh check|run|status" >&2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# journal_line is now the shared scripts/lib/journal.sh one (sourced
# above); this script's own $JOURNAL (dream-governor.log, or
# DREAM_GOVERNOR_JOURNAL override) is an absolute --file target on every
# call site below (PRD-build-test-isolation-by-default).

# load_config -> sets DEPTH_MIN / HEADROOM_MAX; returns 0 iff both are
# present, non-empty positive integers. A file that sets only one of the
# two is treated the same as no file at all (config=absent), per the
# PRD's "absent config is a refusal, not a default."
load_config() {
  DEPTH_MIN=""; HEADROOM_MAX=""
  [ -f "$CONFIG_FILE" ] || return 1
  local v
  v="$(grep -E '^DEPTH_MIN=[0-9]+[[:space:]]*$' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
  [ -n "$v" ] && DEPTH_MIN="$v"
  v="$(grep -E '^HEADROOM_MAX=[0-9]+[[:space:]]*$' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
  [ -n "$v" ] && HEADROOM_MAX="$v"
  [ -n "$DEPTH_MIN" ] && [ -n "$HEADROOM_MAX" ]
}

# gate_depth -> sets DEPTH_QUEUED. Always computable (a straight
# build-queue/*.md scan inside prd-pipeline.sh) — no ledger dependency,
# no no-data case.
gate_depth() {
  local out q
  local -a assign=(PRD_PIPELINE_PRDS_DIR="$PRDS_DIR" BUILD_STATE_DIR="$STATE_DIR")
  [ -n "${DREAM_GOVERNOR_TOKEN_LEDGER_DIR:-}" ] && assign+=(TOKEN_LEDGER_STATE_DIR="$DREAM_GOVERNOR_TOKEN_LEDGER_DIR")
  out="$(env "${assign[@]}" "$PRD_PIPELINE_BIN" --json 2>/dev/null)"
  q="$(printf '%s\n' "$out" | grep -oE 'queued=[0-9]+' | head -1 | cut -d= -f2)"
  DEPTH_QUEUED="${q:-0}"
}

# gate_seeds -> sets SEEDS_COUNT (pending seed count in the inbox).
gate_seeds() {
  local n
  n="$(env SEED_PRD_DIR="$PRDS_DIR" "$SEED_COLLECT_BIN" list --pending 2>/dev/null | grep -c '.')"
  SEEDS_COUNT="${n:-0}"
}

# gate_headroom -> sets HEADROOM_VALUE to an integer or the literal
# string "no-data". Reads today's telemetry sidecar that gate_depth's
# --json call just (re)wrote.
gate_headroom() {
  local d f
  d="$(date -u +%F)"
  f="$STATE_DIR/prd-pipeline/$d.json"
  if [ ! -f "$f" ]; then HEADROOM_VALUE="no-data"; return; fi
  HEADROOM_VALUE="$(python3 - "$f" <<'PY'
import json, sys
try:
    obj = json.load(open(sys.argv[1]))
    w = obj.get("weighted")
except Exception:
    print("no-data")
    sys.exit(0)
if isinstance(w, (int, float)) and not isinstance(w, bool):
    print(int(w))
else:
    print("no-data")
PY
)"
}

# lock_probe -> prints "free" or "held". Non-blocking, non-owning: opens,
# tries, releases immediately. Safe to call from `check` (never holds
# the lock) and as the FIRST, non-authoritative read for `run` (which
# takes the real, TOCTOU-safe flock separately right before launching).
lock_probe() {
  mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null
  if ! exec 8>"$LOCKFILE" 2>/dev/null; then
    echo held
    return
  fi
  if flock -n 8 2>/dev/null; then
    flock -u 8
    exec 8>&-
    echo free
  else
    exec 8>&-
    echo held
  fi
}

# acquire_lock_real -> attempts the REAL flock on fd 9, held for the rest
# of this process. Returns flock's own exit code (0 acquired, nonzero
# held-by-someone-else). This is the authoritative gate 4 check for `run`.
acquire_lock_real() {
  mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null
  exec 9>"$LOCKFILE" 2>/dev/null || return 1
  flock -n 9
}

# fires_this_week -> count of bare-`fire`-outcome lines (never a
# `refuse:*`) in the journal within the trailing 7 days. build_decision_line
# always separates fields with exactly two spaces, so "  fire  (" is an
# unambiguous marker for a fire decision (a refuse:* value never matches
# it — "refuse:fires_week=" etc. never equals the bare token "fire").
fires_this_week() {
  local cutoff ts epoch n=0
  [ -f "$JOURNAL" ] || { echo 0; return; }
  cutoff="$(date -u -d '7 days ago' +%s)"
  while IFS= read -r ts; do
    epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || continue
    [ -n "$epoch" ] && [ "$epoch" -ge "$cutoff" ] && n=$((n + 1))
  done < <(grep -F '  fire  (' "$JOURNAL" 2>/dev/null | awk '{print $1}')
  echo "$n"
}

# evaluate -> read-only. Computes every gate value (always — so the
# journal line always carries all five/six, per the PRD requirement) and
# sets DECISION to "fire" or the first-encountered "refuse:<gate>=<value>"
# in gate order. Sets globals: G_CONFIG G_DEPTH G_SEEDS G_HEADROOM G_LOCK
# [G_FIRES] DECISION.
evaluate() {
  DECISION=""

  if load_config; then G_CONFIG="present"; else G_CONFIG="absent"; fi
  [ "$G_CONFIG" = "absent" ] && DECISION="refuse:config=absent"

  gate_depth
  G_DEPTH="$DEPTH_QUEUED"
  if [ -z "$DECISION" ] && [ -n "$DEPTH_MIN" ] && is_int "$G_DEPTH" && [ "$G_DEPTH" -ge "$DEPTH_MIN" ]; then
    DECISION="refuse:depth=$G_DEPTH"
  fi

  gate_seeds
  G_SEEDS="$SEEDS_COUNT"
  if [ -z "$DECISION" ] && [ "$G_SEEDS" -eq 0 ]; then
    DECISION="refuse:seeds=0"
  fi

  gate_headroom
  G_HEADROOM="$HEADROOM_VALUE"
  if [ -z "$DECISION" ]; then
    if [ "$G_HEADROOM" = "no-data" ]; then
      DECISION="refuse:headroom=no-data"
    elif [ -n "$HEADROOM_MAX" ] && is_int "$G_HEADROOM" && [ "$G_HEADROOM" -ge "$HEADROOM_MAX" ]; then
      DECISION="refuse:headroom=$G_HEADROOM"
    fi
  fi

  G_LOCK="$(lock_probe)"
  if [ -z "$DECISION" ] && [ "$G_LOCK" = "held" ]; then
    DECISION="refuse:lock=held"
  fi

  if [ -z "$DECISION" ] && [ -n "$MAX_FIRES_WEEK" ] && is_int "$MAX_FIRES_WEEK"; then
    G_FIRES="$(fires_this_week)"
    if [ "$G_FIRES" -ge "$MAX_FIRES_WEEK" ]; then
      DECISION="refuse:fires_week=$G_FIRES"
    fi
  fi

  [ -z "$DECISION" ] && DECISION="fire"
}

build_decision_line() {
  local cmd="$1" line
  line="$(now_iso)  dream-governor  $cmd  $DECISION  (depth=$G_DEPTH seeds=$G_SEEDS headroom=$G_HEADROOM lock=$G_LOCK config=$G_CONFIG"
  [ -n "${G_FIRES:-}" ] && line="$line fires_week=$G_FIRES"
  [ -n "${EXTRA:-}" ] && line="$line $EXTRA"
  line="$line)"
  printf '%s' "$line"
}

# launch_and_postprocess -> runs on `fire` only, lock already held (fd 9).
# Sets EXTRA (appended to the journal line: dream_run/drafted/lint
# counts/slugs).
launch_and_postprocess() {
  local pre_head unit_name run_log
  local -a cmd_arr drafted=() slugs=()
  local f lint_out lint_rc pass=0 fail=0

  pre_head="$(git -C "$PRDS_DIR" rev-parse HEAD 2>/dev/null || echo none)"
  unit_name="dream-governor-run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$STATE_DIR/dream-governor"
  run_log="$STATE_DIR/dream-governor/$unit_name.log"

  if [ -n "${DREAM_GOVERNOR_DREAM_CMD:-}" ]; then
    # shellcheck disable=SC2206 -- documented: stub/selftest commands
    # only, never a slash-command string with embedded spaces (that path
    # uses DREAM_ARGS below, passed as one -p argument, not split).
    cmd_arr=( $DREAM_GOVERNOR_DREAM_CMD )
  else
    cmd_arr=( "$CLAUDE_BIN" -p "$DREAM_ARGS" )
  fi

  systemd-run --user --unit="$unit_name" --collect --quiet --wait \
    -p "RuntimeMaxSec=$TIMEOUT_S" -p "WorkingDirectory=$PRDS_DIR" \
    -p "StandardOutput=append:$run_log" -p "StandardError=append:$run_log" \
    --setenv=HOME="$HOME" \
    -- "${cmd_arr[@]}" >>"$run_log" 2>&1
  # dream run's own exit code isn't otherwise actioned here: a defective
  # drafted PRD is caught by the lint pass below regardless of how the
  # run itself exited (a partial-then-killed run may still have committed
  # something worth linting).

  if [ "$pre_head" != "none" ] && git -C "$PRDS_DIR" rev-parse HEAD >/dev/null 2>&1; then
    while IFS= read -r f; do
      [ -n "$f" ] && drafted+=("$f")
    done < <(git -C "$PRDS_DIR" log --name-only --diff-filter=A --pretty=format: \
                "$pre_head..HEAD" -- 'build-queue/PRD-*.md' 2>/dev/null | sort -u)
  fi

  for f in "${drafted[@]:-}"; do
    [ -n "$f" ] || continue
    lint_out="$("$PRD_LINT_BIN" --quiet "$PRDS_DIR/$f" 2>&1)"
    lint_rc=$?
    if [ "$lint_rc" -ne 0 ]; then
      fail=$((fail + 1))
      journal_line --file "$JOURNAL" "$(now_iso)  dream-governor  lint-fail  file=$f  ($(printf '%s' "$lint_out" | tr '\n' ' '))"
      ( cd "$PRDS_DIR" \
        && git rm -q -- "$f" \
        && git commit -q -m "dream-governor: drop $f (failed prd-lint post-run)" -- "$f" ) \
        || journal_line --file "$JOURNAL" "$(now_iso)  dream-governor  lint-fail-revert-error  file=$f"
      if git -C "$PRDS_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$PRDS_DIR" push -q 2>>"$run_log" || true
      fi
    else
      pass=$((pass + 1))
      slugs+=("$(basename "$f" .md)")
    fi
  done

  EXTRA="dream_run=$unit_name drafted=${#drafted[@]} lint_pass=$pass lint_fail=$fail"
  if [ "${#slugs[@]}" -gt 0 ]; then
    local joined; joined="$(IFS=,; echo "${slugs[*]}")"
    EXTRA="$EXTRA slugs=$joined"
  fi
}

cmd_check() {
  evaluate
  journal_line --file "$JOURNAL" "$(build_decision_line check)"
  echo "$DECISION"
}

cmd_run() {
  evaluate
  if [ "$DECISION" = "fire" ]; then
    if acquire_lock_real; then
      launch_and_postprocess
      flock -u 9 2>/dev/null || true
      exec 9>&- 2>/dev/null || true
      rm -f "$LOCKFILE" 2>/dev/null || true
    else
      DECISION="refuse:lock=held"
      G_LOCK="held"
    fi
  fi
  journal_line --file "$JOURNAL" "$(build_decision_line run)"
  echo "$DECISION"
}

cmd_status() {
  if [ -f "$JOURNAL" ]; then
    echo "last: $(tail -1 "$JOURNAL")"
  else
    echo "last: no decisions recorded yet"
  fi
  evaluate
  echo "current: depth=$G_DEPTH seeds=$G_SEEDS headroom=$G_HEADROOM lock=$G_LOCK config=$G_CONFIG"
}

cmd="${1:-}"
[ $# -ge 1 ] && shift
case "$cmd" in
  check) cmd_check ;;
  run) cmd_run ;;
  status) cmd_status ;;
  -h|--help) usage; exit 2 ;;
  *) echo "dream-governor.sh: unknown subcommand: $cmd" >&2; usage >&2; exit 2 ;;
esac
