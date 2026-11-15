#!/usr/bin/env bash
# dream-scorecard.sh — /dream hook `dream.scorecard` (Phase 0): one read-only command that
# prints the numbers that say whether Dream got better (PRD-dream-scorecard-hook).
#
# Read-only: it opens every source for reading only and writes no file (the reused
# prd-lint.sh's repo-surface cache is pointed at an uncreatable path for that call).
# Every metric is {value, source, note?}; value is a number, an object of numbers, or an
# `na:<reason>` string:
#   absent source              na:no-review-log | na:no-decisions-log | na:no-dream-log |
#                              na:no-prd-dir | na:no-build-queue | na:no-visions-dir |
#                              na:no-parked-dir | na:no-run-record-lint | na:no-pipeline-sidecar
#   unreadable / over 50 MB    na:unreadable | na:too-large
#   every candidate row lacks a field the metric needs   na:schema-mismatch:<field>
#   an empty window            0 (never na)
# Rows lacking any named field are counted in <source>.schema_mismatch and excluded; a
# JSONL line that does not parse is counted in <source>.malformed_lines and skipped.
#
# Sources (all overridable; nothing is written to any of them):
#   review log       $DREAM_REVIEW_LOG          (default ~/.local/state/dream/review-log.jsonl)
#   decisions log    $SKILL_ROUTING_DECISIONS   (default ~/.local/state/skill-routing/decisions.jsonl)
#   corpus           --prd-dir, else $DREAM_PRD_DIR, else ~/Documents/PRDs
#                    (build-queue/ by Drafted:, visions/ and parked/ by file mtime,
#                     notes/dream-log.md by entry header timestamp)
#   prd-lint         sibling scripts/prd-lint.sh <prd-dir>/build-queue --format pass-fail
#   run-note lint    seam $DREAM_RUN_NOTE_LINT, else `command -v dream-run-note-lint.sh`, else
#                    ${DREAM_SKILL_DIR:-$(readlink -f ~/.claude/skills/dream)}/scripts/dream-run-note-lint.sh
#                    (contract: sibling PRD dream-run-record R3/R6 — `<log> --entry <ts> --json
#                     --prd-dir <dir>`; exit 0 and 1 print the JSON object, exit 2 prints none)
#   pipeline sidecar seam $DREAM_PIPELINE_SIDECAR_DIR, else
#                    ${BUILD_STATE_DIR:-${BUILD_SKILL_DIR:-<parent of scripts/>}/state}/prd-pipeline
#                    (newest <YYYY-MM-DD>.json written by prd-pipeline.sh --json)
# Windows: review and decisions rows by `ts` date (first 10 chars) >= --since; queued PRDs
# by `Drafted:`; visions and parked files by mtime (local date); dream-log entries by the
# header timestamp. The default window is the last 30 days. malformed_lines and the
# pipeline sidecar fields are not windowed.
#
# Usage:
#   dream-scorecard.sh [--json] [--since <YYYY-MM-DD>] [--prd-dir <dir>]
#   dream-scorecard.sh --check <metric path> [--since ...] [--prd-dir ...]
#       prints `number` or `na`; exit 0 when the metric is a number (or an object of numbers)
#       or an na: string, 1 when the path is missing or names no metric
#   dream-scorecard.sh --selftest      (runs tests/dreamsc_ac0[1-7]_*.sh on fixtures)
#
# Exit: 0 whenever the command ran (na values are output, not errors) | 1 --check path
#       missing/malformed | 2 usage or no python3 on PATH.
set -uo pipefail

# Interpreter check before any other external command, so the message names it.
if ! command -v python3 >/dev/null 2>&1; then
  echo "dream-scorecard: python3 not found on PATH (it parses every JSON source); nothing computed" >&2
  exit 2
fi

SELF="${BASH_SOURCE[0]}"
case "${1:-}" in
  -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; exit 0 ;;
  --selftest)
    here="$(cd "$(dirname "$SELF")" && pwd)"; fails=0; n=0
    for t in "$here"/../tests/dreamsc_ac0[1-7]_*.sh; do
      n=$((n + 1))
      if out="$(bash "$t" 2>&1)"; then echo "ok   $(basename "$t")"; else echo "FAIL $(basename "$t")"; printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/     /'; fails=$((fails + 1)); fi
    done
    [ "$n" -gt 0 ] || { echo "SELFTEST FAILED (no tests/dreamsc_ac0N_*.sh found)"; exit 1; }
    [ "$fails" -eq 0 ] && { echo "SELFTEST PASSED ($n tests)"; exit 0; }
    echo "SELFTEST FAILED ($fails/$n tests)"; exit 1 ;;
esac

exec python3 -I - "$SELF" "$@" <<'PY'
import collections, datetime, json, os, re, shutil, subprocess, sys

SELF = os.path.realpath(sys.argv[1])
REPO = os.path.dirname(os.path.dirname(SELF))
PRD_LINT = os.path.join(REPO, "scripts", "prd-lint.sh")
MAX_BYTES = 50 * 1024 * 1024
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
USAGE = "usage: dream-scorecard.sh [--json] [--since <YYYY-MM-DD>] [--prd-dir <dir>] [--check <metric path>]"


def usage(msg):
    print(f"dream-scorecard: {msg}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)


def valid_day(s):
    if not isinstance(s, str) or not DATE_RE.match(s[:10]):
        return None
    try:
        datetime.date.fromisoformat(s[:10])
    except ValueError:
        return None
    return s[:10]


# ---- arguments -------------------------------------------------------------
as_json, since, prd_dir, check = False, None, None, None
argv = sys.argv[2:]
i = 0
while i < len(argv):
    a = argv[i]
    if a == "--json":
        as_json = True
    elif a in ("--since", "--prd-dir", "--check"):
        if i + 1 >= len(argv) or argv[i + 1] == "":
            usage(f"{a} needs a value")
        v = argv[i + 1]; i += 1
        if a == "--since": since = v
        elif a == "--prd-dir": prd_dir = v
        else: check = v
    elif a.startswith("--since="): since = a.split("=", 1)[1]
    elif a.startswith("--prd-dir="): prd_dir = a.split("=", 1)[1]
    elif a.startswith("--check="): check = a.split("=", 1)[1]
    else:
        usage(f"unknown argument: {a}")
    i += 1
if since is None:
    since = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()
elif not (DATE_RE.match(since) and valid_day(since)):
    usage(f"--since must be YYYY-MM-DD, got {since!r}")

HOME = os.path.expanduser("~")
prd_dir = os.path.abspath(prd_dir or os.environ.get("DREAM_PRD_DIR") or os.path.join(HOME, "Documents", "PRDs"))
review_path = os.environ.get("DREAM_REVIEW_LOG") or os.path.join(HOME, ".local/state/dream/review-log.jsonl")
decisions_path = os.environ.get("SKILL_ROUTING_DECISIONS") or os.path.join(HOME, ".local/state/skill-routing/decisions.jsonl")

metrics = collections.OrderedDict()   # group -> OrderedDict(name -> {value, source, note?})
windows = {}                          # "group.name" -> window label for the text table
sources = collections.OrderedDict()


def put(group, name, value, source, note=None, window=None):
    m = {"value": value, "source": source}
    if note:
        m["note"] = note
    metrics.setdefault(group, collections.OrderedDict())[name] = m
    windows[f"{group}.{name}"] = window or f"since {since}"


def read_source(path, missing):
    """(text, None) or (None, na-reason). Never opens for writing."""
    if not os.path.exists(path):
        return None, missing
    try:
        if os.stat(path).st_size > MAX_BYTES:
            return None, "na:too-large"
        with open(path, "rb") as fh:
            data = fh.read(MAX_BYTES + 1)
    except OSError:
        return None, "na:unreadable"
    if len(data) > MAX_BYTES:
        return None, "na:too-large"
    return data.decode("utf-8", errors="replace"), None


def jsonl(text):
    rows, bad = [], 0
    for ln in text.splitlines():
        if not ln.strip():
            continue
        try:
            obj = json.loads(ln)
        except ValueError:
            bad += 1
            continue
        if not isinstance(obj, dict):
            bad += 1
            continue
        rows.append(obj)
    return rows, bad


def window_rows(rows, required):
    """Split parsed rows into (good rows in window, schema_mismatch count, all_missing set).
    A row with no valid `ts` cannot be windowed: it is a candidate and a mismatch. A field
    is all-missing when every candidate row (in window or ts-less) lacks it; `ts` is
    all-missing when no row in the file carries a valid one."""
    good, mismatch, cand = [], 0, 0
    lacking = collections.Counter()
    any_ts = any(valid_day(r.get("ts")) for r in rows)
    for r in rows:
        d = valid_day(r.get("ts"))
        if d is not None and d < since:
            continue
        cand += 1
        miss = [f for f in required if f not in r or (f == "ts" and d is None)]
        for f in miss:
            lacking[f] += 1
        if miss:
            mismatch += 1
            continue
        good.append(r)
    all_missing = {f for f in required if cand and lacking[f] == cand}
    if not any_ts and rows:
        all_missing.add("ts")
    return good, mismatch, all_missing


def first_mismatch(needs, all_missing):
    for f in needs:
        if f in all_missing:
            return f"na:schema-mismatch:{f}"
    return None


# ---- corpus slugs (the review filter) ---------------------------------------
corpus_ok = os.path.isdir(prd_dir)
sources["prd_dir"] = prd_dir if corpus_ok else "absent"
prd_slugs = set()
if corpus_ok:
    for sub in ("build-queue", "built-prds", "parked"):
        try:
            names = os.listdir(os.path.join(prd_dir, sub))
        except OSError:
            continue
        for n in names:
            if n.startswith("PRD-") and n.endswith(".md"):
                prd_slugs.add(n[4:-3])

# ---- review log -------------------------------------------------------------
R_NEEDS = collections.OrderedDict([
    ("persisted_rows", ("ts", "slug", "outcome")),
    ("with_verdict", ("ts", "slug", "verdict")),
    ("approve_last", ("ts", "slug", "verdict")),
    ("fix_last", ("ts", "slug", "verdict")),
    ("no_verdict_pushed", ("ts", "slug", "outcome", "verdict")),
    ("refused", ("ts", "slug", "outcome")),
    ("failed", ("ts", "slug", "outcome")),
    ("rounds_max_per_slug", ("ts", "slug")),
    ("malformed_lines", ()),
    ("schema_mismatch", ()),
    ("rows_without_prd", ("ts", "slug")),
])
R_NOTES = {
    "persisted_rows": "rows with outcome pushed",
    "with_verdict": "rows carrying a non-null verdict",
    "approve_last": "slugs whose last in-window row carries verdict APPROVE",
    "fix_last": "slugs whose last in-window row carries verdict FIX",
    "no_verdict_pushed": "rows with outcome pushed and no verdict",
    "rounds_max_per_slug": "most rows for one slug",
    "malformed_lines": "lines that do not parse as a JSON object (whole file)",
    "schema_mismatch": "rows lacking ts, slug, outcome or verdict; excluded from every count",
    "rows_without_prd": "rows whose slug has no PRD-<slug>.md in build-queue/, built-prds/ or parked/ "
                        "(mostly persist-selftest fixture slugs); excluded from every other count",
}
text, na = read_source(review_path, "na:no-review-log")
sources["review_log"] = "absent" if na == "na:no-review-log" else review_path
if na:
    for name in R_NEEDS:
        put("review", name, na, review_path)
else:
    rows, bad = jsonl(text)
    good, mismatch, all_missing = window_rows(rows, ("ts", "slug", "outcome", "verdict"))
    counted, without = [], 0
    for r in good:
        if r.get("slug") in prd_slugs:
            counted.append(r)
        else:
            without += 1
    last = {}
    per_slug = collections.Counter()
    for idx, r in sorted(enumerate(counted), key=lambda t: (str(t[1].get("ts")), t[0])):
        last[r["slug"]] = r
        per_slug[r["slug"]] += 1
    verdict = lambda r: str(r.get("verdict") or "").strip().upper()
    vals = {
        "persisted_rows": sum(1 for r in counted if r.get("outcome") == "pushed"),
        "with_verdict": sum(1 for r in counted if r.get("verdict") not in (None, "")),
        "approve_last": sum(1 for r in last.values() if verdict(r) == "APPROVE"),
        "fix_last": sum(1 for r in last.values() if verdict(r) == "FIX"),
        "no_verdict_pushed": sum(1 for r in counted if r.get("outcome") == "pushed" and r.get("verdict") in (None, "")),
        "refused": sum(1 for r in counted if r.get("outcome") == "refused"),
        "failed": sum(1 for r in counted if r.get("outcome") == "failed"),
        "rounds_max_per_slug": max(per_slug.values()) if per_slug else 0,
        "malformed_lines": bad,
        "schema_mismatch": mismatch,
        "rows_without_prd": without,
    }
    for name, needs in R_NEEDS.items():
        v = first_mismatch(needs, all_missing)
        if v is None and needs and not corpus_ok:
            v = "na:no-prd-dir"
        win = "whole file" if name == "malformed_lines" else None
        put("review", name, vals[name] if v is None else v, review_path, R_NOTES.get(name), win)

# ---- decisions log ----------------------------------------------------------
D_NEEDS = collections.OrderedDict([
    ("dream_launches_by_route", ("ts", "decision", "skill", "route")),
    ("dream_denied", ("ts", "decision", "skill")),
    ("analysis_launches_with_dream_task", ("ts", "decision", "skill", "task_id")),
    ("malformed_lines", ()),
    ("schema_mismatch", ()),
])
D_NOTES = {
    "dream_launches_by_route": "decision launch, skill dream, counted by route",
    "dream_denied": "decision denied, skill dream",
    "analysis_launches_with_dream_task": "launch rows of skill wwhtbt or 5whysandrhyme whose task_id has a dream launch row",
    "malformed_lines": "lines that do not parse as a JSON object (whole file)",
    "schema_mismatch": "rows lacking ts, decision, skill, task_id or route; excluded from every count",
}
text, na = read_source(decisions_path, "na:no-decisions-log")
sources["decisions_log"] = "absent" if na == "na:no-decisions-log" else decisions_path
if na:
    for name in D_NEEDS:
        put("routing", name, na, decisions_path)
else:
    rows, bad = jsonl(text)
    good, mismatch, all_missing = window_rows(rows, ("ts", "decision", "skill", "task_id", "route"))
    by_route = collections.Counter()
    dream_tasks = set()
    for r in good:
        if r.get("decision") == "launch" and r.get("skill") == "dream":
            by_route[str(r.get("route"))] += 1
            if r.get("task_id") not in (None, ""):
                dream_tasks.add(r.get("task_id"))
    vals = {
        "dream_launches_by_route": dict(sorted(by_route.items())),
        "dream_denied": sum(1 for r in good if r.get("decision") == "denied" and r.get("skill") == "dream"),
        "analysis_launches_with_dream_task": sum(
            1 for r in good if r.get("decision") == "launch" and r.get("skill") in ("wwhtbt", "5whysandrhyme")
            and r.get("task_id") not in (None, "") and r.get("task_id") in dream_tasks),
        "malformed_lines": bad,
        "schema_mismatch": mismatch,
    }
    for name, needs in D_NEEDS.items():
        v = first_mismatch(needs, all_missing)
        win = "whole file" if name == "malformed_lines" else None
        put("routing", name, vals[name] if v is None else v, decisions_path, D_NOTES.get(name), win)

# ---- corpus -----------------------------------------------------------------
sources["prd_lint"] = PRD_LINT if os.path.isfile(PRD_LINT) else "absent"
bq = os.path.join(prd_dir, "build-queue")
vis = os.path.join(prd_dir, "visions")
parked = os.path.join(prd_dir, "parked")


def local_day(path):
    try:
        return datetime.date.fromtimestamp(os.stat(path).st_mtime).isoformat()
    except OSError:
        return None


def drafted_of(path):
    text, na = read_source(path, None)
    if na or text is None:
        return None
    for ln in text.splitlines()[:80]:
        if ln.startswith("## "):
            break
        k = re.sub(r"^[-*+]\s+", "", ln.strip())
        k = re.sub(r"^\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
        m = re.match(r"^Drafted\s*:\s*(\S+)", k, re.I)
        if m:
            return valid_day(m.group(1))
    return None


def dir_files(d, suffix=".md", prefix=""):
    out = []
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if n.startswith(prefix) and n.endswith(suffix) and os.path.isfile(p):
            out.append(p)
    return out


if not corpus_ok:
    for name in ("queued_lint_fail_by_id", "queued", "visions_in_window", "visions_citing_wwhtbt_page",
                 "visions_citing_fivewhys_page", "parked_prd_defect"):
        put("corpus", name, "na:no-prd-dir", prd_dir)
else:
    if not os.path.isdir(bq):
        put("corpus", "queued_lint_fail_by_id", "na:no-build-queue", bq)
        put("corpus", "queued", "na:no-build-queue", bq)
    else:
        files = dir_files(bq, prefix="PRD-")
        in_win, undated = [], 0
        for p in files:
            d = drafted_of(p)
            if d is None:
                undated += 1
            elif d >= since:
                in_win.append(p)
        note_q = "queued PRDs whose Drafted: is in the window"
        if undated:
            note_q += f"; {undated} file(s) without a Drafted: date not counted"
        lint_note = ("ids named on `prd-lint.sh build-queue --format pass-fail` FAIL lines of in-window "
                     "queued PRDs, one count per file per id (pass-fail folds a FAIL file's warnings onto its line)")
        if not os.path.isfile(PRD_LINT):
            put("corpus", "queued_lint_fail_by_id", "na:no-prd-lint", PRD_LINT)
        elif not in_win:
            put("corpus", "queued_lint_fail_by_id", {}, bq, lint_note)
        else:
            env = dict(os.environ)
            env["PRD_LINT_CACHE"] = "/dev/null/dream-scorecard-writes-nothing"   # uncreatable: the surface cache is never written
            try:
                r = subprocess.run(["bash", PRD_LINT, bq, "--format", "pass-fail"], stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True, timeout=600, env=env)
                rc, lout = r.returncode, r.stdout
            except (OSError, subprocess.SubprocessError) as e:
                rc, lout = -1, ""
            if rc not in (0, 1):
                put("corpus", "queued_lint_fail_by_id", f"na:prd-lint-error:exit-{rc}", bq, lint_note)
            else:
                want = {os.path.basename(p) for p in in_win}
                by_id = collections.Counter()
                for ln in lout.splitlines():
                    m = re.match(r"^FAIL (.*?/(PRD-[^/:]*\.md)): (.*)$", ln)
                    if not m or m.group(2) not in want:
                        continue
                    ids = set(re.findall(r"(?:^|, )([a-z0-9][a-z0-9-]*): ", m.group(3)))
                    for x in ids:
                        by_id[x] += 1
                put("corpus", "queued_lint_fail_by_id", dict(sorted(by_id.items())), bq, lint_note)
        put("corpus", "queued", len(in_win), bq, note_q, f"Drafted: since {since}")

    if not os.path.isdir(vis):
        for name in ("visions_in_window", "visions_citing_wwhtbt_page", "visions_citing_fivewhys_page"):
            put("corpus", name, "na:no-visions-dir", vis)
    else:
        n_in = n_w = n_f = 0
        for p in dir_files(vis):
            d = local_day(p)
            if d is None or d < since:
                continue
            t, na = read_source(p, None)
            if na or t is None:
                continue
            n_in += 1
            n_w += 1 if re.search(r"-wwhtbt\.md", t) else 0
            n_f += 1 if re.search(r"five-whys|5whysandrhyme", t) else 0
        win = f"mtime since {since}"
        put("corpus", "visions_in_window", n_in, vis, "vision files modified in the window", win)
        put("corpus", "visions_citing_wwhtbt_page", n_w, vis, "in-window visions matching -wwhtbt\\.md", win)
        put("corpus", "visions_citing_fivewhys_page", n_f, vis, "in-window visions matching five-whys|5whysandrhyme", win)

    if not os.path.isdir(parked):
        put("corpus", "parked_prd_defect", "na:no-parked-dir", parked)
    else:
        n = 0
        for p in dir_files(parked):
            d = local_day(p)
            if d is None or d < since:
                continue
            t, na = read_source(p, None)
            if not na and t is not None and "prd-defect" in t:
                n += 1
        put("corpus", "parked_prd_defect", n, parked, "parked files naming prd-defect", f"mtime since {since}")

# ---- dream-log + run-note lint ----------------------------------------------
attempted = []
seam = os.environ.get("DREAM_RUN_NOTE_LINT", "")
lint = None
is_exec = lambda p: os.path.isfile(p) and os.access(p, os.X_OK)
if seam:
    attempted.append(seam)
    lint = seam if is_exec(seam) else None
else:
    w = shutil.which("dream-run-note-lint.sh")
    if w:
        attempted.append(w)
        lint = w
    else:
        sd = os.environ.get("DREAM_SKILL_DIR") or os.path.realpath(os.path.join(HOME, ".claude", "skills", "dream"))
        cand = os.path.join(sd, "scripts", "dream-run-note-lint.sh")
        attempted.append(cand)
        lint = cand if is_exec(cand) else None
sources["run_note_lint"] = lint or "absent"
sources["run_note_lint_attempted"] = attempted

log = os.path.join(prd_dir, "notes", "dream-log.md")
RUN_NAMES = ("entries", "with_run_record", "lint_fail", "no_record", "analysis")
text, na = read_source(log, "na:no-dream-log")
sources["dream_log"] = "absent" if na == "na:no-dream-log" else log
if na:
    for name in RUN_NAMES:
        put("runs", name, na, log)
else:
    entries = []
    for ln in text.splitlines():
        m = re.match(r"^## (\d{4}-\d{2}-\d{2}\S*)(.*)$", ln)
        if not m or not re.search(r"(?:^|\s)/dream(?:\s|$)", m.group(2).split("(")[0]):
            continue
        d = valid_day(m.group(1))
        if d and d >= since:
            entries.append(m.group(1))
    win = f"entry header since {since}"
    put("runs", "entries", len(entries), log, "`## <ts> ... /dream ...` entries in the window", win)
    if lint is None:
        for name in RUN_NAMES[1:]:
            put("runs", name, "na:no-run-record-lint", lint or (attempted[-1] if attempted else "absent"),
                "no run-note lint found; tried: " + (", ".join(attempted) or "PATH"), win)
    else:
        rec = fail = norec = errs = unparsed = 0
        kinds = collections.OrderedDict((k, 0) for k in ("ran", "reused", "skipped", "inline"))
        other_kinds = collections.Counter()
        for ts in entries:
            try:
                r = subprocess.run([lint, log, "--entry", ts, "--json", "--prd-dir", prd_dir],
                                   stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
                rc = r.returncode
            except (OSError, subprocess.SubprocessError):
                rc = None
            if rc in (0, 1):
                rec += 1
                fail += 1 if rc == 1 else 0
                try:
                    obj = json.loads(r.stdout)
                    an = obj.get("analysis") if isinstance(obj, dict) else None
                    if not isinstance(an, dict):
                        raise ValueError
                    for v in an.values():
                        k = v.get("kind") if isinstance(v, dict) else None
                        if k in kinds:
                            kinds[k] += 1
                        else:
                            other_kinds[str(k)] += 1
                except (ValueError, AttributeError):
                    unparsed += 1
            elif rc == 2:
                norec += 1
            else:
                errs += 1
        extra = []
        if errs:
            extra.append(f"{errs} entr{'y' if errs == 1 else 'ies'} where the lint exited other than 0/1/2 or timed out (in no bucket)")
        if unparsed:
            extra.append(f"{unparsed} exit-0/1 output(s) without a parsable analysis object")
        if other_kinds:
            extra.append("unbucketed analysis kinds: " + json.dumps(dict(other_kinds)))
        tail = ("; " + "; ".join(extra)) if extra else ""
        put("runs", "with_run_record", rec, lint, "entries where the run-note lint exited 0 or 1" + tail, win)
        put("runs", "lint_fail", fail, lint, "entries where it exited 1", win)
        put("runs", "no_record", norec, lint, "entries where it exited 2", win)
        put("runs", "analysis", dict(kinds), lint, "analysis kinds over the --json of exit-0 and exit-1 entries", win)

# ---- pipeline sidecar -------------------------------------------------------
seam = os.environ.get("DREAM_PIPELINE_SIDECAR_DIR", "")
if seam:
    sdir = seam
else:
    state = os.environ.get("BUILD_STATE_DIR") or os.path.join(os.environ.get("BUILD_SKILL_DIR") or REPO, "state")
    sdir = os.path.join(state, "prd-pipeline")
sources["pipeline_sidecar_attempted"] = [sdir]
newest = None
try:
    names = sorted(n for n in os.listdir(sdir) if re.match(r"^\d{4}-\d{2}-\d{2}\.json$", n))
    newest = os.path.join(sdir, names[-1]) if names else None
except OSError:
    newest = None
sources["pipeline_sidecar"] = newest or "absent"
if newest is None:
    for k in ("drafted", "shipped", "weighted"):
        put("pipeline", k, "na:no-pipeline-sidecar", sdir, f"no <date>.json under {sdir}", "newest sidecar")
else:
    text, na = read_source(newest, "na:no-pipeline-sidecar")
    obj = None
    if not na:
        try:
            obj = json.loads(text)
        except ValueError:
            obj = None
        if not isinstance(obj, dict):
            na = "na:malformed-sidecar"
    for k in ("drafted", "shipped", "weighted"):
        win = f"sidecar {os.path.basename(newest)[:-5]}"
        if na:
            put("pipeline", k, na, newest, None, win)
            continue
        v = obj.get(k)
        if k not in obj:
            v = f"na:schema-mismatch:{k}"
        elif isinstance(v, bool) or not isinstance(v, (int, float, str)):
            v = f"na:schema-mismatch:{k}"
        elif isinstance(v, str):
            v = v if v.startswith("na:") else f"na:sidecar-{v}"
        put("pipeline", k, v, newest, "copied from prd-pipeline.sh --json (not windowed)", win)

result = collections.OrderedDict([
    ("generated_at", datetime.datetime.now().astimezone().isoformat(timespec="seconds")),
    ("window", {"since": since}),
    ("sources", sources),
    ("metrics", metrics),
])


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# ---- output -----------------------------------------------------------------
if check is not None:
    node, parts = result, check.split(".")
    try:
        for p in parts:
            node = node[p]
    except (KeyError, TypeError):
        print(f"dream-scorecard: --check: no such path: {check}", file=sys.stderr)
        sys.exit(1)
    if isinstance(node, dict) and "value" in node and "source" in node:
        node = node["value"]
    elif not (parts[-1] == "value" and parts[0] == "metrics"):
        print(f"dream-scorecard: --check: {check} names no metric", file=sys.stderr)
        sys.exit(1)
    if is_number(node) or (isinstance(node, dict) and all(is_number(x) for x in node.values())):
        print("number")
    elif isinstance(node, str) and node.startswith("na:"):
        print("na")
    else:
        print(f"dream-scorecard: --check: {check} holds a malformed value: {node!r}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

if as_json:
    print(json.dumps(result, indent=2))
    sys.exit(0)

rows = []
for g, ms in metrics.items():
    for n, m in ms.items():
        v = m["value"]
        vs = json.dumps(v, sort_keys=True) if isinstance(v, dict) else str(v)
        rows.append((f"{g}.{n}", vs, windows[f"{g}.{n}"], m["source"], m.get("note", "")))
w0 = max(len(r[0]) for r in rows); w1 = max(8, max(len(r[1]) for r in rows)); w2 = max(len(r[2]) for r in rows)
print(f"dream-scorecard  generated {result['generated_at']}  window since {since}  host-local paths")
for k, v in sources.items():
    if not k.endswith("_attempted"):
        print(f"  source {k:<18} {v}")
print()
print(f"{'metric':<{w0}}  {'value':<{w1}}  {'window':<{w2}}  source")
for name, vs, win, src, note in rows:
    print(f"{name:<{w0}}  {vs:<{w1}}  {win:<{w2}}  {src}" + (f"  # {note}" if note else ""))
sys.exit(0)
PY
