#!/usr/bin/env bash
# tests/lint_gate_red_renderers_show_age.sh — PRD-build-gate-red-render-age.
#
# gate-red-red state (state/gate-red.summary line 1's leading field,
# state/gate-red.json's .ts) carries its own write time, but nothing
# forced a renderer of that state to SHOW how old it is — three separate
# scripts (gates-banner.sh, handoff-header.sh, gate-red-tick.sh) printed
# it bare, and Joe read a resolved red as current for 2h on 2026-09-17.
# lib/gate-red-age.sh fixes the three known sites; this lint keeps a
# fourth site from regrowing unreviewed, the same convention
# tests/lint_basename_as_identity.sh uses for its own bug class (a
# `# lint:...` marker-controlled allowlist, python heredoc, site
# enumeration by grep, `N violation(s) of M site(s) scanned` output).
#
# Scans scripts/*.sh and scripts/lib/*.sh (excluding *selftest*, *.bak-*
# files, and lib/gate-red-age.sh itself -- the helper's own home) for any
# non-comment line containing the literal substring `gate-red.summary`,
# `gate-red.json`, or (PRD-buildloop-tick-outcome-liveness AC14)
# `tick-outcome.json` -- the record `tick-run.sh` writes every tick and
# `loop-liveness.sh`/`handoff-header.sh`/`gates-banner.sh` render a
# "when did the loop last succeed" line from, the same staleness-hiding
# bug class gate-red.summary/.json already had: a renderer that prints
# `last_ok=...` without an age is exactly how a dead loop reads alive.
# Each such line is a SITE.
#
# A site passes if:
#   (a) its FILE, anywhere, both sources lib/gate-red-age.sh (a `source`/
#       `.` line naming gate-red-age.sh) AND calls gate_red_age_note or
#       gate_red_age_s -- once a file has adopted the helper, every
#       gate-red.summary/.json/tick-outcome.json reference in it is
#       presumed downstream of that adoption (gates-banner.sh,
#       handoff-header.sh, gate-red-tick.sh, loop-liveness.sh all
#       reference the filename several times each -- in a cache-path
#       default, a remote ssh command string, a doc comment -- and
#       re-marking every one individually would be noise, not signal);
#   (b) OR the line itself carries the trailing marker
#       `# lint:gate-red-not-rendered` with a reason -- for a producer or
#       a machine consumer that intentionally never renders the state as
#       a human-facing "current" line (gate-red-summary.sh itself,
#       manifest-invariants.sh's retraction-consistency check (both the
#       gate-red-archived class and, since AC14, the loop-tick-stale
#       class), day-ledger.sh's machine ledger record, gate-status.sh's
#       --red JSON passthrough, tick-run.sh's own tick-outcome.json
#       write -- a writer, not a renderer).
#
# --extra <path> [<path> ...]: scan additional files (outside scripts/)
# with the same two rules, plus a third: the marker
# `# lint:gate-red-age-shown` -- for an out-of-repo renderer (the
# dotfiles-managed ~/.claude/statusline.sh and
# ~/.claude/hooks/gates-banner.sh) that already shows age with its own
# logic and is out of this repo's lint scope by construction.
#
# --root <dir>: scan <dir>/scripts and <dir>/scripts/lib instead of this
# repo's own (fixture testing -- tests/gateage_ac1_lint_fixture.sh).
#
# Usage: lint_gate_red_renderers_show_age.sh [--root <dir>] [--extra <path> ...]
# Exit: 0 clean (prints "lint_gate_red_renderers_show_age: N site(s)
#   scanned, 0 violations") | 1 one or more violations, each `file:line`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"

root="$SKILL_DIR"
extra=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --extra)
      shift
      while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do extra+=("$1"); shift; done
      ;;
    *) echo "usage: lint_gate_red_renderers_show_age.sh [--root <dir>] [--extra <path> ...]" >&2; exit 2 ;;
  esac
done

python3 - "$root" "${extra[@]:-}" <<'PY'
import re
import sys
import os

args = [a for a in sys.argv[1:] if a]
root = args[0] if args else "."
extra = args[1:]

REF_RE = re.compile(r'gate-red\.summary|gate-red\.json|tick-outcome\.json')
SOURCE_RE = re.compile(r'gate-red-age\.sh')
CALL_RE = re.compile(r'\bgate_red_age_(?:note|s)\b')
MARKER_NOT_RENDERED = "# lint:gate-red-not-rendered"
MARKER_AGE_SHOWN = "# lint:gate-red-age-shown"

def collect_scripts_files(root):
    files = []
    for sub in ("scripts", os.path.join("scripts", "lib")):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if not n.endswith(".sh"):
                continue
            if "selftest" in n or ".bak-" in n:
                continue
            if sub == os.path.join("scripts", "lib") and n == "gate-red-age.sh":
                continue
            files.append(os.path.join(d, n))
    return files

def scan(path, allow_age_shown):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    lines = text.splitlines()

    adopted = bool(SOURCE_RE.search(text)) and bool(CALL_RE.search(text))

    scanned = 0
    violations = []
    for i, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if not REF_RE.search(line):
            continue
        scanned += 1
        if adopted:
            continue
        if MARKER_NOT_RENDERED in line:
            continue
        if allow_age_shown and MARKER_AGE_SHOWN in line:
            continue
        violations.append(f"{path}:{i}")
    return scanned, violations

files = collect_scripts_files(root)

total_scanned = 0
all_violations = []
for path in files:
    s, v = scan(path, allow_age_shown=False)
    total_scanned += s
    all_violations.extend(v)

for path in extra:
    if not os.path.isfile(path):
        continue
    s, v = scan(path, allow_age_shown=True)
    total_scanned += s
    all_violations.extend(v)

if all_violations:
    for v in all_violations:
        print(v)
    print(f"lint_gate_red_renderers_show_age: {len(all_violations)} violation(s) of {total_scanned} site(s) scanned", file=sys.stderr)
    sys.exit(1)

print(f"lint_gate_red_renderers_show_age: {total_scanned} site(s) scanned, 0 violations")
sys.exit(0)
PY
