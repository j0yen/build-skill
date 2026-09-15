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
#   prd-lint.sh <file|dir>... [--format text|json|pass-fail] [--quiet] [--contract <path>]
#
# `--format text` (the default) and `--format json` are the original,
# stable machine/human contracts -- scan-prds.sh's Phase-1 gate shells out
# with `--format json` and several selftests assert the single-clean-file
# default prints exactly `OK`, so neither is ever changed by this script;
# a regression there silently misclassifies the whole queue (see this
# script's own header history). `--format pass-fail` and `--quiet`
# (PRD-prd-contract-lint) are additive, opt-in surfaces layered on top:
#   pass-fail : one line per file, `PASS <file>` or
#               `FAIL <file>: <id>: <message>[, <id>: <message>...]`
#   --quiet   : implies pass-fail rendering and prints ONLY the FAIL lines
#               (no PASS lines) -- for a directory scan where only the
#               defects matter.
# A directory argument (in place of a file) expands to its immediate
# `PRD-*.md` files (not recursive).
# `--contract <path>` re-derives the accepted `build_target` set from a
# build-contract.md-shaped file's `| \`build_target\` | ... |` row instead
# of the hardcoded set below (for testing against a modified contract);
# on parse failure this falls back to the hardcoded set and warns on
# stderr rather than failing every file.
#
# Exit: 0 = every file clean (warnings allowed), 1 = at least one FAIL
#       anywhere, 2 = usage error.
#
# Checks reuse the contract in build-contract.md; keep the two in step.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PRD-build-tenant-secret-continuity: exported so the python heredoc below
# can resolve state/secrets/<slug>/ without re-deriving SKILL_DIR itself.
export LINT_STATE_DIR="${BUILD_STATE_DIR:-$HERE/../state}"

usage() {
  echo "usage: prd-lint.sh <file|dir>... [--format text|json|pass-fail] [--quiet] [--contract <path>]" >&2
}

format="text"
quiet=0
contract=""
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
    --quiet)
      quiet=1
      shift
      ;;
    --contract)
      shift
      contract="${1:-}"
      [ -n "$contract" ] || { usage; exit 2; }
      shift
      ;;
    --contract=*)
      contract="${1#--contract=}"
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
  text|json|pass-fail) ;;
  *) echo "prd-lint: --format must be text, json, or pass-fail" >&2; exit 2 ;;
esac
# --quiet implies pass-fail rendering unless the caller explicitly asked
# for json (machine-parsed elsewhere -- quiet has no meaning there).
if [ "$quiet" -eq 1 ] && [ "$format" = "text" ]; then
  format="pass-fail"
fi

# Directory args expand to their immediate PRD-*.md files (non-recursive --
# a corpus dir like build-queue/ is flat by contract). Expanded in place so
# a mix of files and dirs on one command line works.
expanded=()
for f in "${files[@]}"; do
  if [ -d "$f" ]; then
    shopt -s nullglob
    matched=("$f"/PRD-*.md)
    shopt -u nullglob
    if [ "${#matched[@]}" -eq 0 ]; then
      echo "prd-lint: no PRD-*.md files in directory: $f" >&2
      exit 2
    fi
    expanded+=("${matched[@]}")
  else
    expanded+=("$f")
  fi
done
files=("${expanded[@]}")

for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "prd-lint: no such file: $f" >&2
    exit 2
  fi
done

if [ -n "$contract" ] && [ ! -f "$contract" ]; then
  echo "prd-lint: --contract file not found: $contract (falling back to the built-in build_target set)" >&2
  contract=""
fi

# All the real work happens in one python3 process so the whole batch stays
# well under the 200ms/PRD budget even with cross-file cycle detection.
python3 - "$format" "$quiet" "$contract" "${files[@]}" <<'PY'
import json, os, re, sys

fmt = sys.argv[1]
quiet = sys.argv[2] == "1"
contract_path = sys.argv[3]
targets = sys.argv[4:]

# Contract's build_target set (build-contract.md). "product" is valid but
# skipped, not built -- still a legal value here.
VALID_TARGETS = {
    "rust-cli", "rust-lib", "rust-extend", "kernel-extend", "shell",
    "hooks", "config", "notebook", "mixed",
    "python-cli", "python-lib", "python-agent", "product",
}
# PRD-prd-contract-lint, `--contract <path>`: re-derive VALID_TARGETS from a
# build-contract.md-shaped file's `| \`build_target\` | ... |` row instead of
# the hardcoded set above, for testing against a modified contract. Only the
# cell up to the first `(` (the row's own parenthetical commentary, e.g.
# "routes to /pybuild") is scanned, so annotation text never contributes a
# bogus token. Falls back to the hardcoded set (already warned about on
# stderr by the bash layer) on any parse failure or empty result.
if contract_path:
    try:
        with open(contract_path, encoding="utf-8", errors="replace") as fh:
            ctext = fh.read()
        row = next(
            (l for l in ctext.splitlines() if re.match(r"^\s*\|\s*`build_target`\s*\|", l)),
            None,
        )
        if row:
            cell = row.split("|")[2]
            cell = cell.split("(", 1)[0]
            found = re.findall(r"`([a-z][a-z0-9-]*)`", cell)
            if found:
                VALID_TARGETS = set(found)
    except OSError:
        pass
EXTEND_TARGETS = {"rust-extend", "kernel-extend"}
# PRD-build-classification-self-heal: the build_target families a substrate
# check applies to. Deliberately mirrors substrate-probe.sh's depth<=1
# algorithm rather than shelling out to it -- this script stays a single
# self-contained python process for its <200ms/PRD budget; keep the two in
# step by hand (see that script's own header for why it's duplicated here).
RUST_SUBSTRATE_TARGETS = {"rust-cli", "rust-lib", "rust-extend", "kernel-extend"}
PYTHON_SUBSTRATE_TARGETS = {"python-cli", "python-lib", "python-agent"}
SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
FILENAME_RE = re.compile(r"^PRD-([a-z0-9]+(?:-[a-z0-9]+)*)\.md$")
AC_HEADING_RE = re.compile(r"^##\s+Acceptance(?:\s+(criteria|tests))?\s*$", re.I)
AC_NUM_RE = re.compile(r"^(\d+)\.\s+(.*)$")
AC_LEVELED_RE = re.compile(r"^\d+\.\s+P[0-2]\s*[—–-]\s*")
AC_LEGACY_RE = re.compile(r"^AC-\d+\s*:")
# PRD-prd-contract-lint AC8 / verified-completed-ac-count-h3-inflation: an
# h3+ or bold-only pseudo-heading inside the Acceptance-criteria section
# doesn't close verified-completed.sh's own AC-counting block (its awk only
# closes `in_block` on a genuine `^##[[:space:]]`), so any numbered list
# after it -- e.g. a trailing "### Anti-pattern audit" section reusing
# `1.`/`2.` -- gets swept in as phantom ACs. Two real incidents, 2026-07-02
# (aistack-query-complexity-governor, aistack-metric-fingerprint-block-on-
# drift). Catch the trap here, at draft time, before it can false-refuse an
# otherwise-ready archive.
AC_H3_RE = re.compile(r"^#{3,6}\s+\S")
AC_BOLD_HEADING_RE = re.compile(r"^\*\*[^*\n]+\*\*\.?$")
SHA40_RE = re.compile(r"\b[0-9a-f]{40}\b")
BASE_SHA_RE = re.compile(r"--base\s+([0-9a-f]{7,40})\b")
HOME_PATH_RE = re.compile(r"/home/[A-Za-z0-9_.-]+/")
# PRD-build-tenant-secret-continuity, AC3: "key/token/credential already
# held" (or have/got/captured) in either word order, loosely anchored so it
# catches the real 2026-09-13 phrasing ("key already held") without
# requiring an exact string.
CRED_WORD = r"(?:key|token|credential|credentials|secret|api[ _-]?key)"
ALREADY_HELD = r"already\s+(?:held|have|has|got|possess(?:es)?|exists?|captured)"
CRED_CLAIM_RE = re.compile(
    rf"\b{CRED_WORD}\b[^.\n]{{0,60}}\b{ALREADY_HELD}\b"
    rf"|\b{ALREADY_HELD}\b[^.\n]{{0,60}}\b{CRED_WORD}\b",
    re.I,
)
# PRD-build-operator-authorization-contract requirement 8: an AC that names a
# real Hetzner box, real money, or hcloud itself is a spend the loop cannot
# make on its own risk judgment (see build-contract.md's Operator-
# authorization row) -- a PRD describing one with no authorization key is not
# wrong (it may legitimately defer that AC pending a future authorization),
# just worth flagging before dispatch rather than discovering the gap mid-
# tick. `ccx` deliberately has no trailing \b -- it needs to match the
# Hetzner instance-type tokens themselves (ccx43, ccx53), not just a bare
# "ccx" word.
REAL_BOX_RE = re.compile(
    r"\bhcloud\b|\bccx\w*|\breal box\b|\breal money\b|\bbilled\b|\bHetzner server\b",
    re.I,
)
LINT_STATE_DIR = os.environ.get("LINT_STATE_DIR", "")


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


def substrate_marker(base, filename):
    """True + the subdir name (or '' for the root itself) if `filename`
    lives directly at `base` or in any immediate subdirectory of it.
    Mirrors substrate-probe.sh's depth<=1 algorithm -- see that script's
    header for why this is duplicated rather than shelled out to."""
    top = os.path.join(base, filename)
    if os.path.isfile(top):
        return True, []
    members = []
    try:
        for name in sorted(os.listdir(base)):
            sub = os.path.join(base, name)
            if os.path.isdir(sub) and os.path.isfile(os.path.join(sub, filename)):
                members.append(name)
    except OSError:
        pass
    return bool(members), members


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


def ac_inflation_trap(all_lines):
    """Line numbers (1-indexed) + text of any h3+/bold pseudo-heading between
    the Acceptance-criteria heading and the next REAL `## ` heading (or EOF).
    Uses the SAME stop rule as verified-completed.sh's own awk (only a true
    h2 closes the block), so a hit here is a hit there too -- see AC_H3_RE's
    comment for the incident this closes."""
    start = None
    for i, line in enumerate(all_lines):
        if AC_HEADING_RE.match(line.strip()):
            start = i + 1
            break
    if start is None:
        return []
    hits = []
    for i in range(start, len(all_lines)):
        line = all_lines[i]
        if line.startswith("## "):
            break
        stripped = line.strip()
        if AC_H3_RE.match(stripped) or AC_BOLD_HEADING_RE.match(stripped):
            hits.append((i + 1, stripped))
    return hits


def slug_corpus_dirs_for(path):
    """Same as queue_dirs_for but also includes parked/ -- the corpus scope
    for slug uniqueness (PRD-build-prd-slug-uniqueness: 'for every slug,
    exactly one file across build-queue/, built-prds/, and parked/')."""
    d = os.path.dirname(os.path.abspath(path)) or "."
    base = os.path.basename(d)
    if base in ("build-queue", "built-prds", "parked"):
        root = os.path.dirname(d)
        dirs = [os.path.join(root, x) for x in ("build-queue", "built-prds", "parked")]
        return [x for x in dirs if os.path.isdir(x)]
    return [d]


def extract_title(path):
    for line in read_lines(path):
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip()
    return ""


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
    # `Depends-on: none` (also `-`, `n/a`) is the documented way to state an
    # empty dependency list; 2026-09-14 the bare word was read as a filename
    # and parked prd-contract-lint + prd-seed-inbox every tick.
    if raw.strip().lower() in ("none", "-", "n/a", "na", "[]"):
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

    # -- slug uniqueness across the corpus (PRD-build-prd-slug-uniqueness) --
    # A slug is a primary key -- the manifest, claims, receipts, and
    # test_prefix pairing all key on it -- so exactly one PRD-<slug>.md may
    # exist across build-queue/, built-prds/, and parked/ at a time.
    # archive-commit.sh's own in-flight move (queue copy about to be
    # removed, built-prds copy just landed, same commit) is tolerated: two
    # copies with an identical title and an identical `Drafted:` value are
    # "the same PRD in transit", not a collision. Anything else -- three or
    # more copies, or two that disagree on title or Drafted -- fails.
    corpus_dirs = slug_corpus_dirs_for(path)
    this_abs = os.path.abspath(path)
    seen_abs = {this_abs}
    matches = [this_abs]
    for d in corpus_dirs:
        cand = os.path.join(d, name)
        cand_abs = os.path.abspath(cand)
        if cand_abs not in seen_abs and os.path.isfile(cand):
            seen_abs.add(cand_abs)
            matches.append(cand_abs)
    if len(matches) > 1:
        titles = [extract_title(p) for p in matches]
        drafted = [parse_frontmatter(p).get("drafted", "") for p in matches]
        tolerated = (
            len(matches) == 2
            and titles[0] == titles[1]
            and drafted[0] == drafted[1]
        )
        if not tolerated:
            detail = "; ".join(
                f"{p} (title={t!r}, Drafted={dr!r})"
                for p, t, dr in zip(matches, titles, drafted)
            )
            fail(
                "slug-not-unique",
                f"slug {slug!r} resolves to {len(matches)} files, not one: "
                f"{detail} -- test_prefix pairing and receipts also key on "
                f"this slug, so every layer downstream degrades silently "
                f"until the corpus is deduplicated",
            )

    # -- frontmatter presence -------------------------------------------------
    if "status" not in fm:
        fail("status-missing", "no `Status:` line found in the first 80 lines")

    # PRD-prd-contract-lint AC5: presence-only, and a WARN not a FAIL. A
    # measured run against the live build-queue/ corpus at ship time (2026-
    # 09-15) found ~45% of currently-queued PRDs (predating the `Grounding:`
    # convention) have no such line; scan-prds.sh's Phase-1 gate treats the
    # first FAIL as a hard park to needs_classification, so a FAIL here would
    # have stranded roughly half the live queue the instant this shipped --
    # a much bigger regression than the gap this closes (same reasoning as
    # `build-into-not-found` above: promoting a real but non-catastrophic gap
    # to FAIL can jam the whole queue rather than one PRD). WARN still
    # surfaces the gap to a human/drafter without blocking dispatch.
    if "grounding" not in fm:
        warn("grounding-missing", "no `- Grounding:` line found in the first 80 lines — every drafted PRD names its grounding chain (wwhtbt / five-whys / failure-derived / opportunity / ...)")

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
        # lint happens to run. Left unchanged by PRD-build-classification-
        # self-heal (requirement 1: "missing path stays the existing
        # failure") -- promoting this to a FAIL would hard-block every
        # extend PRD linted from a lane that isn't RedBaron, which is a much
        # bigger regression than the substrate-mismatch bug this PRD fixes.
        # The substrate-mismatch check below only ever runs when the path
        # DOES exist locally, so the two checks never compound on this case.
        warn("build-into-not-found", f"build_into {build_into!r} does not exist on this host (may be a different build host)")
    elif build_into and os.path.isdir(build_into):
        # PRD-build-classification-self-heal, requirement 1: cross-check
        # build_target against the actual substrate at build_into so a
        # mismatched pair (e.g. build_target: python-cli against a Cargo
        # workspace -- the real 2026-09-12 defect) fails lint instead of
        # silently passing and bouncing at dispatch three times before a
        # human fixes it by hand. Only the two language families that
        # declare a `build_into` at all (rust-*/kernel-extend, python-*)
        # are in scope, per the requirement text; shell/hooks/config/
        # notebook/mixed/product carry no substrate expectation.
        cargo_found, cargo_members = substrate_marker(build_into, "Cargo.toml")
        pyproject_found, pyproject_dirs = substrate_marker(build_into, "pyproject.toml")
        if build_target in RUST_SUBSTRATE_TARGETS and not cargo_found:
            fail(
                "build-into-substrate-mismatch",
                f"build_target {build_target!r} requires a Cargo.toml at or under "
                f"build_into {build_into!r}; none found "
                f"(pyproject.toml present: {pyproject_found})",
            )
        elif build_target in PYTHON_SUBSTRATE_TARGETS and not pyproject_found:
            fail(
                "build-into-substrate-mismatch",
                f"build_target {build_target!r} requires a pyproject.toml at or under "
                f"build_into {build_into!r}; none found "
                f"(Cargo.toml present: {cargo_found}, members: {cargo_members})",
            )

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
        trap_hits = ac_inflation_trap(all_lines)
        if trap_hits:
            named = ", ".join(f"line {ln}: {txt!r}" for ln, txt in trap_hits)
            fail(
                "ac-heading-inflation",
                f"h3/bold heading(s) inside the Acceptance-criteria section "
                f"will not close verified-completed.sh's AC-counting block "
                f"(it only closes on a real `## ` heading) — any numbered "
                f"list after it is swept in as phantom ACs: {named}",
            )

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

        # pattern check: an AC naming a real box/real money/hcloud spend with
        # no Operator-authorization key present (PRD-build-operator-
        # authorization-contract requirement 8/AC11-12). Presence-only check
        # -- a malformed/unparsed Operator-authorization line still counts as
        # "present" here; whether it actually covers the AC's scope is a
        # verdict-receipts-time judgment (see that script), not a lint-time one.
        if "operator-authorization" not in fm:
            for it in leveled_items:
                s = " ".join(it)
                m = REAL_BOX_RE.search(s)
                if m:
                    warn(
                        "real-box-ac-no-authorization",
                        f"AC mentions a real-box/real-money spend ({m.group(0)!r}) "
                        f"with no `Operator-authorization:` key in frontmatter: {it[0]!r}",
                    )

    # -- credential-reuse claim with no backing secrets-path file ------------
    # PRD-build-tenant-secret-continuity, AC3: a PRD whose own text (frontmatter,
    # iter_log, Next:/Blocked: lines -- this checks the whole file, since those
    # sections aren't structurally distinguished from prose here) claims a
    # credential is "already held" is making a promise the NEXT dispatch (a
    # fresh process) cannot keep unless that credential actually landed under
    # state/secrets/<slug>/. Warning, not a fail -- a doc-only false positive
    # (e.g. a PRD *discussing* this convention) shouldn't block selection.
    body_text = "\n".join(all_lines)
    if CRED_CLAIM_RE.search(body_text):
        secrets_dir = os.path.join(LINT_STATE_DIR, "secrets", slug) if LINT_STATE_DIR else ""
        has_secret_file = False
        if secrets_dir:
            try:
                has_secret_file = any(n.endswith(".json") for n in os.listdir(secrets_dir))
            except OSError:
                has_secret_file = False
        if not has_secret_file:
            warn(
                "credential-reuse-unbacked",
                f"PRD text claims a credential/key/token is 'already held' (or "
                f"similar) with no *.json file under state/secrets/{slug}/ "
                f"backing that claim -- the next dispatch (a fresh process) "
                f"cannot verify or reuse it (see SKILL.md 'Runtime secrets')",
            )

    # -- fixture negative-case rule (PRD-build-post-ship-reality-check req 6) --
    # A PRD that requires a selftest but only ever describes it in positive
    # terms (ok/pass/reachable/match/...) with no failure-mode language
    # (fail/reject/block/mismatch/unreachable/...) anywhere near the
    # mention is a PRD whose fixture is likely to gain a new
    # subcommand/state with only a success case — exactly the class this
    # PRD's own TL;DR names (a receipt claiming 251/251 when the tree had
    # 245). Heuristic, warning-only: it reads the PRD's own words, not the
    # shipped fixture (verified-completed.sh's --check-fixture-negative-
    # case does the shipped-fixture-diff half of this requirement, at
    # archive time, on the real repo).
    selftest_lines = [l for l in all_lines if re.search(r"selftest", l, re.I)]
    if selftest_lines:
        blob = "\n".join(selftest_lines)
        pos_kw = re.compile(r"\b(ok|pass|passing|true|success|reachable|match)\b", re.I)
        neg_kw = re.compile(
            r"\b(fail|failing|reject|block|mismatch|missing|unreachable|false|"
            r"negative|deny|refuse|error|invalid|bad|corrupt)\b", re.I)
        if pos_kw.search(blob) and not neg_kw.search(blob):
            warn("selftest-no-negative-case",
                 "PRD mentions a selftest requirement with no apparent "
                 "failure-mode/negative case (fail/reject/mismatch/"
                 "unreachable/...) — a new subcommand or state risks "
                 "shipping with only a success-path fixture")

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
elif fmt == "pass-fail":
    # PRD-prd-contract-lint AC1/AC7: one line per file. FAIL folds every
    # failure (and, since this mode has no separate WARN slot, every
    # warning too -- warnings never affect the PASS/FAIL verdict itself,
    # only what's named on the line) into one comma-joined line; --quiet
    # drops the PASS lines entirely so a big directory scan shows only its
    # defects, with exit still reflecting the worst result across the batch.
    for r in results:
        findings = r["failures"] + r["warnings"]
        if not findings:
            if not quiet:
                print(f"PASS {r['file']}")
            continue
        if r["failures"]:
            named = ", ".join(f"{x['id']}: {x['message']}" for x in findings)
            print(f"FAIL {r['file']}: {named}")
        elif not quiet:
            named = ", ".join(f"{x['id']}: {x['message']}" for x in findings)
            print(f"PASS {r['file']}: {named}")
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
