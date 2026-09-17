#!/usr/bin/env bash
# live-ac-report.sh — PRD-build-live-ac-no-defer R9/AC9: a one-time,
# read-only report listing every SHIPPED (built-prds/) loop-tooling PRD
# that deferred an AC whose own justification text mentions live/real/box
# — the "44 of 121" candidates the PRD's own problem statement measured
# (`grep -l '^- deferred_acs: \[[0-9]' built-prds/PRD-*.md` over loop-
# tooling PRDs). This is visibility only: it never re-opens, re-queues,
# or mutates a single file — R9 explicitly rules that out (see the PRD's
# Non-goals: "Retroactively re-opening the 44 shipped PRDs; a one-time
# report lists them ... for the operator").
#
# Historical PRDs predate the `(Live` marker (this PRD adds it going
# forward), so this report does NOT look for the marker itself — it reads
# each deferred AC's own justification text (whichever form the PRD used)
# and flags it when that text mentions live/real/box, the same words the
# problem statement's own sweep looked for. Two justification forms are
# read, since both are observed in the corpus:
#   - `deferred_ac_reasons:` inline JSON, keyed by AC number
#     (`{"15": "...", "16": "..."}`) — scan-prds.sh does not parse this
#     key's VALUE yet (see archive-trailer.sh's header), so this script
#     reads it directly from the file, same as it reads mock_justifications.
#   - `mock_justifications:` — either a YAML-ish block list (`mock_
#     justifications:` alone on its own line, followed by `- AC<N> ...`
#     bullets, one AC number per bullet) or a single inline sentence
#     (`mock_justifications: <prose>`, applied to every AC that PRD
#     deferred, since the inline form does not disambiguate per-AC).
#
# Usage:
#   live-ac-report.sh [--prd-dir <dir>] [--format text|json]
#
# Env:
#   PRD_DIR                  shared PRDs checkout (default ~/Documents/PRDs)
#   LOOP_TOOLING_REPOS_FILE  loop-tooling scope file (default
#                            scripts/loop-tooling-repos.txt, same file
#                            prd-lint.sh/scan-prds.sh/verified-completed.sh
#                            all read)
#
# Output (text, default): one line per candidate --
#   <slug>  AC<N>  <reason, truncated to 80 chars>
# followed by a summary line: `live-ac-report: <n> candidate(s)`.
# --format json: {"candidates":[{"slug":..,"ac":N,"reason":".."}, ...],
#                 "count":n}
#
# Exit: 0 always (a report never fails the caller on a clean run) | 2 on
# a usage error (unreadable PRD_DIR, bad --format).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
LOOP_TOOLING_REPOS_FILE="${LOOP_TOOLING_REPOS_FILE:-$HERE/loop-tooling-repos.txt}"
format=text

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prd-dir) PRD_DIR="${2:-}"; shift 2 ;;
    --prd-dir=*) PRD_DIR="${1#--prd-dir=}"; shift ;;
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#--format=}"; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "live-ac-report: unknown arg $1" >&2; exit 2 ;;
  esac
done
case "$format" in text|json) ;; *) echo "live-ac-report: bad --format $format" >&2; exit 2 ;; esac
[ -d "$PRD_DIR" ] || { echo "live-ac-report: PRD_DIR not a directory: $PRD_DIR" >&2; exit 2; }

built_dirs=()
for d in "$PRD_DIR/built-prds" "$PRD_DIR/ARCHIVE" "$PRD_DIR/archive"; do
  [ -d "$d" ] && built_dirs+=("$d")
done

python3 - "$LOOP_TOOLING_REPOS_FILE" "$format" "${built_dirs[@]}" <<'PY'
import glob
import json
import os
import re
import sys

repos_file, fmt = sys.argv[1], sys.argv[2]
built_dirs = sys.argv[3:]

def load_loop_tooling_repos(path):
    repos = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                repos.append(line.rstrip("/"))
    except OSError:
        pass
    return repos

LOOP_TOOLING_REPOS = load_loop_tooling_repos(repos_file)

def is_loop_tooling(build_into):
    if not build_into:
        return False
    bi = build_into.rstrip("/")
    for repo in LOOP_TOOLING_REPOS:
        if bi == repo or bi.startswith(repo + "/"):
            return True
    return False

FM_RE = re.compile(r'^-\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$')
LIVE_REAL_BOX_RE = re.compile(r'live|real|box', re.I)

def parse_frontmatter(lines):
    """Best-effort `- key: value` scan over the first ~60 lines (past the
    title, before the body) -- same shape scan-prds.sh itself reads,
    lighter-weight since this script only needs three keys."""
    fm = {}
    for ln in lines[:60]:
        m = FM_RE.match(ln.rstrip("\n"))
        if m:
            fm.setdefault(m.group(1).lower(), m.group(2).strip())
    return fm

def parse_deferred_acs(raw):
    if not raw:
        return []
    m = re.match(r'^\[\s*(\d+(?:\s*,\s*\d+)*)\s*\]$', raw.strip())
    if not m:
        return []
    return [int(n) for n in re.findall(r'\d+', m.group(1))]

def parse_deferred_ac_reasons(raw):
    if not raw:
        return {}
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return {str(k): str(v) for k, v in obj.items()}
    except (ValueError, TypeError):
        pass
    return {}

def parse_mock_justifications(lines, fm_raw):
    """Two forms, both observed in the corpus: a block list (the key
    alone on its own line, followed by `- AC<N> ...` bullets) or a single
    inline sentence (the key's own line carries the whole value). Block
    list returns a per-AC dict; inline returns {"*": "<sentence>"} --
    applied to every deferred AC on that PRD, since the inline form names
    no single AC."""
    if fm_raw:
        return {"*": fm_raw}
    key_re = re.compile(r'^-\s*mock_justifications\s*:\s*$', re.I)
    start = None
    for i, ln in enumerate(lines[:200]):
        if key_re.match(ln.strip()):
            start = i + 1
            break
    if start is None:
        return {}
    item_re = re.compile(r'^\s*-\s*(.*)$')
    ac_re = re.compile(r'^"?AC\s*(\d+)\b', re.I)
    result = {}
    cur = None
    for ln in lines[start:]:
        s = ln.rstrip("\n")
        if not s.strip():
            break
        m = item_re.match(s)
        if not m:
            break
        text = m.group(1).strip()
        if len(text) >= 2 and text[0] == text[-1] == '"':
            text = text[1:-1]
        am = ac_re.match(text)
        if am:
            cur = am.group(1)
            result[cur] = text
        elif cur is not None:
            result[cur] += " " + text
    return result

candidates = []
for d in built_dirs:
    for path in sorted(glob.glob(os.path.join(d, "PRD-*.md"))):
        slug = os.path.basename(path)[len("PRD-"):-len(".md")]
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        fm = parse_frontmatter(lines)
        build_into = fm.get("build_into", "")
        if not is_loop_tooling(build_into):
            continue
        deferred = parse_deferred_acs(fm.get("deferred_acs", ""))
        if not deferred:
            continue
        reasons_json = parse_deferred_ac_reasons(fm.get("deferred_ac_reasons", ""))
        mock = parse_mock_justifications(lines, fm.get("mock_justifications", ""))
        for n in deferred:
            reason = reasons_json.get(str(n)) or mock.get(str(n)) or mock.get("*") or ""
            if reason and LIVE_REAL_BOX_RE.search(reason):
                candidates.append({
                    "slug": slug,
                    "ac": n,
                    "reason": reason[:80],
                })

if fmt == "json":
    print(json.dumps({"candidates": candidates, "count": len(candidates)}))
else:
    for c in candidates:
        print(f"{c['slug']}  AC{c['ac']}  {c['reason']}")
    print(f"live-ac-report: {len(candidates)} candidate(s)")
PY
