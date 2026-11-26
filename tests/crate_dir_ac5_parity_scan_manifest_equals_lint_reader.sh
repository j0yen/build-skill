#!/usr/bin/env bash
# crate_dir_ac5_parity_scan_manifest_equals_lint_reader.sh —
# PRD-build-contract-declared-crate-dir AC5 / R3 across header forms.
#
# For every header form in tests/fixtures/crate-dir-forms.sh, the crate_dir
# that scripts/scan-prds.sh puts in a manifest entry equals the value
# scripts/prd-lint.sh parses from that file, and is "" exactly when the lint
# finds no crate_dir key. Checked on both emission paths: the bash loop, and
# the vellum fast path through a stand-in `vellum` whose rows carry no
# crate_dir (with and without ARCHIVE/). So every non-empty manifest crate_dir
# is a value R2 validates: on the queue the same scan's lint pass parks an
# invalid one with crate-dir-invalid, and a crate_dir line the lint does not
# read never reaches the manifest. A crate_dir reader that fails leaves no
# manifest at all rather than one with crate_dir silently "".
#
# The lint's value is read from its public findings (cdf_lint_value), not
# from any reader under test. Fixtures only: one mktemp root, scratch
# state/manifest/journal per scan, a refusing `docket` first on PATH; the
# corpus is not a git repo, so the lint pass's self-heal call commits nothing.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixtures/crate-dir-common.sh"
. "$HERE/fixtures/crate-dir-forms.sh"
SCAN="$CD_REPO/scripts/scan-prds.sh"
JQ="${JQ:-$(command -v jq)}"
PY3="$(command -v python3)"

mkdir -p "$CD_ROOT/bin" "$CD_PY/ledger-read"
printf '#!/bin/sh\necho "test stub: docket refused" >&2\nexit 97\n' > "$CD_ROOT/bin/docket"
chmod +x "$CD_ROOT/bin/docket"
export PATH="$CD_ROOT/bin:$PATH"

T="$CD_ROOT/forms.tsv"; : > "$T"
cdf_write "$CD_ROOT/corpus/built-prds" "$CD_PY" f "$T"
cdf_write "$CD_Q" "$CD_PY" q "$T" bold-title-invalid,indented-bullet

# prd-lint.sh's own reading of every fixture, from its findings
while IFS=$'\t' read -r f form exp; do
  printf '%s\t%s\t%s\t%s\n' "$f" "$form" "$exp" "$(cdf_lint_value "$f")"
done < "$T" > "$T.lint"

# scan <label> [env...]: one scan-prds.sh run with its own scratch state
scan() {
  local label="$1"; shift
  mkdir -p "$CD_ROOT/state-$label"
  printf '{"prds":{},"built_at":"2020-01-01T00:00:00Z"}\n' > "$CD_ROOT/state-$label/manifest.json"
  env "$@" PRD_DIR="$CD_ROOT/corpus" JQ="$JQ" BUILD_STATE_DIR="$CD_ROOT/state-$label" \
    BUILD_MANIFEST="$CD_ROOT/state-$label/manifest.json" JOURNAL="$CD_ROOT/journal-$label.md" \
    bash "$SCAN" > "$CD_ROOT/scan-$label.json" 2> "$CD_ROOT/scan-$label.err"
  local rc=$?
  [ "$rc" -eq 0 ] || { echo "  scan $label rc=$rc, stderr tail:" >&2; tail -n 5 "$CD_ROOT/scan-$label.err" | sed 's/^/    /' >&2; }
  return "$rc"
}

scan bash; rc_bash=$?
cd_expect "scan (bash path) exits 0" "[ $rc_bash -eq 0 ]"

# A stand-in vellum: rows in scan-prds.sh's shape (slug, path, ...) without crate_dir.
mkdir -p "$CD_ROOT/vbin"
cat > "$CD_ROOT/vbin/vellum" <<EOF
#!$PY3
import glob, json, os, sys
d = sys.argv[2]
if os.path.basename(d.rstrip("/")) == "ARCHIVE":
    files = glob.glob(os.path.join(d, "PRD-*.md"))
else:
    files = glob.glob(os.path.join(d, "build-queue", "PRD-*.md")) + glob.glob(os.path.join(d, "built-prds", "PRD-*.md"))
print(json.dumps([{"slug": os.path.basename(f)[4:-3], "path": f, "build_target": None} for f in sorted(files)], indent=2))
EOF
chmod +x "$CD_ROOT/vbin/vellum"
scan vellum PATH="$CD_ROOT/vbin:$PATH"; rc_v=$?
cd_expect "scan (vellum path, no ARCHIVE/) exits 0" "[ $rc_v -eq 0 ]"
mkdir -p "$CD_ROOT/corpus/ARCHIVE"
cdf_write "$CD_ROOT/corpus/ARCHIVE" "$CD_PY" a "$T.archive" bold-title-key,indented-fence,cr-file
while IFS=$'\t' read -r f form exp; do
  printf '%s\t%s\t%s\t%s\n' "$f" "$form" "$exp" "$(cdf_lint_value "$f")"
done < "$T.archive" >> "$T.lint"
scan vellum-archive PATH="$CD_ROOT/vbin:$PATH"; rc_va=$?
cd_expect "scan (vellum path with ARCHIVE/) exits 0" "[ $rc_va -eq 0 ]"

# prd-lint.sh's reader mode, the one the scan and the self-heal consume
cut -f1 "$T.lint" | tr '\n' '\0' | xargs -0 "$CD_LINT" --print-crate-dir -- > "$CD_ROOT/reader.json" 2> "$CD_ROOT/reader.err"
rc_reader=$?
cd_expect "prd-lint.sh --print-crate-dir exits 0" "[ $rc_reader -eq 0 ]"
# A path gone by the time the reader runs (a pull racing a scan) reads as no
# crate_dir, the way parse_frontmatter reads a file it cannot open, and the
# reader still answers for every other path.
canon="$CD_ROOT/corpus/built-prds/PRD-f-canon-bullet.md" gone="$CD_ROOT/gone/PRD-gone.md"
gone_out="$("$CD_LINT" --print-crate-dir -- "$canon" "$gone" 2>/dev/null)"; rc_gone=$?
cd_expect "reader: a vanished path reads null and the others still answer (exit 0)" \
  "[ $rc_gone -eq 0 ] && python3 -c 'import json,sys; m=json.loads(sys.argv[1]); sys.exit(0 if m[sys.argv[2]] == \"ledger-read\" and m[sys.argv[3]] is None else 1)' \"\$gone_out\" \"\$canon\" \"\$gone\" 2>/dev/null"

out="$(python3 - "$T.lint" "$CD_ROOT" <<'PY'
import json, sys
table, root = sys.argv[1], sys.argv[2]
def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return None
scans = {k: load(f"{root}/scan-{k}.json") for k in ("bash", "vellum", "vellum-archive")}
reader = load(f"{root}/reader.json")
fails = 0
def check(ok, label):
    global fails
    print(("ok  " if ok else "FAIL ") + label)
    fails += 0 if ok else 1
unvalidated = []
for row in open(table, encoding="utf-8"):
    path, form, exp, lint = row.rstrip("\n").split("\t")
    where = path.split("/corpus/")[1].split("/")[0]
    tag = f"{where}/{form}"
    check(lint == exp, f"lint reads {tag} as {exp} (findings say {lint})")
    if lint == "UNDETERMINED":
        continue
    want = json.loads(lint) or ""
    for k, entries in scans.items():
        if where == "ARCHIVE" and k != "vellum-archive":
            continue
        got = None
        if isinstance(entries, list):
            got = next((e.get("crate_dir", "<missing>") for e in entries if e.get("path") == path), "<no entry>")
        check(got == want, f"RQ1 {k} {tag}: manifest crate_dir {json.dumps(got)} == lint {json.dumps(want)}")
        if isinstance(got, str) and got not in ("", "<missing>", "<no entry>") and json.loads(lint) is None:
            unvalidated.append(f"{k} {tag}={got}")
    got_r = reader.get(path, "<missing>") if isinstance(reader, dict) else "<no reader output>"
    check(got_r == json.loads(lint), f"reader {tag}: --print-crate-dir {json.dumps(got_r)} == lint {lint}")
check(not unvalidated, "RQ1: no non-empty manifest crate_dir the lint never read"
      + (f" (found: {'; '.join(unvalidated)})" if unvalidated else ""))
for k, entries in scans.items():
    check(isinstance(entries, list) and len(entries) > 0
          and all(isinstance(e.get("crate_dir"), str) for e in entries),
          f"R3 {k}: every entry carries crate_dir as a string")
sys.exit(1 if fails else 0)
PY
)"; rc_py=$?
printf '%s\n' "$out" | grep '^ok  '
printf '%s\n' "$out" | grep '^FAIL ' >&2
cd_expect "every form: manifest crate_dir == prd-lint.sh's value on all emission paths" "[ $rc_py -eq 0 ]"

# The queue fixtures through the same scan's lint pass (R2 validates what the
# manifest carries): the lint-visible invalid value is parked crate-dir-invalid;
# the indented line the lint does not read parks as a plain substrate mismatch.
reason() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prds"].get(sys.argv[2],{}).get("needs_classification_reason",""))' "$CD_ROOT/state-bash/manifest.json" "$1"; }
cd_expect "lint pass: q-bold-title-invalid parked with crate-dir-invalid" \
  "[[ \"\$(reason q-bold-title-invalid)\" == crate-dir-invalid:* ]]"
cd_expect "lint pass: q-indented-bullet parked with build-into-substrate-mismatch (no crate_dir read)" \
  "[[ \"\$(reason q-indented-bullet)\" == build-into-substrate-mismatch:* ]]"

# A failing crate_dir reader: python3 refuses only inside prd-lint.sh's reader
# mode; scan-prds.sh must exit non-zero and print no manifest.
mkdir -p "$CD_ROOT/failbin"
printf '#!/bin/sh\n[ "${LINT_PRINT_CRATE_DIR:-}" = 1 ] && { echo "test: reader refused" >&2; exit 1; }\nexec %s "$@"\n' "$PY3" > "$CD_ROOT/failbin/python3"
chmod +x "$CD_ROOT/failbin/python3"
scan readerfail PATH="$CD_ROOT/failbin:$PATH"; rc_f=$?
cd_expect "reader failure: scan exits non-zero" "[ $rc_f -ne 0 ]"
cd_expect "reader failure: scan prints no manifest" "[ ! -s \"\$CD_ROOT/scan-readerfail.json\" ]"
scan readerfail-vellum PATH="$CD_ROOT/failbin:$CD_ROOT/vbin:$PATH"; rc_fv=$?
cd_expect "reader failure (vellum path): scan exits non-zero" "[ $rc_fv -ne 0 ]"
cd_expect "reader failure (vellum path): scan prints no manifest" "[ ! -s \"\$CD_ROOT/scan-readerfail-vellum.json\" ]"

exit $cd_fail
