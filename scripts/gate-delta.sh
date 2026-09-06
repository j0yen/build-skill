#!/usr/bin/env bash
# gate-delta.sh — per-repo blocking-receipt baseline: parse, record, diff.
# PRD-build-gate-delta-baseline.
#
# The ship rule used to be absolute: `autobuilder gate` block=0 or nothing
# ships. On shared repos the gate reports chronic repo-wide blocks that
# predate every individual PRD, so finished work sits `in_progress`
# forever. This script adds a committed per-repo baseline of KNOWN
# blocking receipts (`agent/gate-baseline.json`) so a caller can ship on
# "no NEW blocking receipt vs. baseline" instead of "zero blocking
# receipts" — inherited debt stays visible (named in every verdict) and
# frozen (never auto-widened; only an explicit `record` run changes it).
#
# Subcommands:
#
#   gate-delta.sh parse-blocking <gate-output-file>
#     Parses a captured `autobuilder gate` stdout/stderr blob (the text
#     extend-gate.sh already captures as $gate_out, one receipt per line
#     as printed by autobuilder/src/gate.rs: "  \xe2\x9c\x93 <name>" for a
#     pass, "  \xe2\x9c\x97 <name>[ \xe2\x80\x94 <note>]" for a block) for
#     the blocking ("\xe2\x9c\x97") lines. Prints one "<name>\t<note>" per
#     line, in first-seen order, deduped by name (a name repeated in the
#     same run keeps its first note). <note> is empty when the line had no
#     " \xe2\x80\x94 " suffix.
#
#   gate-delta.sh record <repo> <gate-output-file>
#     Writes <repo>/agent/gate-baseline.json from the blocking set parsed
#     out of <gate-output-file> and prints the same JSON to stdout. This
#     is the ONLY way the baseline changes — deliberately never invoked
#     automatically by a verdict run. The caller (a human, or an explicit
#     `extend-gate.sh <repo> --record-baseline`) is responsible for
#     committing the written file. Exits 0 on a successful write, 2 on a
#     setup error (bad repo path, jq missing). An empty blocking set is a
#     valid, common recording (writes `"receipts": []`).
#
#   gate-delta.sh verdict <repo> <gate-output-file> <gate-rc>
#     Reads ONLY the committed baseline (`git -C <repo> show
#     HEAD:agent/gate-baseline.json`) — an uncommitted working-tree copy
#     never counts, and neither does a missing file or one that isn't
#     valid JSON: all three fail closed to "no baseline". Prints
#     key=value lines to stdout:
#       baseline=present|absent
#       verdict=pass|delta-pass|block
#       new_blocks=<comma-sep names not in the baseline, empty if none>
#       inherited_blocks=<comma-sep names both blocking now AND in the
#                          baseline, empty if none>
#     Exit code: 0 when verdict is pass or delta-pass, 1 when verdict is
#     block. When baseline=absent, verdict/exit code mirror <gate-rc>
#     exactly (pass/0 when <gate-rc> is 0, block/1 otherwise) — a caller
#     that always defers its own exit code to this subcommand's exit code
#     gets today's absolute block-zero behavior, byte-for-byte, whenever
#     there is no committed baseline.
#
# Baseline file schema (agent/gate-baseline.json), schema
# autobuilder.gate_baseline.v1:
#   {
#     "schema": "autobuilder.gate_baseline.v1",
#     "recorded_at": "<rfc3339 UTC>",
#     "head_sha": "<sha this was recorded at — informational, never
#                   compared against on a verdict run: the baseline names
#                   a set of receipts, not a commit>",
#     "receipts": [ {"name": "...", "reason": "..."}, ... ]
#   }
#
# Exit codes (usage/setup errors, all subcommands): 2.

set -uo pipefail

JQ="${JQ:-$(command -v jq || echo /usr/bin/jq)}"

die() { echo "gate-delta: $2" >&2; exit "$1"; }

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[ -x "$JQ" ] || die 2 "jq not found (looked for \$JQ=$JQ)"

# parse_blocking <file> — prints "<name>\t<note>" per blocking receipt,
# first-seen order, deduped by name. Pure bash (no awk/sed multibyte
# arithmetic) so the UTF-8 glyphs compare as opaque byte sequences.
parse_blocking() {
  local file="$1"
  [ -r "$file" ] || die 2 "cannot read $file"
  local -A seen=()
  local line rest name note
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "  ✗ "*)
        rest="${line#  ✗ }"
        case "$rest" in
          *" — "*)
            name="${rest%% — *}"
            note="${rest#* — }"
            ;;
          *)
            name="$rest"
            note=""
            ;;
        esac
        [ -n "${seen[$name]:-}" ] && continue
        seen[$name]=1
        printf '%s\t%s\n' "$name" "$note"
        ;;
    esac
  done < "$file"
}

cmd_parse_blocking() {
  [ $# -eq 1 ] || die 2 "parse-blocking needs exactly one argument: <gate-output-file>"
  parse_blocking "$1"
}

cmd_record() {
  [ $# -eq 2 ] || die 2 "record needs exactly two arguments: <repo> <gate-output-file>"
  local repo_arg="$1" out_file="$2" repo
  repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 2 "no such directory: $repo_arg"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 2 "not a git repo: $repo"
  local head_sha
  head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
  local pairs
  pairs="$(parse_blocking "$out_file")"
  local json
  json="$(printf '%s\n' "$pairs" | "$JQ" -Rn --arg head "$head_sha" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {
      schema: "autobuilder.gate_baseline.v1",
      recorded_at: $now,
      head_sha: $head,
      receipts: [inputs | select(length > 0) | split("\t") | {name: .[0], reason: (.[1] // "")}]
    }
  ')" || die 2 "jq failed to build the baseline document"
  mkdir -p "$repo/agent"
  printf '%s\n' "$json" > "$repo/agent/gate-baseline.json"
  printf '%s\n' "$json"
}

cmd_verdict() {
  [ $# -eq 3 ] || die 2 "verdict needs exactly three arguments: <repo> <gate-output-file> <gate-rc>"
  local repo_arg="$1" out_file="$2" gate_rc="$3" repo
  case "$gate_rc" in ''|*[!0-9]*) die 2 "<gate-rc> must be a non-negative integer, got: $gate_rc" ;; esac
  repo="$(cd "$repo_arg" 2>/dev/null && pwd)" || die 2 "no such directory: $repo_arg"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 2 "not a git repo: $repo"

  local baseline_json=""
  local baseline_present=false
  if baseline_json="$(git -C "$repo" show HEAD:agent/gate-baseline.json 2>/dev/null)" \
    && [ -n "$baseline_json" ] \
    && printf '%s' "$baseline_json" | "$JQ" -e . >/dev/null 2>&1; then
    baseline_present=true
  fi

  local pairs blocking_names
  pairs="$(parse_blocking "$out_file")"
  blocking_names="$(printf '%s\n' "$pairs" | awk -F'\t' 'NF{print $1}')"

  if ! $baseline_present; then
    echo "baseline=absent"
    if [ "$gate_rc" -eq 0 ]; then
      echo "verdict=pass"
      echo "new_blocks="
      echo "inherited_blocks="
      exit 0
    else
      echo "verdict=block"
      echo "new_blocks=$(printf '%s\n' "$blocking_names" | paste -sd, -)"
      echo "inherited_blocks="
      exit 1
    fi
  fi

  echo "baseline=present"
  if [ "$gate_rc" -eq 0 ]; then
    echo "verdict=pass"
    echo "new_blocks="
    echo "inherited_blocks="
    exit 0
  fi

  local baseline_names
  baseline_names="$(printf '%s' "$baseline_json" | "$JQ" -r '.receipts[]?.name // empty')"

  local -a new_blocks=() inherited=()
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if grep -qxF "$n" <<<"$baseline_names"; then
      inherited+=("$n")
    else
      new_blocks+=("$n")
    fi
  done <<<"$blocking_names"

  local new_csv inh_csv
  new_csv="$(IFS=,; echo "${new_blocks[*]:-}")"
  inh_csv="$(IFS=,; echo "${inherited[*]:-}")"

  if [ "${#new_blocks[@]}" -eq 0 ]; then
    echo "verdict=delta-pass"
    echo "new_blocks="
    echo "inherited_blocks=$inh_csv"
    exit 0
  else
    echo "verdict=block"
    echo "new_blocks=$new_csv"
    echo "inherited_blocks=$inh_csv"
    exit 1
  fi
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  parse-blocking) cmd_parse_blocking "$@" ;;
  record)         cmd_record "$@" ;;
  verdict)        cmd_verdict "$@" ;;
  -h|--help)      usage ;;
  *) die 2 "unknown subcommand: $sub (see --help)" ;;
esac
