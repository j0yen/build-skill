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
#       - a finding with a `commits=<sha>[,<sha>...]` token is attributed by
#         COMMIT RANGE, not by path (PRD-build-inherited-blocks-delta-pass
#         AC10): those shas ARE the finding's inputs. The finding is
#         `inherited` when EVERY named sha is an ancestor of <diff_base>
#         (`git merge-base --is-ancestor <sha> <diff_base>` — it landed on
#         main before this branch forked, so this branch did not cause it);
#         `in-scope` when ANY named sha is inside <diff_base>..<diff_head>,
#         or is unresolvable in <repo>, or the token names nothing at all
#         (fail-closed, same spirit as the unknown-inputs rule below).
#         This token is checked FIRST and wins over path/test.
#         The block carries `"attribution":"commit-range"` and the stderr
#         summary gains ` attribution=commit-range`.
#         Motivating case (2026-09-18 live finding, burst-lane-gate-debt-
#         2b2982e): `rollback-plan` is pathless and has no producer-input
#         map, so the fail-closed rule below called it in-scope on every
#         branch — even when the non-revert-clean commit it names landed on
#         main long before the branch existed. extend-gate.sh now puts the
#         guilty (non-revertable) shas from the rollback-plan receipt into
#         the note as this token, which makes that block correctly
#         inherited.
#       - a finding WITH a path/test token is `in-scope` if ANY of its
#         listed paths appears in `git -C <repo> diff --name-only
#         <diff_base>..<diff_head>`, else `inherited`.
#       - a PATHLESS finding whose receipt has a KNOWN producer-input map
#         (the small built-in default — proof-receipt / intake -> the
#         intent card + Cargo.toml, the files those two producers actually
#         read — plus whatever `--producer-inputs` adds or overrides) is
#         `inherited` UNLESS the diff touches at least one of those files.
#       - a PATHLESS finding whose receipt has NO producer-input map (an
#         unregistered receipt, or one registered with an empty file list)
#         is `in-scope`, fail-closed (PRD-build-inherited-blocks-delta-pass
#         requirement 2: "a finding whose producer inputs are unknown is
#         in-scope") — an unmapped producer must never quietly become free
#         inherited debt just because nobody wired its inputs yet. Such a
#         block also carries `"attribution":"unknown-inputs"` and the
#         summary line below gains an `attribution=unknown-inputs` token.
#
#     Prints ONE line of JSON to stdout:
#       {"blocks":[{"receipt":"...","finding":"...","path":"...",
#                   "scope":"in-scope"|"inherited"
#                   [,"attribution":"unknown-inputs"|"commit-range"]
#                   [,"commits":"<sha>,<sha>"]}, ...],
#        "in_scope":<N>, "inherited":<M>, "unknown_inputs":<K>,
#        "commit_range":<R>}
#     and a human summary to stderr: "gate-attribution: inherited=M in-scope=N"
#     (the exact token order extend-gate.sh's journal gate line reuses,
#     AC1: "the journal gate line reads inherited=1 in-scope=1"), with an
#     appended " attribution=unknown-inputs" when K > 0.
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

  python3 - "$notes_file" "$producer_inputs" "$diff_file" "$repo" "$base" <<'PY'
import json, re, subprocess, sys

notes_file, producer_inputs_spec, diff_file = sys.argv[1], sys.argv[2], sys.argv[3]
repo, diff_base = sys.argv[4], sys.argv[5]
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
commits_re = re.compile(r'\bcommits=(\S+)')

# AC10: a guilty commit that is an ancestor of the branch base landed
# before this branch forked -> the branch did not cause it -> inherited.
# Anything else (inside diff_base..diff_head, or a sha this repo cannot
# resolve at all) is in-scope, fail-closed. Cached: a rollback-plan note
# can name the same sha on several findings, and each check is two forks.
_ancestor_cache = {}


def landed_before_base(sha):
    if sha in _ancestor_cache:
        return _ancestor_cache[sha]
    verdict = False
    try:
        resolved = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--verify", "--quiet", sha + "^{commit}"],
            capture_output=True, text=True)
        if resolved.returncode == 0:
            anc = subprocess.run(
                ["git", "-C", repo, "merge-base", "--is-ancestor", sha, diff_base],
                capture_output=True, text=True)
            verdict = anc.returncode == 0
    except Exception:
        verdict = False
    _ancestor_cache[sha] = verdict
    return verdict

blocks = []
in_scope = 0
inherited = 0
unknown_inputs = 0
commit_range = 0

with open(notes_file) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 1)
        receipt = parts[0]
        note = parts[1] if len(parts) > 1 else ""

        cm = commits_re.search(note)
        m = path_re.search(note) or test_re.search(note)
        unknown = False
        by_commit_range = False
        commits_field = ""
        if cm:
            # AC10: attribute by commit range. These shas ARE the inputs;
            # checked before path/test because a receipt that names its
            # guilty commits has told us exactly what caused it.
            shas = [c for c in cm.group(1).split(",") if c]
            scope = "inherited" if shas and all(landed_before_base(c) for c in shas) else "in-scope"
            path_field = ""
            commits_field = ",".join(shas)
            by_commit_range = True
        elif m:
            paths = [p for p in m.group(1).split(",") if p]
            scope = "in-scope" if any(p in diff_files for p in paths) else "inherited"
            path_field = ",".join(paths)
        else:
            # PRD-build-inherited-blocks-delta-pass requirement 2: a finding
            # whose producer input list is unknown (no entry in the map, or
            # an entry registered with an empty file list) is in-scope,
            # fail-closed — a mis-attributed real defect must never pass as
            # "just inherited debt" for want of a producer-input mapping.
            # This is distinct from a KNOWN producer whose registered inputs
            # simply weren't touched (still legitimately inherited).
            inputs = producer_inputs.get(receipt)
            if not inputs:
                scope = "in-scope"
                unknown = True
            else:
                touched = any(f in diff_files for f in inputs)
                scope = "in-scope" if touched else "inherited"
            path_field = ""

        block = {"receipt": receipt, "finding": note, "path": path_field, "scope": scope}
        if unknown:
            block["attribution"] = "unknown-inputs"
            unknown_inputs += 1
        if by_commit_range:
            block["attribution"] = "commit-range"
            block["commits"] = commits_field
            commit_range += 1
        blocks.append(block)
        if scope == "in-scope":
            in_scope += 1
        else:
            inherited += 1

print(json.dumps({"blocks": blocks, "in_scope": in_scope, "inherited": inherited,
                  "unknown_inputs": unknown_inputs, "commit_range": commit_range}))
summary = f"gate-attribution: inherited={inherited} in-scope={in_scope}"
if unknown_inputs:
    summary += " attribution=unknown-inputs"
if commit_range:
    summary += " attribution=commit-range"
print(summary, file=sys.stderr)
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
