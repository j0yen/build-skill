#!/usr/bin/env bash
# scripts/lib/journal.sh — the one journal_line and the one root, shared by
# every build-skill script that journals (PRD-build-test-isolation-by-default).
#
# Source this; never execute it. Was six private `journal_line()` copies
# (burst-lane.sh, gate-burst.sh, gate-wedge.sh, dream-governor.sh,
# gate-debt.sh, mark-needs-classification.sh), seven journal env names, and
# an isolation guard that only some tests remembered to arm. On 2026-09-15
# that let ~840 fixture-shaped lines from `/tmp` test targets land in the
# real production journal and nearly turn a 1-wide canary into a reported
# 2-wide one (Grounding, PRD-build-test-isolation-by-default).
#
# API:
#   journal_root()                      -> the directory today's journal lives under
#   journal_line <text>                 -> append "<text>\n" to $(journal_root)/$(date -u +%F).md
#   journal_line --file <name> <text>   -> append to $(journal_root)/<name> (named logs, e.g. burst-lane.log)
#
# journal_root() honors exactly one knob, BUILD_JOURNAL_ROOT, defaulting to
# the real production journal directory ($HOME/brain/journal/build) only
# when BUILD_JOURNAL_ROOT is unset (requirement 1).
#
# Legacy aliases (requirement 1, one release only): when BUILD_JOURNAL_ROOT
# is unset but one of the seven old per-script env names below is, that
# name's value is honored directly as the write target, and a one-time
# `journal  legacy-env  (name=<NAME>)` notice is appended to that same
# target the first time this process sees it set. FILE-valued names name
# the exact file historically written (burst-lane.log / the day's .md
# file); DIR-valued names name a directory, date-stamped the same way the
# production default is.
#   BURST_LANE_JOURNAL    file   (was burst-lane.sh's own JOURNAL, burst-lane.log)
#   GATE_WEDGE_JOURNAL    file   (was gate-wedge.sh's own JOURNAL, <date>.md)
#   SELECT_GUARD_JOURNAL  file   (was select-guard.sh's own journal var)
#   CARGO_BUDGET_JOURNAL  file   (was cargo-budget.sh's own jf)
#   TICK_RUN_JOURNAL      file   (was tick-run.sh's own JOURNAL, <date>.md)
#   GATE_LAUNCH_JOURNAL   file   (was gate-launch.sh's own journal var)
#   EXTEND_GATE_JOURNAL   file   (was extend-gate.sh's own journal var)
#   JOURNAL_DIR           dir
#   BUILD_JOURNAL_DIR      dir
#   TICK_JOURNAL_DIR       dir
#
# TICK_RUN_JOURNAL/GATE_LAUNCH_JOURNAL/EXTEND_GATE_JOURNAL added by
# PRD-build-journal-single-writer requirement 1 — same shape as
# SELECT_GUARD_JOURNAL above, generalized to all five direct writers so
# the wide existing selftest suite that already isolates via these names
# keeps working unchanged once the writers route through journal_line.
#
# Tripwire (requirement 3): a write that would otherwise land at the
# UNMODIFIED production default (no BUILD_JOURNAL_ROOT, no legacy alias
# active) whose text is fixture-shaped — `/tmp/`, `does-not-matter`,
# `fixture`, `step=ac<N>` / `step=prog*`, or `BURST_LANE_TEST` — is refused:
# nothing is appended, `journal: refused fixture-shaped line to production
# root: <text>` goes to stderr, and journal_line returns 3. A test whose
# isolation override didn't take effect fails loudly instead of polluting
# the evidence journal. `BUILD_TEST_ALLOW_PROD=1` is the documented,
# itself-journaled escape hatch (scripts/lib/isolation.sh; Goals) for the
# rare case a fixture must legitimately target the production root.

_JOURNAL_LEGACY_FILE_VARS="BURST_LANE_JOURNAL GATE_WEDGE_JOURNAL SELECT_GUARD_JOURNAL CARGO_BUDGET_JOURNAL TICK_RUN_JOURNAL GATE_LAUNCH_JOURNAL EXTEND_GATE_JOURNAL"
_JOURNAL_LEGACY_DIR_VARS="JOURNAL_DIR BUILD_JOURNAL_DIR TICK_JOURNAL_DIR"

journal_root() {
  printf '%s\n' "${BUILD_JOURNAL_ROOT:-$HOME/brain/journal/build}"
}

# _journal_legacy_active_name -> the first legacy env var that is set and
# non-empty (checked in the order documented above), or empty if none is.
# Never consulted when BUILD_JOURNAL_ROOT itself is set — that always wins.
_journal_legacy_active_name() {
  [ -n "${BUILD_JOURNAL_ROOT:-}" ] && return 0
  local name
  # Local, default-whitespace IFS — a caller further up the stack (e.g.
  # select-guard.sh's `local IFS=','` still in scope across its own
  # journal_line call) must never make this unquoted word-split treat the
  # whole space-separated list as one name. Verified live: without this,
  # select-guard-same-target-cap-selftest.sh's IFS=',' scope broke this
  # exact loop with "invalid variable name".
  local IFS=$' \t\n'
  for name in $_JOURNAL_LEGACY_FILE_VARS $_JOURNAL_LEGACY_DIR_VARS; do
    if [ -n "${!name:-}" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 0
}

# _journal_legacy_target <name> -> the file journal_line appends to for
# that legacy var.
_journal_legacy_target() {
  local name="$1" val="${!1}"
  case " $_JOURNAL_LEGACY_FILE_VARS " in
    *" $name "*) printf '%s\n' "$val" ;;
    *) printf '%s\n' "$val/$(date -u +%F).md" ;;
  esac
}

_JOURNAL_LEGACY_NOTICED="${_JOURNAL_LEGACY_NOTICED:-}"

# _journal_legacy_notice_once <name> <target> — writes the one-time
# `journal  legacy-env  (name=<NAME>)` line to <target>, at most once per
# process per legacy name.
_journal_legacy_notice_once() {
  local name="$1" target="$2"
  case ",${_JOURNAL_LEGACY_NOTICED}," in
    *",$name,"*) return 0 ;;
  esac
  _JOURNAL_LEGACY_NOTICED="${_JOURNAL_LEGACY_NOTICED:+$_JOURNAL_LEGACY_NOTICED,}$name"
  export _JOURNAL_LEGACY_NOTICED
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  printf '%s  journal  legacy-env  (name=%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" >> "$target" 2>/dev/null || true
}

# _journal_is_fixture_shaped <text> -> true (0) iff text matches
# requirement 3's regex. The `/tmp/` branch is boundary-anchored
# (start-of-string or preceded by whitespace/=/() rather than a bare
# substring match — a real routed run's `/mnt/data/jsy/tmp/burst-prove-*`
# path CONTAINS the literal substring "/tmp/" (".../jsy/tmp/...") and is
# exactly the real line Technical considerations warns this must not
# refuse; verified against the actual 2026-09-15 burst-lane.log, which had
# 28 such false positives under a naive substring match before this fix.
_journal_is_fixture_shaped() {
  [[ "$1" =~ (^|[[:space:]=\(])/tmp/ ]] && return 0
  [[ "$1" =~ (does-not-matter|fixture|step=(ac[0-9]|prog)|BURST_LANE_TEST) ]]
}

# journal_line [--file <name-or-absolute-path>] <text>
#
# --file with a relative name joins journal_root() (the burst-lane.log
# convention). --file with an absolute path (a script-resolved override
# chain the seven legacy names don't cover, e.g. dream-governor.sh's own
# DREAM_GOVERNOR_JOURNAL) is used as-is — the caller already resolved its
# own default-vs-override. An explicit --file ALWAYS wins over legacy-name
# detection below: legacy env detection is purely environment-based (any
# of the seven names being set ANYWHERE in the process), so without this
# ordering, one script's unrelated legacy var (e.g. a test exporting
# BURST_LANE_JOURNAL for burst-lane.sh) could silently hijack a DIFFERENT
# script's own explicitly-resolved --file target (e.g. gate-burst.sh's
# GATE_BURST_JOURNAL) — verified via tests/gate_burst_ac12 failing under
# exactly that env combination before this ordering fix.
journal_line() {
  local named=""
  if [ "${1:-}" = "--file" ]; then
    named="${2:-}"
    shift 2
  fi
  local text="${1:-}"

  local legacy_name="" target

  if [ -n "$named" ]; then
    case "$named" in
      /*) target="$named" ;;
      *) target="$(journal_root)/$named" ;;
    esac
  else
    legacy_name="$(_journal_legacy_active_name)"
    if [ -n "$legacy_name" ]; then
      target="$(_journal_legacy_target "$legacy_name")"
      _journal_legacy_notice_once "$legacy_name" "$target"
    else
      target="$(journal_root)/$(date -u +%F).md"
    fi
  fi

  # is_production: true only for a write that, with NO override in play
  # anywhere in the chain (no BUILD_JOURNAL_ROOT, no legacy alias, no
  # BUILD_TEST=1 structural override), still resolves under the real
  # production evidence tree ($HOME/brain). Path-based rather than
  # journal_root()-equality so it also covers named absolute targets like
  # dream-governor.log, not just the day-stamped default.
  local is_production=0
  if [ -z "$legacy_name" ] && [ -z "${BUILD_JOURNAL_ROOT:-}" ] && [ "${BUILD_TEST:-0}" != "1" ]; then
    case "$target" in
      "$HOME"/brain/*) is_production=1 ;;
    esac
  fi

  if [ "$is_production" = "1" ] && [ "${BUILD_TEST_ALLOW_PROD:-0}" != "1" ] && _journal_is_fixture_shaped "$text"; then
    echo "journal: refused fixture-shaped line to production root: $text" >&2
    return 3
  fi

  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  printf '%s\n' "$text" >> "$target" 2>/dev/null || true
  return 0
}
