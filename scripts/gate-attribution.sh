#!/usr/bin/env bash
# gate-attribution.sh — tag each blocking gate finding as in-scope (touched
# by the building PRD's own diff) or inherited (landed code from another
# PRD's merge). PRD-build-gate-debt-auto-prd requirement 1.
#
# Why: extend-gate.sh's `autobuilder gate` blocks on the UNION of every
# receipt at HEAD, but the building PRD's contract is its own acceptance
# criteria (SKILL.md Phase 3/4) — a finding in code the PRD's diff never
# touched has no owner. The 2026-09-11 incident this PRD fixes: the
# mcphost-schedules PRD sat gate-pending 7 hours on three blocks, none in
# its own diff, because nothing bridged "the gate reports blocks per HEAD"
# and "the loop assigns work per PRD" (see the PRD's TL;DR / five-whys).
# This script is that bridge for a single gate run's blocking set; the
# threshold+draft half of the fix is gate-debt.sh (requirement 2).
#
# Subcommands:
#
#   gate-attribution.sh compute <repo> <diff_base> <diff_head> <notes-file>
#       [--producer-inputs <receipt>=<file>[,<file>...][;<receipt>=...]]
#
#     <diff_base>..<diff_head> is the building PRD's OWN diff range — for a
#     landed no-ff merge, that's <merge>^1..<merge> (the merge commit's
#     first parent is mainline immediately before this PRD landed, so the
#     diff against it is exactly what the PRD's merge introduced); the
#     caller (extend-gate.sh) resolves that range before invoking this.
#
#     <notes-file>: one blocking finding per line, TAB-separated
#       `<receipt>\t<note>` — the same shape gate-delta.sh's
#       `parse-blocking` already emits from a captured `autobuilder gate`
#       run, so a caller can pipe that straight in. A <note> may embed a
#       `path=<file>[,<file>...]` or `test=<file>` token naming what
#       actually failed (comma-separated when one finding spans more than
#       one file); a note with neither token is a PATHLESS finding — e.g.
#       a missing proof receipt has no single file to blame (requirement 1:
#       "findings with no path ... are inherited unless the PRD's diff
#       touches the producer's inputs").
#
#     Scope rule (requirement 1, AC1):
#       - a finding WITH a path/test token is `in-scope` if ANY of its
#         listed paths appears in `git -C <repo> diff --name-only
#         <diff_base>..<diff_head>`, else `inherited`.
#       - a PATHLESS finding is `inherited` UNLESS the diff touches at
#         least one of that receipt's producer-input files — a small
#         built-in default map (proof-receipt / intake -> the intent
#         card + Cargo.toml, the files those two producers actually read)
#         plus whatever `--producer-inputs` adds or overrides.
#
#     Prints ONE line of JSON to stdout:
#       {"blocks":[{"receipt":"...","finding":"...","path":"...",
#                   "scope":"in-scope"|"inherited"}, ...],
#        "in_scope":<N>, "inherited":<M>}
#     and a human summary to stderr: "gate-attribution: inherited=M in-scope=N"
#     (the exact token order extend-gate.sh's journal gate line reuses,
#     AC1: "the journal gate line reads inherited=1 in-scope=1").
#
#     Exit 0 always — this is a computation, never a verdict; the caller's
#     own gate outcome (pass/block) is unaffected by anything here
#     (Non-goals: "No change to which receipts block or to verdict
#     semantics").
#
# SIGPIPE-safe (Technical considerations): all output goes through
# printf/jq, never a pipeline whose reader can exit early on a caller that
# only wants the summary line.
set -uo pipefail

die() { echo "gate-attribution: $*" >&2; exit "${2:-2}"; }

usage() {
  echo "usage: gate-attribution.sh compute <repo> <diff_base> <diff_head> <notes-file> [--producer-inputs <spec>]" >&2
  exit 2
}

cmd_compute() {
  local repo="${1:-}" base="${2:-}" head="${3:-}" notes_file="${4:-}"
  [ -n "$repo" ] && [ -n "$base" ] && [ -n "$head" ] && [ -n "$notes_file" ] || usage
  shift 4
  local producer_inputs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --producer-inputs) producer_inputs="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -d "$repo" ] || die "no such directory: $repo" 2
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo" 2
  [ -f "$notes_file" ] || die "no such notes file: $notes_file" 2

  local diff_file
  diff_file="$(mktemp "${TMPDIR:-/tmp}/gate-attribution-diff.XXXXXX")"
  git -C "$repo" diff --name-only "${base}..${head}" > "$diff_file" 2>/dev/null || true

  python3 - "$notes_file" "$producer_inputs" "$diff_file" <<'PY'
import json, re, sys

notes_file, producer_inputs_spec, diff_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(diff_file) as fh:
    diff_files = set(l.strip() for l in fh if l.strip())

# Built-in default producer-input map (requirement 1: "unless the PRD's
# diff touches the producer's inputs" — these are the files extend-gate.sh's
# `intake` and `proof-receipt` steps actually read before writing a
# pathless receipt).
producer_inputs = {
    "proof-receipt": ["agent/intent-card.json", "Cargo.toml"],
    "intake": ["agent/intent-card.json"],
}
if producer_inputs_spec:
    for clause in producer_inputs_spec.split(";"):
        clause = clause.strip()
        if not clause or "=" not in clause:
            continue
        receipt, files = clause.split("=", 1)
        producer_inputs[receipt.strip()] = [f.strip() for f in files.split(",") if f.strip()]

path_re = re.compile(r'\bpath=(\S+)')
test_re = re.compile(r'\btest=(\S+)')

blocks = []
in_scope = 0
inherited = 0

with open(notes_file) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 1)
        receipt = parts[0]
        note = parts[1] if len(parts) > 1 else ""

        m = path_re.search(note) or test_re.search(note)
        if m:
            paths = [p for p in m.group(1).split(",") if p]
            scope = "in-scope" if any(p in diff_files for p in paths) else "inherited"
            path_field = ",".join(paths)
        else:
            inputs = producer_inputs.get(receipt, [])
            touched = any(f in diff_files for f in inputs)
            scope = "in-scope" if touched else "inherited"
            path_field = ""

        blocks.append({"receipt": receipt, "finding": note, "path": path_field, "scope": scope})
        if scope == "in-scope":
            in_scope += 1
        else:
            inherited += 1

print(json.dumps({"blocks": blocks, "in_scope": in_scope, "inherited": inherited}))
print(f"gate-attribution: inherited={inherited} in-scope={in_scope}", file=sys.stderr)
PY
  local py_rc=$?
  rm -f "$diff_file"
  return "$py_rc"
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    compute) cmd_compute "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
