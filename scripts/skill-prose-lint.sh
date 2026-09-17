#!/usr/bin/env bash
# scripts/skill-prose-lint.sh — PRD-build-skill-instruction-single-source
# R4/R8: keeps SKILL.md's archive/land main-gate command down to ONE
# canonical copy (the section marked `<!-- single-source: archive-gate
# -->`, PRD-build-skill-instruction-single-source R2/R7) going forward.
# Two independent checks, both fenced-code-block-only (Technical
# considerations: "prose sentences that mention flags for explanation do
# not trip it" — this lint never scans plain paragraph text):
#
#   1. Duplicate raw form: any fenced block OUTSIDE the canonical section
#      matching a pattern in scripts/skill-prose-lint.patterns (one
#      extended-regex pattern per line, extensible — see that file's own
#      header). Ships with `gate-launch\.sh .*--scope main` and
#      `extend-gate\.sh .*--head`.
#   2. Unknown flag: any fenced block (inside or outside the canonical
#      section — the canonical section's own claims must stay accurate
#      too) that mentions `scripts/<name>.sh` followed on the same line
#      by a `--flag` token whose literal text does not appear anywhere in
#      that script's own source. A script the lint can't find locally is
#      skipped (not this lint's concern) rather than failing.
#
# R7: the canonical section is located by its marker comment, not its
# heading text — renaming the heading alone still allowlists the section
# correctly (AC10); a MISSING marker fails the WHOLE lint immediately,
# naming it, so the exemption can never be silently disabled by deleting
# the comment.
#
# Usage: skill-prose-lint.sh [<skill.md path>]
#   Defaults to $SKILL_DIR/SKILL.md. Patterns file defaults to
#   $HERE/skill-prose-lint.patterns (override: SKILL_PROSE_LINT_PATTERNS).
#   Marker comment text defaults to the real one (override:
#   SKILL_PROSE_LINT_MARKER — fixtures use this to test a renamed/removed
#   marker without needing a second literal comment string hardcoded here).
#
# Exit: 0 clean | 1 one or more violations (each printed as
#   `skill-prose-lint: <file>:<line>: <reason>`) | 2 usage/file-not-found |
#   3 marker comment not found anywhere in the file
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SKILLMD="${1:-$SKILL_DIR/SKILL.md}"
PATTERNS_FILE="${SKILL_PROSE_LINT_PATTERNS:-$HERE/skill-prose-lint.patterns}"
MARKER="${SKILL_PROSE_LINT_MARKER:-<!-- single-source: archive-gate -->}"

[ -f "$SKILLMD" ] || { echo "skill-prose-lint: no such file: $SKILLMD" >&2; exit 2; }
[ -f "$PATTERNS_FILE" ] || { echo "skill-prose-lint: no such patterns file: $PATTERNS_FILE" >&2; exit 2; }

python3 - "$SKILLMD" "$PATTERNS_FILE" "$SKILL_DIR" "$MARKER" <<'PY'
import re
import sys
import os

skillmd_path, patterns_path, skill_dir, marker = sys.argv[1:5]

with open(skillmd_path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

patterns = []
with open(patterns_path, encoding="utf-8") as fh:
    for raw in fh:
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        patterns.append(re.compile(s))

violations = []

# --- locate the canonical section's exempt line range via the marker ---
marker_idx = None
for i, line in enumerate(lines):
    if marker in line:
        marker_idx = i
        break

if marker_idx is None:
    print(f"skill-prose-lint: {skillmd_path}: missing marker {marker!r} — "
          "the canonical archive-gate section cannot be located, refusing "
          "to lint (a removed marker must fail loud, never silently widen "
          "or disable the exemption)", file=sys.stderr)
    sys.exit(3)

heading_re = re.compile(r'^(#{1,6})\s')
heading_level = None
heading_idx = None
for i in range(marker_idx, -1, -1):
    m = heading_re.match(lines[i])
    if m:
        heading_level = len(m.group(1))
        heading_idx = i
        break
if heading_idx is None:
    # No enclosing heading at all -- exempt only the marker line itself.
    heading_idx = marker_idx
    heading_level = 1

# Prefer an explicit closing marker (`<!-- /single-source: archive-gate
# -->`, derived from the opening one) over next-heading detection: this
# doc nests most of its sub-sections as BOLD inline pseudo-headers inside
# one long bulleted list, not real `#`-headings, so "next heading of the
# same or lower level" can land hundreds of lines past where the section
# actually ends (it did during this PRD's own development -- the
# canonical section is a handful of paragraphs, not the entire rust-
# extend ship-action bullet it lives inside). A missing close marker is
# not itself an error (R7 only requires the OPEN marker) -- fall back to
# next-heading-of-same-or-lower-level, same as before.
close_marker = marker.replace("<!-- ", "<!-- /", 1) if marker.startswith("<!-- ") else None
end_idx = None
if close_marker:
    for i in range(marker_idx + 1, len(lines)):
        if close_marker in lines[i]:
            end_idx = i + 1  # exclusive upper bound includes the close line
            break
if end_idx is None:
    end_idx = len(lines)
    for i in range(marker_idx + 1, len(lines)):
        m = heading_re.match(lines[i])
        if m and len(m.group(1)) <= heading_level:
            end_idx = i
            break

exempt_start, exempt_end = heading_idx, end_idx  # [start, end)

# --- collect fenced code blocks: (start_line_idx, end_line_idx, body_lines) ---
fence_re = re.compile(r'^\s*```')
blocks = []
in_fence = False
fence_start = None
body = []
for i, line in enumerate(lines):
    if fence_re.match(line):
        if not in_fence:
            in_fence = True
            fence_start = i
            body = []
        else:
            in_fence = False
            blocks.append((fence_start, i, body))
    elif in_fence:
        body.append((i, line))

script_mention_re = re.compile(r'scripts/([A-Za-z0-9_-]+\.sh)\b')
flag_re = re.compile(r'--[A-Za-z][A-Za-z0-9-]*')

for start, end, body_lines in blocks:
    inside_section = exempt_start <= start < exempt_end
    for lineno, text in body_lines:
        # Check 1: duplicate raw form -- only outside the canonical section.
        if not inside_section:
            for pat in patterns:
                if pat.search(text):
                    violations.append(
                        f"{lineno + 1}: raw main-gate form outside the "
                        f"canonical section (matches /{pat.pattern}/): {text.strip()}"
                    )

        # Check 2: unknown flag -- everywhere, including inside the section.
        mentions = list(script_mention_re.finditer(text))
        for idx, sm in enumerate(mentions):
            seg_start = sm.end()
            seg_end = mentions[idx + 1].start() if idx + 1 < len(mentions) else len(text)
            segment = text[seg_start:seg_end]
            script_name = sm.group(1)
            script_path = os.path.join(skill_dir, "scripts", script_name)
            if not os.path.isfile(script_path):
                continue  # not this lint's concern
            try:
                with open(script_path, encoding="utf-8", errors="replace") as sfh:
                    script_src = sfh.read()
            except OSError:
                continue
            for fm in flag_re.finditer(segment):
                flag = fm.group(0)
                if flag not in script_src:
                    violations.append(
                        f"{lineno + 1}: unknown flag {flag} for scripts/{script_name} "
                        f"(not found in that script's own source): {text.strip()}"
                    )

if violations:
    for v in violations:
        print(f"skill-prose-lint: {skillmd_path}:{v}", file=sys.stderr)
    print(f"skill-prose-lint: {len(violations)} violation(s)", file=sys.stderr)
    sys.exit(1)

print(f"skill-prose-lint: {skillmd_path}: clean "
      f"(canonical section lines {exempt_start + 1}-{exempt_end})")
sys.exit(0)
PY
