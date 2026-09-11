#!/usr/bin/env bash
# resurrection-guard.sh — after a stale-base recovery merge whose conflict
# resolution took the union of both sides, re-scan the merge's own diff for
# resurrected risk-gate-shape findings. PRD-build-gate-debt-auto-prd
# requirement 5.
#
# Why: a union-style conflict resolution can silently bring back a line an
# earlier fix on ONE side deliberately removed (this PRD's TL;DR/five-whys:
# "the operator's coder confirms or refutes from the diff" for exactly this
# suspicion at the 2026-09-11 mcphost-schedules incident — a merge is the
# one place a file's history can un-happen without anyone touching it
# directly). The concrete, checkable shape this guard looks for: an `unsafe`
# block the merge's own diff ADDED that has no `SAFETY` comment near it in
# the post-merge file — the same shape the PRD's own AC6 names.
#
# Usage:
#   resurrection-guard.sh check <repo> <before_sha> <after_sha>
#       [--journal <path>] [--out <findings-json-path>]
#
#   <before_sha>..<after_sha> is the union-resolve merge's own diff range
#   (typically the merge's first parent and the merge commit itself, same
#   convention gate-attribution.sh uses for a building PRD's own merge).
#
#   For every `*.rs` file the diff touched, looks at lines the diff ADDED
#   (leading `+`, excluding the `+++` header) that contain the word
#   `unsafe`; a finding fires when neither that added line nor any of the
#   3 lines immediately above it IN THE POST-MERGE FILE contains `SAFETY`.
#   This is a real (if simplified relative to whatever the full autobuilder
#   risk-gate does) scan over actual diff + file content — not a fixture-
#   only stub — scoped to exactly the finding shape this requirement names;
#   it does not attempt to replace the risk-gate receipt itself (Non-goals:
#   "No change to which receipts block or to verdict semantics").
#
#   Journals ONE line: `merge  resurrection-check  (findings=<n>)`.
#   Writes findings (if --out given) as a JSON array in gate-attribution.sh
#   block shape, each tagged `"scope":"inherited","origin":"union-resolve"`
#   (requirement 5: "findings go into attribution as inherited with
#   origin=union-resolve") — a caller can fold this array into a gate run's
#   own `blocks` list alongside gate-attribution.sh's output.
#
# Exit: 0 always (a scan, not a verdict — same posture as
# gate-attribution.sh; Non-goals: no change to verdict semantics). Exit 2
# is reserved for usage errors only.
set -uo pipefail

die() { echo "resurrection-guard: $*" >&2; exit "${2:-2}"; }

usage() {
  echo "usage: resurrection-guard.sh check <repo> <before_sha> <after_sha> [--journal <path>] [--out <path>]" >&2
  exit 2
}

cmd_check() {
  local repo="${1:-}" before="${2:-}" after="${3:-}"
  [ -n "$repo" ] && [ -n "$before" ] && [ -n "$after" ] || usage
  shift 3
  local journal="${JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --journal) journal="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
  mkdir -p "$(dirname "$journal")"

  local diff_file
  diff_file="$(mktemp "${TMPDIR:-/tmp}/resurrection-guard-diff.XXXXXX")"
  git -C "$repo" diff -U0 "${before}..${after}" -- '*.rs' > "$diff_file" 2>/dev/null || true

  local reponame; reponame="$(basename "${repo%/}")"
  local findings_json
  findings_json="$(python3 - "$repo" "$after" "$diff_file" <<'PY'
import json, re, subprocess, sys

repo, after, diff_file = sys.argv[1], sys.argv[2], sys.argv[3]

with open(diff_file) as fh:
    diff_lines = fh.readlines()

current_file = None
findings = []
hunk_re = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
new_lineno = None

for line in diff_lines:
    if line.startswith('+++ '):
        path = line[4:].strip()
        current_file = path[2:] if path.startswith('b/') else path
        continue
    if line.startswith('--- '):
        continue
    m = hunk_re.match(line)
    if m:
        new_lineno = int(m.group(1))
        continue
    if line.startswith('+') and not line.startswith('+++'):
        added_text = line[1:]
        if current_file and re.search(r'\bunsafe\b', added_text):
            # Look at the post-merge file itself for a nearby SAFETY
            # comment (the 3 lines immediately above this added line).
            safety_nearby = False
            try:
                content = subprocess.run(
                    ["git", "-C", repo, "show", f"{after}:{current_file}"],
                    capture_output=True, text=True, check=True,
                ).stdout.splitlines()
                idx = (new_lineno or 1) - 1
                start = max(0, idx - 3)
                context = content[start:idx + 1]
                safety_nearby = any("SAFETY" in l for l in context)
            except Exception:
                safety_nearby = False
            if not safety_nearby:
                findings.append({
                    "receipt": "risk-gate",
                    "finding": "unsafe block without SAFETY comment",
                    "path": current_file,
                    "scope": "inherited",
                    "origin": "union-resolve",
                })
        if new_lineno is not None:
            new_lineno += 1
    elif not line.startswith('-') and not line.startswith('\\'):
        if new_lineno is not None:
            new_lineno += 1

print(json.dumps(findings))
PY
)"
  rm -f "$diff_file"

  local n
  n="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$findings_json")"

  printf '%s  merge  resurrection-check  (findings=%s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" >> "$journal"

  if [ -n "$out" ]; then
    printf '%s\n' "$findings_json" > "$out"
  fi
  echo "resurrection-guard: findings=$n"
  return 0
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    check) cmd_check "$@" ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
