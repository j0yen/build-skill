#!/usr/bin/env bash
# tests/lint_basename_as_identity.sh — decision 42f14605 (extended
# 2026-09-17 19:25 EDT): a countable lint keeping the basename-as-
# repo-slug bug class (branch-protection.sh's six sites, extend-gate.sh's
# repo_slug_for_ci extraction) from regrowing a new site unreviewed.
#
# Scans scripts/*.sh (excluding scripts/lib/repo-slug.sh, the resolver's
# own home — its internal `{ basename "$repo"; return; }` fallback is the
# implementation, not an offense) for `basename` applied to a repo-path
# variable ($repo or $repo_dir — the only two names any site this PRD
# chain has actually found uses; $build_into/$target_repo/$wt are a
# different semantic class — worktree/build-target naming elsewhere in
# this codebase, e.g. burst-lane.sh, worktree-extend.sh's own worktree-dir
# naming — never repo-identity resolution, and out of THIS lint's scope).
#
# A hit is a VIOLATION unless the line carries the trailing marker
# `# lint:basename-label` (meaning: display label only, never identity —
# same convention as skill-prose-lint.sh's marker-controlled allowlist)
# AND is one of:
#   1. assigned to a variable whose name contains "slug" (case-insensitive)
#      -- repo_slug, repo_slug_pv, repo_slug_pvb, slug, ...
#   2. the `${*_BASENAME:-$(basename ...)}` override-fallback idiom
#      (land-resolve.sh's policy-path convention)
#   3. the assigned variable is later, in the same file, passed to
#      push_via_branch_for(), landing_record_path(), or interpolated into
#      a path literal under state/landings, state/land-policy, or
#      state/main-verdict-cache
# A comment-only line (trimmed text starts with `#`) is never scanned.
#
# Usage: lint_basename_as_identity.sh [<dir> ...]   (default: scripts)
# Exit: 0 clean (prints "lint_basename_as_identity: N site(s) scanned, 0
#   violations") | 1 one or more violations, each printed as `file:line`
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"

dirs=("$@")
[ "${#dirs[@]}" -eq 0 ] && dirs=("$SKILL_DIR/scripts")

python3 - "${dirs[@]}" <<'PY'
import re
import sys
import os

dirs = sys.argv[1:]

VAR_RE = r'\$\{?(repo|repo_dir)\}?\b'
BASENAME_RE = re.compile(r'basename\s+"?' + VAR_RE + r'"?')
# Finds the variable immediately assigned FROM a basename-of-repo-var
# call, wherever it sits on the line -- not just at line start, so the
# common `local x; x="$(basename ...)"` two-statement-per-line shape
# (branch-protection.sh's own style before this fix) is caught too.
ASSIGN_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="\$\(basename\s+"?' + VAR_RE + r'"?\)"')
FALLBACK_RE = re.compile(r'\$\{[A-Za-z_]*BASENAME[A-Za-z_]*:-\$\(basename\b')
MARKER = "# lint:basename-label"

files = []
for d in dirs:
    if not os.path.isdir(d):
        continue
    for root, _, names in os.walk(d):
        for n in sorted(names):
            if n.endswith(".sh"):
                files.append(os.path.join(root, n))
files.sort()

scanned = 0
violations = []

for path in files:
    if path.endswith(os.path.join("lib", "repo-slug.sh")):
        continue
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    # Pre-scan: which variables does this file ever pass to
    # push_via_branch_for / landing_record_path, or interpolate into a
    # state/landings|land-policy|main-verdict-cache path literal?
    sink_vars = set()
    for line in lines:
        for m in re.finditer(r'push_via_branch_for\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"', line):
            sink_vars.add(m.group(1))
        for m in re.finditer(r'landing_record_path\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"', line):
            sink_vars.add(m.group(1))
        if re.search(r'state/(landings|land-policy|main-verdict-cache)', line):
            for m in re.finditer(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', line):
                sink_vars.add(m.group(1))

    for i, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if not BASENAME_RE.search(line):
            continue
        scanned += 1
        if MARKER in line:
            continue

        lhs = None
        am = ASSIGN_RE.search(line)
        if am:
            lhs = am.group(1)

        is_violation = False
        if lhs and "slug" in lhs.lower():
            is_violation = True
        elif FALLBACK_RE.search(line):
            is_violation = True
        elif lhs and lhs in sink_vars:
            is_violation = True

        if is_violation:
            violations.append(f"{path}:{i}")

if violations:
    for v in violations:
        print(v)
    print(f"lint_basename_as_identity: {len(violations)} violation(s) of {scanned} site(s) scanned", file=sys.stderr)
    sys.exit(1)

print(f"lint_basename_as_identity: {scanned} site(s) scanned, 0 violations")
sys.exit(0)
PY
