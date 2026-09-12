#!/usr/bin/env python3
"""burst-lane-pathdeps.py — local path-dependency discovery + manifest
rewrite for burst-lane.sh's remote `run` (PRD-build-burst-path-deps).

A regex-driven Cargo.toml reader (not a full TOML parser — consistent with
this skill's existing pragmatic parsing elsewhere, e.g. the PRD frontmatter
reader in build-contract.md) that answers exactly the two questions
burst-lane.sh's `run` needs before it can sync a crate with path
dependencies to the box:

  discover <manifest.toml> [workspace_root]
      Prints one absolute directory per line: every transitive path
      dependency of <manifest.toml> — its own [dependencies] /
      [dev-dependencies] / [build-dependencies] / [target.*.dependencies]
      `path = "..."` entries (both the `[dependencies.name]` table form and
      the inline `name = { path = "...", ... }` form), recursively through
      each discovered dependency's own Cargo.toml. Cycle-safe (a seen-set
      of resolved directories, so a dependency cycle or a diamond shape
      is only ever synced once). The root manifest's own directory is
      never printed.

      [workspace_root] (PRD-build-burst-path-deps-workspaces requirement 1):
      an optional absolute path. Any dependency directory that resolves
      INSIDE it (equal to it or a descendant) is never printed — it is
      already part of the one-tree workspace-root sync burst-lane.sh's
      `run` performs for a workspace member, so mirroring it again under
      deps/ would recreate the very collision (the same package present at
      both <workspace_root>/crates/x and deps/x-<hash>) this PRD fixes.
      Recursion still descends into that dependency's own Cargo.toml, so a
      workspace member's OWN external sibling (outside the workspace
      entirely) is still discovered and printed.

  rewrite <manifest.toml> <local-to-remote-map.tsv>
      Prints <manifest.toml>'s content to stdout with every `path = "..."`
      value that RESOLVES (relative to <manifest.toml>'s own directory) to
      a key in the map rewritten to that key's mapped value. A `path =`
      line that resolves to something NOT in the map — a [[bin]]/[[test]]
      source file, a path dep this run didn't sync — is left byte-
      identical. The map is a plain two-column TSV (local_abs_dir TAB
      remote_abs_dir), one pair per line, matching this codebase's existing
      preference for plain text over an escaping-prone inline JSON string
      (see manifest-set.sh's own "patch file, never inline JSON" rule).
"""
import os
import re
import sys

# Matches a bare `path = "..."` line regardless of leading whitespace — the
# form every `[dependencies.name]` table uses for its own path entry.
PATH_LINE_RE = re.compile(r'^(?P<indent>\s*)path\s*=\s*"(?P<val>[^"]*)"')

# Matches an inline dependency table, e.g. `foo = { path = "../foo",
# version = "0.1" }` — captures the brace contents so a nested path=" can be
# located and rewritten in place without disturbing the rest of the line.
INLINE_DEP_RE = re.compile(
    r'^(?P<pre>\s*[A-Za-z0-9_.-]+\s*=\s*\{)(?P<inner>[^}]*)(?P<post>\}.*)$'
)
INLINE_PATH_RE = re.compile(r'(path\s*=\s*")(?P<val>[^"]*)(")')

DEP_TABLE_HEADER_RE = re.compile(
    r'^\[(?:dependencies|dev-dependencies|build-dependencies'
    r'|workspace\.dependencies|target\.[^\]]+\.dependencies)'
    r'(?:\.[A-Za-z0-9_.-]+)?\]\s*$'
)
ANY_HEADER_RE = re.compile(r'^\[+[^\[\]]+\]+\s*$')


def _manifest_dir(manifest_path):
    return os.path.dirname(os.path.abspath(manifest_path))


def find_path_deps(manifest_path):
    """-> list of absolute dependency directories declared directly by one
    Cargo.toml (not recursive). Covers both the `[dependencies.name]` table
    form and the inline `name = { path = "..." }` form under any bare
    dependency table ([dependencies], [dev-dependencies], etc.)."""
    manifest_dir = _manifest_dir(manifest_path)
    try:
        with open(manifest_path, "r") as fh:
            lines = fh.readlines()
    except OSError:
        return []
    in_dep_table = False
    found = []
    for line in lines:
        stripped = line.strip()
        if ANY_HEADER_RE.match(stripped):
            in_dep_table = bool(DEP_TABLE_HEADER_RE.match(stripped))
            continue
        if not in_dep_table:
            continue
        m = PATH_LINE_RE.match(line)
        if m:
            found.append(os.path.normpath(os.path.join(manifest_dir, m.group("val"))))
            continue
        im = INLINE_DEP_RE.match(line)
        if im:
            pm = INLINE_PATH_RE.search(im.group("inner"))
            if pm:
                found.append(os.path.normpath(os.path.join(manifest_dir, pm.group("val"))))
    return found


def discover(manifest_path, workspace_root=None):
    root_dir = os.path.normpath(_manifest_dir(manifest_path))
    seen_dirs = {root_dir}
    seen_manifests = set()
    out = []
    ws_root_norm = os.path.normpath(workspace_root) if workspace_root else None

    def in_workspace(d):
        if not ws_root_norm:
            return False
        return d == ws_root_norm or d.startswith(ws_root_norm + os.sep)

    stack = [os.path.abspath(manifest_path)]
    while stack:
        m = stack.pop()
        if m in seen_manifests:
            continue
        seen_manifests.add(m)
        for dep_dir in find_path_deps(m):
            if dep_dir in seen_dirs:
                continue
            seen_dirs.add(dep_dir)
            if not os.path.isdir(dep_dir):
                # A dangling path dependency (the exact real-world defect
                # this PRD's problem statement describes — "manifest path …
                # does not exist") has nothing for `run` to sync. Leaving it
                # out of `out` (and never recursing into it) means its
                # ORIGINAL relative path= is never rewritten either, so the
                # remote cargo invocation legitimately fails to resolve it
                # exactly as it does today — a genuine build/resolution
                # error, not an rsync error our own sync step invents.
                continue
            # PRD-build-burst-path-deps-workspaces requirement 1: a dep
            # already inside the workspace root arrives for free with the
            # workspace-root sync — never mirror it under deps/ too. Still
            # recurse into its manifest below, so a workspace member's own
            # OUTSIDE-the-workspace sibling is still found.
            if not in_workspace(dep_dir):
                out.append(dep_dir)
            dep_manifest = os.path.join(dep_dir, "Cargo.toml")
            if os.path.isfile(dep_manifest):
                stack.append(dep_manifest)
    return out


def _load_map(map_path):
    mapping = {}
    try:
        with open(map_path, "r") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or "\t" not in line:
                    continue
                local, remote = line.split("\t", 1)
                mapping[os.path.normpath(local)] = remote
    except OSError:
        pass
    return mapping


def rewrite(manifest_path, map_path):
    mapping = _load_map(map_path)
    manifest_dir = _manifest_dir(manifest_path)
    with open(manifest_path, "r") as fh:
        lines = fh.readlines()
    out_lines = []
    for line in lines:
        m = PATH_LINE_RE.match(line)
        if m:
            resolved = os.path.normpath(os.path.join(manifest_dir, m.group("val")))
            if resolved in mapping:
                out_lines.append(line[: m.start("val")] + mapping[resolved] + line[m.end("val"):])
                continue
            out_lines.append(line)
            continue
        im = INLINE_DEP_RE.match(line)
        if im:
            pm = INLINE_PATH_RE.search(im.group("inner"))
            if pm:
                resolved = os.path.normpath(os.path.join(manifest_dir, pm.group("val")))
                if resolved in mapping:
                    new_inner = (
                        im.group("inner")[: pm.start("val")]
                        + mapping[resolved]
                        + im.group("inner")[pm.end("val"):]
                    )
                    out_lines.append(im.group("pre") + new_inner + im.group("post") + "\n")
                    continue
        out_lines.append(line)
    sys.stdout.write("".join(out_lines))


def main(argv):
    if len(argv) < 3:
        print(
            "usage: burst-lane-pathdeps.py {discover <manifest>|rewrite <manifest> <map.tsv>}",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    if cmd == "discover":
        ws_root = argv[3] if len(argv) > 3 and argv[3] else None
        for d in discover(argv[2], ws_root):
            print(d)
        return 0
    if cmd == "rewrite":
        if len(argv) < 4:
            print("usage: burst-lane-pathdeps.py rewrite <manifest> <map.tsv>", file=sys.stderr)
            return 2
        rewrite(argv[2], argv[3])
        return 0
    print("unknown subcommand: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
