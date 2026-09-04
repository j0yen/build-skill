#!/usr/bin/env bash
# prd-lint.sh — deterministic contract-shape lint for a PRD, run before a
# model ever spends a cycle on it (PRD-build-prd-lint).
#
# Three real 2026-09-03/04 defects motivated this: a `deferred_acs` written
# as prose (parses to `[]` silently per the contract); a `Depends-on` that
# would have deadlocked two PRDs on each other's output; and an acceptance
# criterion that pinned a rollback base to a fixed SHA, which no later squash
# could satisfy. None needed a model to catch — this script catches them in
# well under 200ms.
#
# Usage:
#   prd-lint.sh <file>... [--format text|json]
#
# Exit: 0 = every file clean (warnings allowed), 1 = at least one FAIL
#       anywhere, 2 = usage error.
#
# Checks reuse the contract in build-contract.md; keep the two in step.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: prd-lint.sh <file>... [--format text|json]" >&2
}

format="text"
files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      shift
      format="${1:-}"
      [ -n "$format" ] || { usage; exit 2; }
      shift
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do files+=("$1"); shift; done
      ;;
    -*)
      echo "prd-lint: unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

if [ "${#files[@]}" -eq 0 ]; then
  usage
  exit 2
fi
case "$format" in
  text|json) ;;
  *) echo "prd-lint: --format must be text or json" >&2; exit 2 ;;
esac

for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "prd-lint: no such file: $f" >&2
    exit 2
  fi
done

# All the real work happens in one python3 process so the whole batch stays
# well under the 200ms/PRD budget even with cross-file cycle detection.
python3 - "$format" "${files[@]}" <<'PY'
import json, os, re, sys

fmt = sys.argv[1]
targets = sys.argv[2:]

# Contract's build_target set (build-contract.md). "product" is valid but
# skipped, not built -- still a legal value here.
VALID_TARGETS = {
    "rust-cli", "rust-lib", "rust-extend", "kernel-extend", "shell",
    "hooks", "config", "notebook", "mixed",
    "python-cli", "python-lib", "python-agent", "product",
}
EXTEND_TARGETS = {"rust-extend", "kernel-extend"}
SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
FILENAME_RE = re.compile(r"^PRD-([a-z0-9]+(?:-[a-z0-9]+)*)\.md$")
AC_HEADING_RE = re.compile(r"^##\s+Acceptance(?:\s+(criteria|tests))?\s*$", re.I)
AC_NUM_RE = re.compile(r"^(\d+)\.\s+(.*)$")
AC_LEVELED_RE = re.compile(r"^\d+\.\s+P[0-2]\s*[—–-]\s*")
AC_LEGACY_RE = re.compile(r"^AC-\d+\s*:")
SHA40_RE = re.compile(r"\b[0-9a-f]{40}\b")
BASE_SHA_RE = re.compile(r"--base\s+([0-9a-f]{7,40})\b")
HOME_PATH_RE = re.compile(r"/home/[A-Za-z0-9_.-]+/")


def strip_val(v):
    v = re.sub(r"\s+#.*$", "", v)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == '"':
        v = v[1:-1]
    return v


def parse_frontmatter(path):
    """First-match-wins scan of the first 80 lines, skipping fenced blocks.
    Bullet (`- key: value`), bare (`key: value`), and bold (`**key:**
    value`) forms all read the same, mirroring scan-prds.sh."""
    fields = {}
    in_fence = False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()[:80]
    except OSError:
        return fields
    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        k = re.sub(r"^[-*+]\s+", "", line)
        k = re.sub(r"^\s*\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
        m = re.match(r"^\s*([A-Za-z][A-Za-z _-]*)\s*:\s*(.*)$", k)
        if not m:
            continue
        key = m.group(1).strip().lower().replace(" ", "_")
        if key in fields:
            continue
        fields[key] = strip_val(m.group(2))
    return fields


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []


def ac_section_lines(all_lines):
    """Lines strictly inside the acceptance-criteria section (excluding the
    heading itself), stopping at the next top-level heading."""
    out = []
    in_section = False
    for line in all_lines:
        if AC_HEADING_RE.match(line.strip()):
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if in_section:
            out.append(line)
    return out, in_section


def queue_dirs_for(path):
    """Resolve the sibling queue directories used for Depends-on lookups and
    cycle detection. A file under .../build-queue/ or .../built-prds/ pulls
    in both siblings under the same PRD workspace root; anything else (e.g.
    a self-test fixture directory) just uses its own directory."""
    d = os.path.dirname(os.path.abspath(path)) or "."
    base = os.path.basename(d)
    if base in ("build-queue", "built-prds"):
        root = os.path.dirname(d)
        dirs = [os.path.join(root, "build-queue"), os.path.join(root, "built-prds")]
        return [x for x in dirs if os.path.isdir(x)]
    return [d]


def slug_of(path):
    name = os.path.basename(path)
    m = FILENAME_RE.match(name)
    if m:
        return m.group(1)
    return re.sub(r"^PRD-", "", name[:-3] if name.endswith(".md") else name)


def parse_depends_on(raw):
    if not raw:
        return []
    return [t.strip() for t in raw.split(",") if t.strip()]


_graph_cache = {}


def build_graph(dirs):
    """slug -> set(depends-on slugs), plus slug -> filename, over every
    PRD-*.md found in `dirs`. Cached per unique dir-tuple within this run."""
    key = tuple(sorted(dirs))
    if key in _graph_cache:
        return _graph_cache[key]
    graph = {}
    fname_by_slug = {}
    for d in dirs:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for name in names:
            if not (name.startswith("PRD-") and name.endswith(".md")):
                continue
            fpath = os.path.join(d, name)
            fm = parse_frontmatter(fpath)
            deps = parse_depends_on(fm.get("depends-on", ""))
            dep_slugs = set()
            for dep in deps:
                dep_slugs.add(slug_of(dep))
            s = slug_of(name)
            graph[s] = dep_slugs
            fname_by_slug[s] = name
    _graph_cache[key] = (graph, fname_by_slug)
    return graph, fname_by_slug


def find_cycle(graph, start):
    """DFS from `start`; returns the cycle as a list of slugs (start..start)
    if one exists reachable from start, else None."""
    stack = [(start, [start])]
    seen_paths = set()
    while stack:
        node, path = stack.pop()
        for nxt in graph.get(node, ()):
            if nxt == start:
                return path + [nxt]
            if nxt in path:
                continue  # a cycle not involving start; not this file's problem
            key = (nxt, tuple(path))
            if key in seen_paths:
                continue
            seen_paths.add(key)
            stack.append((nxt, path + [nxt]))
    return None


def lint_file(path):
    fails = []
    warns = []

    def fail(cid, msg):
        fails.append({"id": cid, "message": msg})

    def warn(cid, msg):
        warns.append({"id": cid, "message": msg})

    name = os.path.basename(path)
    slug = slug_of(path)
    if not FILENAME_RE.match(name):
        fail("slug-invalid", f"filename {name!r} must match PRD-<slug>.md with slug matching ^[a-z0-9]+(-[a-z0-9]+)*$")
    elif not SLUG_RE.match(slug):
        fail("slug-invalid", f"slug {slug!r} must match ^[a-z0-9]+(-[a-z0-9]+)*$")

    fm = parse_frontmatter(path)
    all_lines = read_lines(path)
    prd_root = os.path.dirname(os.path.dirname(os.path.abspath(path))) if os.path.basename(os.path.dirname(os.path.abspath(path))) in ("build-queue", "built-prds") else os.path.dirname(os.path.abspath(path))

    # -- frontmatter presence -------------------------------------------------
    if "status" not in fm:
        fail("status-missing", "no `Status:` line found in the first 80 lines")

    build_target = fm.get("build_target")
    if not build_target:
        fail("build-target-missing", "no `build_target:` line found in the first 80 lines")
    elif build_target not in VALID_TARGETS:
        fail("build-target-unknown", f"build_target {build_target!r} is not in the contract's set: {sorted(VALID_TARGETS)}")

    vision = fm.get("vision")
    if not vision:
        fail("vision-missing", "no `Vision:` line found in the first 80 lines")
    else:
        vpath = vision if os.path.isabs(vision) else os.path.join(prd_root, vision)
        if not os.path.isfile(vpath):
            fail("vision-not-found", f"Vision file not found: {vision} (resolved {vpath})")

    # -- build_into ------------------------------------------------------------
    build_into = fm.get("build_into")
    if build_target in EXTEND_TARGETS and not build_into:
        fail("build-into-missing", f"build_target {build_target!r} requires a `build_into:` path")
    if build_into and not os.path.isdir(build_into):
        # Downgraded to a warning: a PRD's build_into commonly lives on a
        # different fleet host (e.g. RedBaron for Rust) than wherever this
        # lint happens to run.
        warn("build-into-not-found", f"build_into {build_into!r} does not exist on this host (may be a different build host)")

    # -- deferred_acs ------------------------------------------------------------
    deferred_raw = fm.get("deferred_acs")
    if deferred_raw:
        if re.match(r"^\[\s*\d+(\s*,\s*\d+)*\s*\]$", deferred_raw) or re.match(r"^\[\s*\]$", deferred_raw):
            is_list = True
            has_items = bool(re.match(r"^\[\s*\d+", deferred_raw))
        else:
            is_list = False
            has_items = False
        if not is_list:
            fail("deferred-acs-prose", "deferred_acs must be a list, e.g. [15, 16]")
        elif has_items and "mock_justifications" not in fm:
            fail("deferred-acs-missing-justification", "deferred_acs is a non-empty list but no `mock_justifications:` line was found")

    # -- Depends-on: existence + cycle -------------------------------------------
    depends_raw = fm.get("depends-on")
    deps = parse_depends_on(depends_raw) if depends_raw else []
    dirs = queue_dirs_for(path)
    if deps:
        missing = []
        for dep in deps:
            found = any(os.path.isfile(os.path.join(d, dep)) for d in dirs)
            if not found:
                missing.append(dep)
        if missing:
            fail("depends-on-missing", f"Depends-on names file(s) not found in build-queue/ or built-prds/: {', '.join(missing)}")

        graph, fname_by_slug = build_graph(dirs)
        graph.setdefault(slug, set()).update(slug_of(d) for d in deps)
        cycle = find_cycle(graph, slug)
        if cycle:
            loop = " -> ".join(fname_by_slug.get(s, f"PRD-{s}.md") for s in cycle)
            fail("depends-on-cycle", f"Depends-on graph has a cycle: {loop}")

        # possible-deadlock pattern: a dependency's own body text names this
        # PRD's slug (not a structural cycle, but the same shape of mistake).
        for dep in deps:
            for d in dirs:
                dep_path = os.path.join(d, dep)
                if not os.path.isfile(dep_path):
                    continue
                dep_text = "\n".join(read_lines(dep_path))
                # Require the `PRD-<slug>` naming convention, not a bare
                # word match, so a common-English slug (or a single-letter
                # one in tests) doesn't false-positive on ordinary prose.
                if re.search(r"\bPRD-" + re.escape(slug) + r"\b", dep_text):
                    warn("depends-on-possible-deadlock", f"{dep} names this PRD's slug ({slug}) in its own text — possible deadlock")
                break

    # -- Loop: -----------------------------------------------------------------
    if vision:
        vpath = vision if os.path.isabs(vision) else os.path.join(prd_root, vision)
        if os.path.isfile(vpath):
            vtext = "\n".join(read_lines(vpath))
            has_loop_contract = bool(re.search(r"^##\s+Loop\b", vtext, re.M)) or bool(re.search(r"^Loop:", vtext, re.M))
            if has_loop_contract and "loop" not in fm:
                fail("loop-missing", f"vision {vision} declares a Loop contract but this PRD has no `Loop:` line")

    # -- Acceptance criteria section --------------------------------------------
    section, found_heading = ac_section_lines(all_lines)
    if not found_heading:
        fail("ac-section-missing", "no `## Acceptance criteria` (or `## Acceptance` / `## Acceptance tests`) section found")
    else:
        legacy = [l for l in section if AC_LEGACY_RE.match(l.strip())]
        if legacy:
            fail("ac-legacy-format", f"found `AC-N:` style line(s), use `N. P0 — Given/When/Then`: {legacy[0].strip()!r}")

        # Group each `N. ...` line with its indented continuation lines (many
        # ACs in this workspace wrap across 2-3 lines for readability) into
        # one logical item, so Given/When/Then and pattern checks see the
        # whole acceptance criterion, not just its first line.
        items = []
        cur = None
        for l in section:
            if AC_NUM_RE.match(l.strip()):
                if cur is not None:
                    items.append(cur)
                cur = [l.strip()]
            elif cur is not None and l.strip():
                cur.append(l.strip())
            elif cur is not None and not l.strip():
                items.append(cur)
                cur = None
        if cur is not None:
            items.append(cur)
        leveled_items = [it for it in items if AC_LEVELED_RE.match(it[0])]
        if not leveled_items:
            fail("ac-no-lines", "no `N. P[0-2] —` acceptance-criterion line found")
        else:
            for it in leveled_items:
                s = " ".join(it)
                missing_tokens = [t for t in ("Given", "When", "Then") if t not in s]
                if missing_tokens:
                    fail("ac-missing-gwt", f"AC line missing {', '.join(missing_tokens)}: {it[0]!r}")

        # pattern check: pinned SHA in an AC of an extend PRD
        if build_target in EXTEND_TARGETS:
            for it in leveled_items:
                s = " ".join(it)
                if SHA40_RE.search(s) or BASE_SHA_RE.search(s):
                    warn("pinned-sha-in-ac", f"pin to a tag or a relative base, not a fixed SHA: {it[0]!r}")

        # pattern check: a /home/ path in an AC
        for it in leveled_items:
            s = " ".join(it)
            if HOME_PATH_RE.search(s):
                warn("home-path-in-ac", f"AC references a path under /home/: {it[0]!r}")

    return slug, fails, warns


results = []
any_fail = False
for path in targets:
    slug, fails, warns = lint_file(path)
    if fails:
        any_fail = True
    results.append({
        "file": path,
        "slug": slug,
        "ok": not fails,
        "failures": fails,
        "warnings": warns,
    })

if fmt == "json":
    print(json.dumps(results, indent=2))
else:
    multi = len(results) > 1
    for r in results:
        if multi:
            print(f"== {r['file']} ==")
        if not r["failures"] and not r["warnings"]:
            print("OK")
            continue
        n = 0
        for f in r["failures"]:
            n += 1
            print(f"{n}. FAIL {f['id']}: {f['message']}")
        for w in r["warnings"]:
            n += 1
            print(f"{n}. WARN {w['id']}: {w['message']}")

sys.exit(1 if any_fail else 0)
PY
exit $?
