#!/usr/bin/env bash
# crate-dir-forms.sh — header-form table for the crate_dir reader parity tests
# (PRD-build-contract-declared-crate-dir R3/R4; tests/crate_dir_ac4_parity_*,
# tests/crate_dir_ac5_parity_*). Source it after crate-dir-common.sh.
#
# Three readers see a PRD's crate_dir: prd-lint.sh (parse_frontmatter, which
# R2 validates), scan-prds.sh (the manifest field) and
# classification-self-heal.sh (the resolve guard). Each form below is one way
# a header line can be written: bullet/bold/bare, indentation, fences (also
# indented), key case and spacing, \n / \r\n / \r line endings, the 80-line
# window, and Unicode whitespace that Python's str methods fold and the shell
# tools do not.
#
# cdf_write <dir> <build_into> <prefix> <table-out> [form,form,...]
#   Writes one rust-extend PRD per form (or per named form),
#   PRD-<prefix>-<form>.md, into <dir>,
#   and appends "<file>\t<form>\t<expected>" rows to <table-out>; <expected>
#   is JSON: the value the author reads prd-lint.sh's parse_frontmatter as
#   taking from that file, null when it finds no crate_dir key.
# cdf_lint_value <file>
#   prd-lint.sh's own answer, read from its public findings alone (so it
#   works on any revision of the lint): <build_into> must be a Python repo
#   (root pyproject.toml) holding ledger-read/ without a Cargo.toml, so a
#   crate_dir key always yields a crate-dir-invalid message naming the value
#   (every valid value in the table is ledger-read) and no key yields
#   build-into-substrate-mismatch. Prints JSON (null or the string), or
#   UNDETERMINED when the findings show neither.

cdf_write() {
  python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import json, os, sys
d, into, prefix, table, only = sys.argv[1:6]
only = set(only.split(",")) if only else None
NB = " "   # NO-BREAK SPACE: str.isspace() and re's \s match it; mawk/sed/bash do not
top = ["# PRD: crate dir form fixture", "", "- Status: queued",
       "- build_target: rust-extend", f"- build_into: {into}"]
bottom = ["- build_priority: high", "- Drafted: 2026-11-18", "- Seed: joe:2026-11-18",
          "- Vision: visions/plain.md", "- Grounding: grounded", "",
          "## Acceptance criteria", "",
          "1. P0 — Given a fixture, When the crate builds, Then it exits 0."]
def filler(n):
    return [f"Note line {i}." for i in range(n)]
# crate line at 1-based line N (\n count) after the 5 top lines: N - 6 fillers
def at_line(n, line, cr_filler=False):
    f = filler(n - 6)
    if cr_filler:
        f[3] = "Note a\rNote b."   # one lone CR: prd-lint's universal newlines count one line more
    return f + [line]
LR = "ledger-read"
forms = [
    # name, middle lines, expected lint value, line ending
    ("canon-bullet",        ["- crate_dir: ledger-read"], LR, "\n"),
    ("bare",                ["crate_dir: ledger-read"], LR, "\n"),
    ("bold",                ["**crate_dir:** ledger-read"], LR, "\n"),
    ("bullet-bold",         ["- **crate_dir:** ledger-read"], LR, "\n"),
    ("plus-bullet",         ["+ crate_dir: ledger-read"], LR, "\n"),
    ("bold-title-key",      ["**Crate Dir:** ledger-read"], LR, "\n"),
    ("bold-space-colon",    ["**crate_dir :** ledger-read"], LR, "\n"),
    ("upper-key",           ["- CRATE_DIR: ledger-read"], LR, "\n"),
    ("title-space-key",     ["- Crate Dir: ledger-read"], LR, "\n"),
    ("space-before-colon",  ["- crate_dir : ledger-read"], LR, "\n"),
    ("tab-indented-bare",   ["\tcrate_dir: ledger-read"], LR, "\n"),
    ("space-indented-bare", ["   crate_dir: ledger-read"], LR, "\n"),
    ("indented-bullet",     ["  - crate_dir: ../evil"], None, "\n"),
    ("indented-fence",      ["   ```", "crate_dir: ../evil", "   ```"], None, "\n"),
    ("nbsp-fence",          [NB + "```", "- crate_dir: ../evil", NB + "```"], None, "\n"),
    ("fence-then-real",     ["```", "crate_dir: in-fence", "```", "- crate_dir: ledger-read"], LR, "\n"),
    ("indented-fence-close", ["```", "x", "   ```", "- crate_dir: ledger-read"], LR, "\n"),
    ("nbsp-fence-close",    ["```", "x", NB + "```", "- crate_dir: ledger-read"], LR, "\n"),
    ("dup-case-first-wins", ["- Crate_Dir: ledger-read", "- crate_dir: other-crate"], LR, "\n"),
    ("quoted-comment",      ['- crate_dir: "ledger-read"  # the crate'], LR, "\n"),
    ("empty-value",         ["- crate_dir:"], "", "\n"),
    ("invalid-visible",     ["- crate_dir: ../evil"], "../evil", "\n"),
    ("bold-title-invalid",  ["**Crate Dir:** ../evil"], "../evil", "\n"),
    ("absent",              [], None, "\n"),
    ("hyphen-key",          ["- crate-dir: ledger-read"], None, "\n"),
    ("double-space-key",    ["- crate  dir: ledger-read"], None, "\n"),
    ("nbsp-before-colon",   ["- crate_dir" + NB + ": ledger-read"], LR, "\n"),
    ("nbsp-leading",        [NB + "crate_dir: ledger-read"], LR, "\n"),
    ("nbsp-after-value",    ["- crate_dir: ledger-read" + NB], LR, "\n"),
    ("crlf-file",           ["- crate_dir: ledger-read"], LR, "\r\n"),
    ("cr-file",             ["- crate_dir: ledger-read"], LR, "\r"),
    # a lone CR inside a prose line: scan-prds.sh JSON-encodes no key value here
    # (a CR inside a build_* value breaks its whole scan, a defect older than
    # crate_dir and outside this PRD)
    ("embedded-cr",         ["Note a\r- crate_dir: ledger-read"], LR, "\n"),
    ("window-line-80",      at_line(80, "- crate_dir: ledger-read"), LR, "\n"),
    ("window-line-81",      at_line(81, "- crate_dir: ledger-read"), None, "\n"),
    ("window-80-after-cr",  at_line(80, "- crate_dir: ../evil", cr_filler=True), None, "\n"),
]
with open(table, "a", encoding="utf-8") as tb:
    for name, middle, expected, nl in forms:
        if only is not None and name not in only:
            continue
        path = os.path.join(d, f"PRD-{prefix}-{name}.md")
        text = nl.join(top + middle + bottom) + nl
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        tb.write(f"{path}\t{name}\t{json.dumps(expected)}\n")
PY
}

cdf_lint_value() {
  "$CD_LINT" --format json "$1" 2>/dev/null | python3 -c '
import ast, json, re, sys
try:
    r = json.load(sys.stdin)[0]
except Exception:
    print("UNDETERMINED"); sys.exit()
fails = r.get("failures") or []
vals = []
for f in fails:
    if f["id"] != "crate-dir-invalid":
        continue
    m = re.match(r"crate_dir (\x27(?:[^\x27\\]|\\.)*\x27|\"(?:[^\"\\]|\\.)*\")", f["message"])
    if m:
        vals.append(ast.literal_eval(m.group(1)))
mismatch = any(f["id"] == "build-into-substrate-mismatch" for f in fails)
if vals and not mismatch and len(set(vals)) == 1:
    print(json.dumps(vals[0]))
elif mismatch and not vals:
    print("null")
else:
    print("UNDETERMINED")
'
}
