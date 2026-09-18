#!/usr/bin/env bash
# live-ac-ruling.sh — durable record of an operator's `(Live` AC pairing
# ruling (PRD-build-inherited-blocks-delta-pass, ship path 2026-09-18).
#
# Why this exists. A `(Live` AC pairs only with the evidence its own text
# names — a regex over the real journal (verified-completed.sh rule h).
# That is the right default: it is what stops a loop-tooling PRD from
# declaring a live outcome proven by a unit test. But an evidence clause
# can be made unmatchable by a defect in a component the PRD does not own.
# Worked example, and the reason this script exists: this PRD's AC6 asks
# for `<slug>  delta-pass` in the journal's OUTCOME slot; extend-gate.sh's
# gate-infra-outcome override relabels that slot `incomplete`, so the
# computed verdict only ever reaches the journal as the in-parens
# `verdict=delta-pass` token. The live behaviour AC6 demands DID happen;
# the clause still cannot match, and editing the clause to match would be
# weakening the AC after the fact.
#
# The operator's answer to that is a ruling: "this AC is paired, against
# this equivalent evidence, because X." Before this script that ruling was
# a sentence in a chat log — no archive path could execute it, so the PRD
# sat `built` (never `shipped`) and live-ac-reality-check.sh eventually
# opened an operator decision for a question the operator had already
# answered. A ruling recorded here is read by verified-completed.sh, hence
# by every consumer of it (archive-live-ac-refusal.sh,
# live-ac-reality-check.sh, the branch agent's own archive step) with no
# per-caller flag to remember and no way to apply it to one caller only.
#
# It is deliberately NOT a general override: verified-completed.sh
# consults a ruling only AFTER the AC's own derived evidence has already
# failed to match, only for an AC the PRD text tagged `(Live`, and only
# when the row is complete (evidence + ruled_by + ruled_at). Every pairing
# it produces is announced on stderr and carries the rule name
# `live-operator-ruling:<who>@<when>` into the trailer, so it is never
# mistaken for a derived pairing.
#
# Usage:
#   live-ac-ruling.sh record <slug> --ac <N> --evidence <text>
#                      --ruled-by <who> [--ruled-at <ISO>] [--note <text>]
#       Upserts the ruling for (slug, AC N). Re-recording the same AC
#       replaces that AC's row and leaves every other AC's row alone.
#       --ruled-at defaults to now. Exit 0 on write, 2 on usage error.
#
#   live-ac-ruling.sh show <slug> [--ac <N>]
#       Prints the slug's rulings as JSON (one object when --ac is given).
#       Exit 0 when at least one matching ruling exists, 1 when none.
#
#   live-ac-ruling.sh list
#       One `<slug>  AC<n>  <ruled_by>  <ruled_at>` line per recorded
#       ruling, oldest file first. Exit 0 always (empty output when none).
#
# Env:
#   LIVE_AC_RULINGS_DIR   default ${BUILD_STATE_DIR:-<skill>/state}/live-ac-rulings.
#                         Same default expression verified-completed.sh
#                         uses, so a worktree selftest that exports
#                         BUILD_STATE_DIR moves both ends together.
#
# Exit codes:
#   0  recorded / found.
#   1  `show` found no matching ruling.
#   2  usage error, or an evidence/ruled_by string carrying a character
#      the classify_ac pipe-delimited protocol cannot survive (`|`, tab,
#      newline) — rejected at write time rather than corrupting a
#      classification line at read time.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"
RULINGS_DIR="${LIVE_AC_RULINGS_DIR:-${BUILD_STATE_DIR:-$SKILL_DIR/state}/live-ac-rulings}"

die() { printf 'live-ac-ruling: %s\n' "$*" >&2; exit "${2:-2}"; }
usage() { sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

[ -x "$JQ" ] || die "jq not at $JQ"
[ "$#" -ge 1 ] || usage
cmd="$1"; shift

# reject_control <label> <value> — the classification protocol inside
# verified-completed.sh is `CLASS|rule|path|other` read with IFS='|', and
# the evidence string is emitted in the `path` field. A pipe, tab or
# newline in it would silently shift every later field, so it is refused
# here (at write time, once) rather than discovered as a mis-parsed
# trailer later.
reject_control() {
  local label="$1" val="$2"
  case "$val" in
    *'|'*) die "$label may not contain '|' (verified-completed.sh parses classifications with IFS='|')" ;;
    *$'\t'*) die "$label may not contain a tab (the ruling is read back as a tab-separated triple)" ;;
    *$'\n'*) die "$label may not contain a newline" ;;
  esac
}

case "$cmd" in
  record)
    slug="${1:-}"; [ -n "$slug" ] && shift || die "record needs a <slug>"
    case "$slug" in -*) die "record needs a <slug> before its flags" ;; esac
    ac=""; evidence=""; ruled_by=""; ruled_at=""; note=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --ac) ac="${2:-}"; shift 2 ;;
        --ac=*) ac="${1#--ac=}"; shift ;;
        --evidence) evidence="${2:-}"; shift 2 ;;
        --evidence=*) evidence="${1#--evidence=}"; shift ;;
        --ruled-by) ruled_by="${2:-}"; shift 2 ;;
        --ruled-by=*) ruled_by="${1#--ruled-by=}"; shift ;;
        --ruled-at) ruled_at="${2:-}"; shift 2 ;;
        --ruled-at=*) ruled_at="${1#--ruled-at=}"; shift ;;
        --note) note="${2:-}"; shift 2 ;;
        --note=*) note="${1#--note=}"; shift ;;
        -h|--help) usage ;;
        *) die "record: unknown argument '$1'" ;;
      esac
    done
    case "$ac" in ''|*[!0-9]*) die "--ac must be a positive AC number (got '$ac')" ;; esac
    [ "$ac" -ge 1 ] || die "--ac must be >= 1"
    [ -n "$evidence" ] || die "--evidence is required: name the real line/receipt the ruling pairs against"
    [ -n "$ruled_by" ] || die "--ruled-by is required: a ruling with no author is not a ruling"
    reject_control "--evidence" "$evidence"
    reject_control "--ruled-by" "$ruled_by"
    reject_control "--note" "$note"
    [ -n "$ruled_at" ] || ruled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    reject_control "--ruled-at" "$ruled_at"

    mkdir -p "$RULINGS_DIR" || die "cannot create $RULINGS_DIR"
    f="$RULINGS_DIR/$slug.json"
    seed='{"slug":"","rulings":[]}'
    if [ -s "$f" ]; then
      existing="$("$JQ" -c '.' "$f" 2>/dev/null)" && [ -n "$existing" ] && seed="$existing"
    fi
    out="$("$JQ" -n --argjson seed "$seed" --arg slug "$slug" --argjson ac "$ac" \
      --arg evidence "$evidence" --arg by "$ruled_by" --arg at "$ruled_at" --arg note "$note" '
        ($seed.rulings // []) as $rows
        | {slug: $slug,
           rulings: (($rows | map(select(((.ac // "") | tostring) != ($ac | tostring))))
                     + [{ac: $ac, evidence: $evidence, ruled_by: $by, ruled_at: $at}
                        + (if $note == "" then {} else {note: $note} end)]
                     | sort_by(.ac))}')" || die "failed to build the ruling row"
    printf '%s\n' "$out" > "$f.tmp.$$" || die "cannot write $f"
    mv -f "$f.tmp.$$" "$f" || die "cannot install $f"
    printf 'live-ac-ruling: recorded %s AC%s (by %s at %s) -> %s\n' \
      "$slug" "$ac" "$ruled_by" "$ruled_at" "$f" >&2
    ;;
  show)
    slug="${1:-}"; [ -n "$slug" ] && shift || die "show needs a <slug>"
    ac=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --ac) ac="${2:-}"; shift 2 ;;
        --ac=*) ac="${1#--ac=}"; shift ;;
        -h|--help) usage ;;
        *) die "show: unknown argument '$1'" ;;
      esac
    done
    f="$RULINGS_DIR/$slug.json"
    [ -s "$f" ] || exit 1
    if [ -n "$ac" ]; then
      "$JQ" -e --arg ac "$ac" '(.rulings // []) | map(select(((.ac // "") | tostring) == $ac)) | .[0] // empty' \
        "$f" 2>/dev/null || exit 1
    else
      "$JQ" -e '(.rulings // []) | select(length > 0)' "$f" 2>/dev/null || exit 1
    fi
    ;;
  list)
    [ -d "$RULINGS_DIR" ] || exit 0
    shopt -s nullglob
    for f in "$RULINGS_DIR"/*.json; do
      "$JQ" -r '(.slug // "?") as $s | (.rulings // [])[]
                | "\($s)  AC\(.ac)  \(.ruled_by // "?")  \(.ruled_at // "?")"' "$f" 2>/dev/null
    done
    ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand '$cmd'" ;;
esac
