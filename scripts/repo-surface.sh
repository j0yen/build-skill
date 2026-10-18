#!/usr/bin/env bash
# repo-surface.sh — the CLI/module "surface" of a repo, GENERATED from the repo
# itself (PRD-build-prd-lint-cross-repo-ac). prd-lint.sh's
# ac-names-foreign-surface check asks "does this backticked command belong to
# the repo the PRD builds into, or to another repo?"; the valid set per repo is
# read from the repo, never typed into a list here or in the lint.
#
# Usage:
#   repo-surface.sh <repo-path>              one token per line (sorted, unique)
#   repo-surface.sh --all [<dir>...] [--json]   the fleet map (repo -> tokens)
#
# Surface of <repo-path> (depth <= 1, same reach as substrate-probe.sh: the
# repo root plus any immediate subdirectory holding the marker):
#   Cargo:   [package] name, every [[bin]] name, src/bin/*.rs stems,
#            src/bin/<dir>/main.rs dir names
#   Python:  every [project.scripts] key, every src/<pkg>/*.py and
#            <pkg>/*.py stem except __init__ / _*  (a root-level <pkg> must
#            hold an __init__.py so tests/, docs/ and the like do not count)
#   Shell:   (repo root only) scripts/*.sh stems and bin/* names
# A path with none of those (or no such directory) prints nothing and exits 0.
#
# `--all`: the fleet map. The set of repos is the distinct `build_into` values
# of the PRDs in the given corpus directories (default
# $PRD_DIR/{build-queue,built-prds,parked}, PRD_DIR defaulting to
# ~/Documents/PRDs) -- the corpus owns "which repos exist". Text output is
# `<repo><TAB><tokens space-joined>` per repo present on this host, then one
# `# missing on this host: <path>` line per absent repo. `--json` prints
# {"repos": {path: [tokens]}, "missing": [paths]} (prd-lint.sh reads this).
# Two spellings of one repo (symlinks) collapse to the first one seen.
#
# Cache: $PRD_LINT_CACHE/surface/<sha256 of realpath>-<HEAD sha>.txt (default
# PRD_LINT_CACHE=${XDG_CACHE_HOME:-~/.cache}/prd-lint); a non-git path is
# never cached. A cache file whose first line is not the current schema tag is
# ignored, so changing the rules above cannot serve stale tokens.
#
# Exit: 0 always for a readable invocation (a probe, not a gate); 2 = usage.
set -uo pipefail

usage() {
  echo "usage: repo-surface.sh <repo-path>" >&2
  echo "       repo-surface.sh --all [<dir>...] [--json]" >&2
}

mode="path"
json=0
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) mode="all"; shift ;;
    --json) json=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do args+=("$1"); shift; done ;;
    -*) echo "repo-surface: unknown flag: $1" >&2; usage; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "$mode" = "path" ]; then
  [ "${#args[@]}" -eq 1 ] || { usage; exit 2; }
  [ "$json" -eq 0 ] || { usage; exit 2; }
fi

python3 - "$mode" "$json" "${args[@]}" <<'PY'
import hashlib, itertools, json, os, re, subprocess, sys

mode, as_json, args = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]

SCHEMA_TAG = "#surface-v1"
CACHE_ROOT = os.environ.get("PRD_LINT_CACHE") or os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "prd-lint")

SECTION_RE = re.compile(r"^\s*\[\[?\s*([A-Za-z0-9_.\"' -]+?)\s*\]\]?\s*(?:#.*)?$")
KV_RE = re.compile(r"""^\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_.-]+))\s*=\s*(.*)$""")
VAL_RE = re.compile(r"""^(?:"([^"]*)"|'([^']*)')""")
TOKEN_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


def toml_pairs(path):
    """(section, key, value-or-None) for every `key = value` line, with the
    section header it sits under. A minimal scanner: it reads exactly the
    tables this script needs ([package], [[bin]], [project.scripts]), so no
    TOML library is required on a host that lacks one."""
    out = []
    section = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return out
    for raw in lines:
        m = SECTION_RE.match(raw)
        if m and not KV_RE.match(raw):
            section = m.group(1).strip().replace('"', "").replace("'", "")
            continue
        m = KV_RE.match(raw)
        if not m:
            continue
        key = m.group(1) or m.group(2) or m.group(3)
        vm = VAL_RE.match(m.group(4).strip())
        val = (vm.group(1) if vm and vm.group(1) is not None else (vm.group(2) if vm else None))
        out.append((section, key, val))
    return out


def marker_bases(root, filename):
    """root itself if it holds `filename`, plus every immediate subdirectory
    that does (substrate-probe.sh's depth<=1 reach)."""
    bases = []
    if os.path.isfile(os.path.join(root, filename)):
        bases.append(root)
    try:
        names = sorted(os.listdir(root))
    except OSError:
        names = []
    for n in names:
        sub = os.path.join(root, n)
        if os.path.isdir(sub) and os.path.isfile(os.path.join(sub, filename)):
            bases.append(sub)
    return bases


def py_stems(d):
    out = set()
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        if n.endswith(".py") and os.path.isfile(os.path.join(d, n)):
            stem = n[:-3]
            if stem != "__init__" and not stem.startswith("_"):
                out.add(stem)
    return out


def compute_surface(root):
    toks = set()
    if not os.path.isdir(root):
        return toks
    # Cargo
    for base in marker_bases(root, "Cargo.toml"):
        for section, key, val in toml_pairs(os.path.join(base, "Cargo.toml")):
            if key == "name" and val and section in ("package", "bin"):
                toks.add(val)
        bindir = os.path.join(base, "src", "bin")
        if os.path.isdir(bindir):
            for n in os.listdir(bindir):
                p = os.path.join(bindir, n)
                if n.endswith(".rs") and os.path.isfile(p):
                    toks.add(n[:-3])
                elif os.path.isfile(os.path.join(p, "main.rs")):
                    toks.add(n)
    # Python
    for base in marker_bases(root, "pyproject.toml"):
        for section, key, val in toml_pairs(os.path.join(base, "pyproject.toml")):
            if section == "project.scripts":
                toks.add(key)
        srcdir = os.path.join(base, "src")
        if os.path.isdir(srcdir):
            for n in sorted(os.listdir(srcdir)):
                if not n.startswith((".", "_")) and os.path.isdir(os.path.join(srcdir, n)):
                    toks |= py_stems(os.path.join(srcdir, n))
        for n in sorted(os.listdir(base)):
            p = os.path.join(base, n)
            if (not n.startswith((".", "_")) and os.path.isdir(p)
                    and os.path.isfile(os.path.join(p, "__init__.py"))):
                toks |= py_stems(p)
    # Shell (repo root only)
    sdir = os.path.join(root, "scripts")
    if os.path.isdir(sdir):
        for n in os.listdir(sdir):
            if n.endswith(".sh") and os.path.isfile(os.path.join(sdir, n)):
                toks.add(n[:-3])
    bdir = os.path.join(root, "bin")
    if os.path.isdir(bdir):
        for n in os.listdir(bdir):
            if os.path.isfile(os.path.join(bdir, n)):
                toks.add(n)
    return {t for t in toks if TOKEN_OK.match(t)}


def head_sha(root):
    try:
        r = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    sha = r.stdout.strip()
    return sha if r.returncode == 0 and re.match(r"^[0-9a-f]{7,64}$", sha) else ""


def surface(path):
    """Sorted token list for `path`, served from the HEAD-keyed cache when
    the path is a git checkout."""
    root = os.path.realpath(path)
    if not os.path.isdir(root):
        return []
    head = head_sha(root)
    cfile = ""
    if head:
        key = hashlib.sha256(root.encode("utf-8")).hexdigest()
        cfile = os.path.join(CACHE_ROOT, "surface", f"{key}-{head}.txt")
        try:
            with open(cfile, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
            if lines and lines[0] == SCHEMA_TAG:
                return [l for l in lines[1:] if l]
        except OSError:
            pass
    toks = sorted(compute_surface(root))
    if cfile:
        try:
            os.makedirs(os.path.dirname(cfile), exist_ok=True)
            tmpf = cfile + f".{os.getpid()}.tmp"
            with open(tmpf, "w", encoding="utf-8") as fh:
                fh.write(SCHEMA_TAG + "\n" + "".join(t + "\n" for t in toks))
            os.replace(tmpf, cfile)
        except OSError:
            pass  # an unwritable cache only costs a recompute
    return toks


# -- fleet map ---------------------------------------------------------------
# First-match-wins scan of the first 80 lines, skipping fenced blocks, bullet /
# bare / bold key forms alike: the same reading as prd-lint.sh's
# parse_frontmatter and scan-prds.sh (kept in step by hand, duplicated rather
# than shelled out per this repo's convention).
def build_into_of(path):
    in_fence = False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = list(itertools.islice(fh, 80))
    except OSError:
        return ""
    for raw in lines:
        line = raw.rstrip("\n")
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        k = re.sub(r"^[-*+]\s+", "", line)
        k = re.sub(r"^\s*\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
        m = re.match(r"^\s*([A-Za-z][A-Za-z _-]*)\s*:\s*(.*)$", k)
        if not m or m.group(1).strip().lower().replace(" ", "_") != "build_into":
            continue
        v = re.sub(r"\s+#.*$", "", m.group(2)).strip()
        if len(v) >= 2 and v[0] == v[-1] == '"':
            v = v[1:-1]
        return v
    return ""


def corpus_dirs(given):
    if given:
        return list(given)
    prd_dir = os.environ.get("PRD_DIR") or os.path.expanduser("~/Documents/PRDs")
    return [os.path.join(prd_dir, d) for d in ("build-queue", "built-prds", "parked")]


def fleet(dirs):
    """({as-written path: tokens}, [missing paths]) over the distinct
    build_into values of PRD-*.md in `dirs`. Values that are not a plain
    path (prose such as "(new repo) `~/x`") are not repos and are skipped."""
    seen_real = {}
    repos = {}
    missing = []
    values = set()
    for d in dirs:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.startswith("PRD-") and n.endswith(".md"):
                v = build_into_of(os.path.join(d, n))
                if v.startswith("~"):
                    v = os.path.expanduser(v)
                if v.startswith("/"):
                    values.add(v.rstrip("/") or "/")
    for v in sorted(values):
        if not os.path.isdir(v):
            missing.append(v)
            continue
        real = os.path.realpath(v)
        if real in seen_real:
            continue
        seen_real[real] = v
        repos[v] = surface(v)
    return repos, missing


if mode == "path":
    for t in surface(args[0]):
        print(t)
    sys.exit(0)

repos, missing = fleet(corpus_dirs(args))
if as_json:
    print(json.dumps({"repos": repos, "missing": missing}, indent=1, sort_keys=True))
else:
    for r in sorted(repos):
        print(f"{r}\t{' '.join(repos[r])}")
    for m in missing:
        print(f"# missing on this host: {m}")
sys.exit(0)
PY
