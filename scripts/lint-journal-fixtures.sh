#!/usr/bin/env bash
# scripts/lint-journal-fixtures.sh — the corpus tripwire's reporting side
# (PRD-build-test-isolation-by-default requirements 2 and 7).
#
# Usage:
#   lint-journal-fixtures.sh --code
#       Fails (exit 1) if any file under scripts/ or tests/, OTHER than
#       scripts/lib/journal.sh itself, defines a function named
#       `journal_line` or `journal_root`, or reassigns BUILD_JOURNAL_ROOT=
#       outright (as opposed to reading it via ${BUILD_JOURNAL_ROOT:-...}).
#       Prints one `file:line` per offense. Exit 0 and "lint-journal-
#       fixtures: 0 private journal_line definitions" when clean.
#   lint-journal-fixtures.sh --corpus [date]
#       Counts fixture-shaped lines (the same regex scripts/lib/journal.sh's
#       tripwire uses) already sitting in the production journals for
#       <date> (default: today, UTC) — the real day file
#       ($HOME/brain/journal/build/<date>.md) plus any burst-lane.log lines
#       whose own leading timestamp starts with <date>. Prints counts
#       grouped by token (the `target=...` value when present, else the
#       `step=ac<N>`/`step=prog*` token, else the matched keyword), then
#       `fixture-lines-total=<n>`. Never edits anything (Non-goals: append-
#       only journals). Exit 0 always (a report, not a gate) — a caller
#       wiring this into manifest-invariants.sh --report reads the printed
#       total itself (requirement 7).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

usage() {
  echo "usage: lint-journal-fixtures.sh --code | --corpus [YYYY-MM-DD]" >&2
  exit 2
}

# ---- --code -----------------------------------------------------------
cmd_code() {
  local lib="$SKILL_DIR/scripts/lib/journal.sh"
  local offenses=0
  local f line

  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    echo "lint-journal-fixtures: private journal_line() definition: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '^[[:space:]]*journal_line[[:space:]]*\(\)' \
             "$SKILL_DIR/scripts" "$SKILL_DIR/tests" 2>/dev/null \
             | grep -v '/lib/journal\.sh:')

  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    echo "lint-journal-fixtures: private journal_root() definition: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '^[[:space:]]*journal_root[[:space:]]*\(\)' \
             "$SKILL_DIR/scripts" "$SKILL_DIR/tests" 2>/dev/null \
             | grep -v '/lib/journal\.sh:')

  # A new script reassigning BUILD_JOURNAL_ROOT= outright (not reading it
  # via ${BUILD_JOURNAL_ROOT:-...}) would silently defeat the one-root
  # contract requirement 1 establishes.
  while IFS=: read -r f line _; do
    [ -z "$f" ] && continue
    [ "$f" = "$lib" ] && continue
    echo "lint-journal-fixtures: journal-root default outside lib/journal.sh: $f:$line"
    offenses=$((offenses + 1))
  done < <(grep -rnE '^[[:space:]]*(export[[:space:]]+)?BUILD_JOURNAL_ROOT=[^$]' \
             "$SKILL_DIR/scripts" "$SKILL_DIR/tests" 2>/dev/null \
             | grep -v '/lib/journal\.sh:' | grep -v '/lib/isolation\.sh:')

  if [ "$offenses" -eq 0 ]; then
    echo "lint-journal-fixtures: 0 private journal_line definitions"
    echo "lint-journal-fixtures: 0 journal-root defaults outside lib/journal.sh"
    return 0
  fi
  return 1
}

# ---- --corpus -----------------------------------------------------------
_fixture_token() {
  # Extracts the grouping token for one fixture-shaped line.
  local line="$1" tok
  tok="$(printf '%s' "$line" | grep -oE 'target=[^ )]+' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  tok="$(printf '%s' "$line" | grep -oE 'step=(ac[0-9][a-z]*|prog[a-zA-Z-]*)' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  tok="$(printf '%s' "$line" | grep -oE 'does-not-matter[-A-Za-z0-9]*' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  tok="$(printf '%s' "$line" | grep -oE '/tmp/[^ )]+' | head -n1)"
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  if printf '%s' "$line" | grep -q 'BURST_LANE_TEST'; then printf 'BURST_LANE_TEST\n'; return 0; fi
  if printf '%s' "$line" | grep -q 'fixture'; then printf 'fixture\n'; return 0; fi
  printf 'fixture-other\n'
}

cmd_corpus() {
  local date="${1:-$(date -u +%F)}"
  local day_file="$HOME/brain/journal/build/$date.md"
  local flat_log="$HOME/brain/journal/build/burst-lane.log"
  # Boundary-anchored /tmp/ branch — same fix as scripts/lib/journal.sh's
  # tripwire (a real /mnt/data/jsy/tmp/burst-prove-* path contains "/tmp/"
  # as a bare substring and must not count as fixture-shaped).
  local regex='((^|[ =(])/tmp/|does-not-matter|fixture|step=(ac[0-9]|prog)|BURST_LANE_TEST)'

  local tmp; tmp="$(mktemp "${TMPDIR:-/mnt/data/jsy/tmp}/lint-journal-fixtures.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  [ -f "$day_file" ] && grep -E "$regex" "$day_file" >> "$tmp" 2>/dev/null
  if [ -f "$flat_log" ]; then
    grep -E "^${date}" "$flat_log" 2>/dev/null | grep -E "$regex" >> "$tmp" 2>/dev/null
  fi

  local total; total="$(wc -l < "$tmp" 2>/dev/null || echo 0)"

  if [ "$total" -eq 0 ]; then
    echo "lint-journal-fixtures: fixture-lines-total=0 (date=$date)"
    return 0
  fi

  local line tok
  local counts_file; counts_file="$(mktemp "${TMPDIR:-/mnt/data/jsy/tmp}/lint-journal-fixtures-tok.XXXXXX")"
  while IFS= read -r line; do
    _fixture_token "$line"
  done < "$tmp" | sort | uniq -c | sort -rn > "$counts_file"

  while read -r count tok; do
    [ -z "$tok" ] && continue
    echo "lint-journal-fixtures: $tok  $count"
  done < "$counts_file"
  rm -f "$counts_file"

  echo "lint-journal-fixtures: fixture-lines-total=$total (date=$date)"
  return 0
}

[ "$#" -ge 1 ] || usage
case "$1" in
  --code) shift; cmd_code ;;
  --corpus) shift; cmd_corpus "${1:-}" ;;
  *) usage ;;
esac
