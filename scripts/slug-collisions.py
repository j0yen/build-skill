#!/usr/bin/env python3
"""slug-collisions.py — corpus-level PRD slug uniqueness scanner
(PRD-build-prd-slug-uniqueness).

A slug ("PRD-<slug>.md") should resolve to exactly one file across
build-queue/, built-prds/, and parked/. archive-commit.sh briefly leaves
the SAME PRD in two of those directories within one commit (queue copy
about to be removed, built-prds copy just added) -- that transitional
window is NOT a collision: it is tolerated when there are exactly two
copies and both have an identical title (the file's first `# ` heading)
and an identical `Drafted:` frontmatter value. Anything else -- three or
more copies, or two copies that differ in title or Drafted date -- is a
real collision: two different PRDs sharing one slug (the
build-post-ship-reality-check incident this PRD was drafted from).

Usage:
  slug-collisions.py [--prd-dir DIR] [--slug SLUG]

--prd-dir   PRD workspace root (default $HOME/Documents/PRDs), containing
            build-queue/, built-prds/, parked/.
--slug      Restrict the report to this one slug (still scans the whole
            corpus; just filters the printed result). Omit to report every
            collision in the corpus.

Output: a JSON array on stdout, one object per colliding slug:
  {"slug": "...", "paths": ["...", ...], "titles": ["...", ...],
   "drafted": ["...", ...]}
Always exits 0 -- this is a read-only report; callers decide what a
non-empty array means for them (lint failure, scan suppression, a
manifest-set.sh refusal, ...).
"""
import argparse
import json
import os
import re
import sys

DIR_NAMES = ("build-queue", "built-prds", "parked")
DRAFTED_RE = re.compile(r"^\s*[-*+]?\s*\**drafted\**\s*:\**\s*(.+?)\s*$", re.I)


def title_of(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("# "):
                    return s[2:].strip()
    except OSError:
        pass
    return ""


def drafted_of(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh.readlines()[:80]:
                m = DRAFTED_RE.match(line.rstrip("\n"))
                if m:
                    return m.group(1).strip()
    except OSError:
        pass
    return ""


def find_collisions(prd_dir):
    dirs = {name: os.path.join(prd_dir, name) for name in DIR_NAMES}
    names_by_file = {}
    for name in DIR_NAMES:
        d = dirs[name]
        if not os.path.isdir(d):
            continue
        try:
            entries = sorted(os.listdir(d))
        except OSError:
            continue
        for fname in entries:
            if not (fname.startswith("PRD-") and fname.endswith(".md")):
                continue
            names_by_file.setdefault(fname, []).append(os.path.join(d, fname))

    collisions = []
    for fname, paths in sorted(names_by_file.items()):
        if len(paths) < 2:
            continue
        titles = [title_of(p) for p in paths]
        drafted = [drafted_of(p) for p in paths]
        if len(paths) == 2 and titles[0] == titles[1] and drafted[0] == drafted[1]:
            continue  # transitional window (archive-commit mid-move), not a collision
        slug = fname[len("PRD-"):-len(".md")]
        collisions.append({
            "slug": slug, "paths": paths, "titles": titles, "drafted": drafted,
        })
    return collisions


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument(
        "--prd-dir",
        default=os.environ.get("PRD_DIR") or os.path.join(os.path.expanduser("~"), "Documents", "PRDs"),
    )
    ap.add_argument("--slug", default=None)
    args = ap.parse_args(argv)

    collisions = find_collisions(args.prd_dir)
    if args.slug:
        collisions = [c for c in collisions if c["slug"] == args.slug]
    print(json.dumps(collisions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
