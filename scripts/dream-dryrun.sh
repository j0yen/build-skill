#!/usr/bin/env bash
# dream-dryrun.sh — /dream hook `dream.dryrun` (end of Phase 3, every PRD): before persist,
# ask the destination's own intake and admission checks, and the public URLs a PRD's Live
# ACs or `Premise:` name, what they would say about each drafted PRD
# (PRD-dream-dryrun-hook).
#
# Read-only toward the destination corpus. Steps:
#   (a) stage one temporary corpus: build-queue/ = a COPY of every given file plus
#       symlinks to the destination's other build-queue/PRD-*.md (a given file wins over a
#       same-named link); built-prds/ and parked/ = symlinks to the destination's
#       directories; visions/ = copies of each given file's own home's visions (home = the
#       parent of build-queue/|built-prds/|parked/, else the file's own directory); an
#       empty state/. The lint and `explain` then answer about ONE corpus, the
#       destination's view.
#   (b) scripts/dream-lint.sh on each staged copy (reused), with DREAM_LINT_WM_BUILD set to a
#       one-line wrapper running the resolved binary with `--prd-dir <tmp>`; a FAIL yields
#       `ineligible — lint: <first failing id>` and skips (c) and the URL probe.
#   (c) `<wm-build> explain --prd-dir <tmp> --state-dir <tmp>/state <slug>` (10 s timeout;
#       DREAM_DRYRUN_EXPLAIN_TIMEOUT overrides: the real 0.77.112 explain took 7.1 s on
#       ryzen7 against ~/Documents/PRDs, 11-15),
#       parsing ONLY the `tick-would:` line — never the JSON `eligible` flag, never the exit:
#         admit                          -> eligible
#         skip:depends-unresolved:<dep>  -> waiting — … when <dep> is a batch member or a
#                                           destination build-queue/ file, else ineligible — …
#         skip:prefix-denied             -> ineligible — prefix-denied@<hostname>
#         skip:<reason>                  -> ineligible — <reason>
#         no/unparseable line            -> unknown — explain: <first stderr line | no tick-would line>
#   URL probe (R7), for a file not already ineligible: every distinct scheme:// URL in a Live
#   AC's evidence or the `Premise:` value; loopback/private/non-http -> unknown — url: <url>
#   not-public (never probed); at most 10 per file (more: unknown — url: over-limit). One HEAD
#   (5 s, no body, no credentials, no redirects); 2xx/3xx ok; 405 -> one ranged GET decides
#   (405 again: unknown — url: <url> head-not-allowed); other 4xx/5xx -> ineligible — url:
#   <url> <code>; an error or timeout -> unknown — url: <url> <error>.
# Every line ends ` claims=unknown open-runs=unknown`: the empty state dir cannot know them.
#
# wm-build discovery (R8): $DREAM_DRYRUN_WM_BUILD when set (a path; non-executable or
# missing = absent); else the first executable of `command -v wm-build`,
# $HOME/.cargo/bin/wm-build, $HOME/.local/bin/wm-build (the daemon unit's PATH order), so
# a judge's bare `bash -c` PATH still finds it. None: header wm-build=absent and every
# verdict that reaches (c) is `unknown — wm-build not found` (the lint half still runs).
# URL prober seam: $DREAM_DRYRUN_URL_PROBE, a command given `<METHOD> <url>` that prints the
# status code (default: curl -sS -I / curl -sS -r 0-0, -o /dev/null -w '%{http_code}',
# --max-time 5, no .curlrc, no redirects).
#
# Usage:
#   dream-dryrun.sh [--prd-dir <destination corpus>] [--json] <PRD file>...
#   dream-dryrun.sh --selftest        (runs tests/dreamdry_ac0[1-7]_*.sh on fixtures)
# Destination default: $DREAM_PRD_DIR, else ~/Documents/PRDs.
# Output: `dream-dryrun: host=<hostname> wm-build=<version|absent> prd-dir=<path>`, then one
# `admit-would: <slug> <verdict>[ — <reason>[; <reason>…]] claims=unknown open-runs=unknown`
# per file in argument order; --json prints one object instead (R6).
# Exit: 0 all eligible | 3 any ineligible | 4 no ineligible, any unknown | 5 only eligible
#       and waiting, at least one waiting | 2 usage | 1 internal error or the destination
#       is not a directory.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "dream-dryrun: python3 not found on PATH" >&2
  exit 1
fi

SELF="${BASH_SOURCE[0]}"
case "${1:-}" in
  -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; exit 0 ;;
  --selftest)
    here="$(cd "$(dirname "$SELF")" && pwd)"; fails=0; n=0
    for t in "$here"/../tests/dreamdry_ac0[1-7]_*.sh; do
      n=$((n + 1))
      if out="$(bash "$t" 2>&1)"; then echo "ok   $(basename "$t")"; else echo "FAIL $(basename "$t")"; printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/     /'; fails=$((fails + 1)); fi
    done
    [ "$n" -gt 0 ] || { echo "SELFTEST FAILED (no tests/dreamdry_ac0N_*.sh found)"; exit 1; }
    [ "$fails" -eq 0 ] && { echo "SELFTEST PASSED ($n tests)"; exit 0; }
    echo "SELFTEST FAILED ($fails/$n tests)"; exit 1 ;;
esac

exec python3 -I - "$SELF" "$@" <<'PY'
import ipaddress, json, os, re, shlex, shutil, signal, subprocess, sys, tempfile, urllib.parse

SELF = os.path.realpath(sys.argv[1])
HERE = os.path.dirname(SELF)
DREAM_LINT = os.path.join(HERE, "dream-lint.sh")
USAGE = "usage: dream-dryrun.sh [--prd-dir <destination corpus>] [--json] <PRD file>..."
TAIL = " claims=unknown open-runs=unknown"
URL_LIMIT = 10
RANK = {"eligible": 0, "waiting": 1, "unknown": 2, "ineligible": 3}


def usage(msg):
    print(f"dream-dryrun: {msg}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)


args, as_json, prd_dir = [], False, None
argv = sys.argv[2:]
i = 0
while i < len(argv):
    a = argv[i]
    if a == "--json":
        as_json = True
    elif a == "--prd-dir":
        if i + 1 >= len(argv) or not argv[i + 1]:
            usage("--prd-dir needs a value")
        prd_dir = argv[i + 1]; i += 1
    elif a.startswith("--prd-dir="):
        prd_dir = a.split("=", 1)[1]
    elif a == "--":
        args += argv[i + 1:]; break
    elif a.startswith("-") and a != "-":
        usage(f"unknown flag: {a}")
    else:
        args.append(a)
    i += 1
if not args:
    usage("no PRD file given")

HOME = os.path.expanduser("~")
dest = os.path.abspath(prd_dir or os.environ.get("DREAM_PRD_DIR") or os.path.join(HOME, "Documents", "PRDs"))
if not os.path.isdir(dest):
    print(f"dream-dryrun: destination corpus is not a directory: {dest}", file=sys.stderr)
    sys.exit(1)
host = os.uname().nodename


# ---- R8: the daemon binary --------------------------------------------------
def executable(p):
    return bool(p) and os.path.isfile(p) and os.access(p, os.X_OK)


if "DREAM_DRYRUN_WM_BUILD" in os.environ:
    cands = [os.environ["DREAM_DRYRUN_WM_BUILD"]]
else:
    cands = [shutil.which("wm-build"), os.path.join(HOME, ".cargo", "bin", "wm-build"),
             os.path.join(HOME, ".local", "bin", "wm-build")]
wb = next((c for c in cands if executable(c)), None)
version = "absent"
if wb:
    try:
        r = subprocess.run([wb, "--version"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        first = (r.stdout.strip().splitlines() or [""])[0].split()
        version = first[-1] if r.returncode == 0 and first else "unknown"
    except (OSError, subprocess.SubprocessError):
        version = "unknown"


def slug_of(path):
    n = os.path.basename(path)
    n = n[:-3] if n.endswith(".md") else n
    return n[4:] if n.startswith("PRD-") else n


def home_of(path):
    d = os.path.dirname(os.path.abspath(path))
    return os.path.dirname(d) if os.path.basename(d) in ("build-queue", "built-prds", "parked") else d


# ---- URL extraction and classification (R7) ---------------------------------
URL_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s`'\"<>()\[\]{}]+")
LIVE_RE = re.compile(r"\(Live;\s*evidence:\s*(.*)\)\s*$")
PRIVATE_SUFFIX = (".localhost", ".local", ".internal", ".lan", ".home.arpa", ".ts.net")


def urls_of(text):
    lines = text.splitlines()
    found = []
    for ln in lines[:80]:
        if ln.startswith("## "):
            break
        k = re.sub(r"^[-*+]\s+", "", ln.strip())
        k = re.sub(r"^\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
        m = re.match(r"^Premise\s*:\s*(.*)$", k)
        if m:
            found += URL_RE.findall(m.group(1))
    in_ac = False
    for ln in lines:
        if ln.startswith("## "):
            in_ac = ln[3:].strip().lower().startswith("acceptance criteria")
            continue
        if in_ac:
            m = LIVE_RE.search(ln)
            if m:
                found += URL_RE.findall(m.group(1))
    out = []
    for u in found:
        u = u.rstrip(".,;:!?")
        if u not in out:
            out.append(u)
    return out


def not_public(url):
    try:
        parts = urllib.parse.urlsplit(url)
        h = parts.hostname
    except ValueError:
        return True
    if parts.scheme.lower() not in ("http", "https") or not h:
        return True
    try:
        return not ipaddress.ip_address(h).is_global
    except ValueError:
        pass
    h = h.lower().rstrip(".")
    return h == "localhost" or "." not in h or h.endswith(PRIVATE_SUFFIX)


def probe(method, url):
    """-> ("code", "404") | ("error", "<text>")"""
    seam = os.environ.get("DREAM_DRYRUN_URL_PROBE", "")
    if seam:
        cmd = shlex.split(seam) + [method, url]
    else:
        cmd = ["curl", "-q", "-sS", "--max-time", "5", "--proto", "=http,https", "-o", "/dev/null",
               "-w", "%{http_code}"] + (["-I"] if method == "HEAD" else ["-r", "0-0"]) + ["--", url]
    try:
        rc, sout, serr = run(cmd, 6)
    except OSError as e:
        return "error", f"prober: {e.strerror or e}"
    if rc is None:
        return "error", "timeout"
    out = (sout.strip().splitlines() or [""])[0].strip()
    if re.fullmatch(r"[1-5]\d\d", out):
        return "code", out
    err = (serr.strip().splitlines() or [""])[0].strip()
    return "error", next(x for x in (out if out not in ("", "000") else "", err, f"exit-{rc}") if x)


# ---- lint output: the first failing id --------------------------------------
def first_fail(out, rc):
    m = re.search(r"^\s*\d+\. FAIL ([A-Za-z0-9_.:-]+):", out, re.M)
    if m:
        return m.group(1)
    sec = None
    for ln in out.splitlines():
        h = re.match(r"^-- wm-build lint \(exit (\d+)\)", ln)
        if h:
            sec = h.group(1) != "0"; continue
        if ln.startswith("-- "):
            sec = None; continue
        if sec:
            m = re.match(r"^\s+([a-z0-9][a-z0-9-]*): ", ln)
            if m:
                return m.group(1)
    if "FAIL dream-lint:" in out:
        return "dream-lint"
    return f"exit-{rc}"


def parse_checks(stdout):
    checks = []
    s = stdout.lstrip()
    if s.startswith("{"):
        try:
            obj, _ = json.JSONDecoder().raw_decode(s)
            for c in obj.get("checks") or []:
                if isinstance(c, dict):
                    checks.append({"name": c.get("name"), "passed": c.get("passed"), "detail": c.get("detail")})
        except ValueError:
            pass
    for ln in stdout.splitlines():
        m = re.match(r"^check: (\S+) passed=(true|false)(?: (.*))?$", ln)
        if m:
            checks.append({"name": m.group(1), "passed": m.group(2) == "true", "detail": m.group(3)})
    return checks


def run(cmd, timeout, env=None):
    """subprocess.run with a timeout that also reaps grandchildren: the child runs in its
    own process group (created here), and only that group is killed on timeout.
    -> (rc, stdout, stderr), rc None on timeout."""
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=env, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err
    except BaseException as e:            # timeout, or this script being stopped mid-call
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        if isinstance(e, subprocess.TimeoutExpired):
            return None, "", ""
        raise


try:
    EXPLAIN_TIMEOUT = float(os.environ.get("DREAM_DRYRUN_EXPLAIN_TIMEOUT") or 10)
except ValueError:
    usage("DREAM_DRYRUN_EXPLAIN_TIMEOUT must be a number of seconds")

tmp = None


def on_signal(signum, frame):
    raise SystemExit(128 + signum)


for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(s, on_signal)

files = []
try:
    tmp = tempfile.mkdtemp(prefix="dream-dryrun.")
    sbq = os.path.join(tmp, "build-queue")
    for d in ("build-queue", "visions", "state"):
        os.mkdir(os.path.join(tmp, d))
    dbq = os.path.join(dest, "build-queue")
    if os.path.isdir(dbq):
        for n in sorted(os.listdir(dbq)):
            if n.startswith("PRD-") and n.endswith(".md"):
                os.symlink(os.path.join(dbq, n), os.path.join(sbq, n))
    for sub in ("built-prds", "parked"):
        if os.path.isdir(os.path.join(dest, sub)):
            os.symlink(os.path.join(dest, sub), os.path.join(tmp, sub))
        else:
            os.mkdir(os.path.join(tmp, sub))

    # (a) staging: copies of the given files (a given file wins over a same-named link)
    staged_by = {}
    for path in args:
        f = {"file": path, "slug": slug_of(path), "reasons": [], "lint": {"exit": None, "first_fail": None},
             "explain": {"tick_would": None, "checks": []}, "urls": [], "unknown": [], "staged": None}
        files.append(f)
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            f["reasons"].append(("unknown", "cannot read"))
            continue
        name = os.path.basename(path)
        if name in staged_by:
            for g in (staged_by[name], f):
                if not any(t == "lint: slug-not-unique" for _, t in g["reasons"]):
                    g["reasons"].append(("ineligible", "lint: slug-not-unique"))
                g["lint"] = {"exit": None, "first_fail": "slug-not-unique"}
            continue
        target = os.path.join(sbq, name)
        if os.path.lexists(target):
            os.unlink(target)                  # removes OUR symlink in <tmp>, never its target
        with open(target, "wb") as fh:
            fh.write(data)
        staged_by[name] = f
        f["staged"] = target
        vdir = os.path.join(home_of(path), "visions")
        if os.path.isdir(vdir):
            for vn in sorted(os.listdir(vdir)):
                src, dst = os.path.join(vdir, vn), os.path.join(tmp, "visions", vn)
                if os.path.isfile(src) and not os.path.lexists(dst):
                    shutil.copyfile(src, dst)
    batch = {f["slug"] for f in files}

    env = dict(os.environ)
    if wb:
        wrapper = os.path.join(tmp, "wm-build-prd-dir")
        with open(wrapper, "w") as fh:
            fh.write(f"#!/bin/sh\nexec {shlex.quote(wb)} \"$@\" --prd-dir {shlex.quote(tmp)}\n")
        os.chmod(wrapper, 0o700)
        env["DREAM_LINT_WM_BUILD"] = wrapper
    else:
        env["DREAM_LINT_WM_BUILD"] = ""

    for f in files:
        if f["staged"] is None:
            continue
        # (b) the lint hook, on the staged copy
        lrc, lo, le = run(["bash", DREAM_LINT, f["staged"]], 300, env)
        lout = lo + le
        if lrc is None:
            f["lint"] = {"exit": None, "first_fail": "timeout"}
            f["reasons"].append(("unknown", "lint: timeout"))
            continue
        f["lint"] = {"exit": lrc, "first_fail": None if lrc == 0 else first_fail(lout, lrc)}
        if lrc != 0:
            f["reasons"].append(("ineligible", f"lint: {f['lint']['first_fail']}"))
            continue
        # (c) the daemon's own admission check, against the same staged corpus
        if not wb:
            f["reasons"].append(("unknown", "wm-build not found"))
        else:
            erc, out, err = run([wb, "explain", "--prd-dir", tmp, "--state-dir", os.path.join(tmp, "state"), f["slug"]],
                                EXPLAIN_TIMEOUT)
            if erc is None:
                f["reasons"].append(("unknown", "explain: timeout"))
            else:
                f["explain"]["checks"] = parse_checks(out)
                tw = [ln[len("tick-would:"):].strip() for ln in out.splitlines() if ln.startswith("tick-would:")]
                tw = tw[-1] if tw else None
                f["explain"]["tick_would"] = tw
                errline = (err.strip().splitlines() or [""])[0].strip()
                if tw is not None and re.match(r"^admit(\s|$)", tw):
                    pass
                elif tw is not None and re.match(r"^skip:\S+", tw):
                    reason = tw[5:].split()[0]
                    if reason.startswith("depends-unresolved:"):
                        dep = slug_of(reason.split(":", 1)[1])
                        queued = dep in batch or os.path.isfile(os.path.join(dbq, f"PRD-{dep}.md"))
                        f["reasons"].append(("waiting" if queued else "ineligible", f"depends-unresolved:{dep}"))
                    elif reason == "prefix-denied":
                        f["reasons"].append(("ineligible", f"prefix-denied@{host}"))
                    else:
                        f["reasons"].append(("ineligible", reason))
                else:
                    f["reasons"].append(("unknown", f"explain: {errline or 'no tick-would line'}"))
        # R7: the URL probe, for a file not already ineligible
        if any(c == "ineligible" for c, _ in f["reasons"]):
            continue
        try:
            with open(f["staged"], encoding="utf-8", errors="replace") as fh:
                urls = urls_of(fh.read())
        except OSError:
            urls = []
        probed = 0
        for u in urls:
            rec = {"url": u, "probes": [], "outcome": None}
            f["urls"].append(rec)
            if not_public(u):
                rec["outcome"] = "not-public"
                f["reasons"].append(("unknown", f"url: {u} not-public"))
                continue
            if probed >= URL_LIMIT:
                rec["outcome"] = "over-limit"
                continue
            probed += 1
            kind, val = probe("HEAD", u)
            rec["probes"].append({"method": "HEAD", kind: val})
            if kind == "code" and val == "405":
                kind, val = probe("GET", u)
                rec["probes"].append({"method": "GET", kind: val})
                if kind == "code" and val == "405":
                    rec["outcome"] = "head-not-allowed"
                    f["reasons"].append(("unknown", f"url: {u} head-not-allowed"))
                    continue
            if kind == "error":
                rec["outcome"] = "error"
                f["reasons"].append(("unknown", f"url: {u} {val}"))
            elif val[0] in "23":
                rec["outcome"] = "ok"
            elif val[0] in "45":
                rec["outcome"] = "refused"
                f["reasons"].append(("ineligible", f"url: {u} {val}"))
            else:
                rec["outcome"] = "unknown"
                f["reasons"].append(("unknown", f"url: {u} {val}"))
        if any(r["outcome"] == "over-limit" for r in f["urls"]):
            f["reasons"].append(("unknown", "url: over-limit"))
except SystemExit:
    raise
except Exception as e:  # internal error: exit 1, the temporary directory still goes
    print(f"dream-dryrun: internal error: {type(e).__name__}: {e}", file=sys.stderr)
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1)
finally:
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)

for f in files:
    verdict = max((c for c, _ in f["reasons"]), key=lambda c: RANK[c], default="eligible")
    ordered = [t for c, t in f["reasons"] if c == verdict] + [t for c, t in f["reasons"] if c != verdict]
    f["verdict"], f["reason_texts"] = verdict, ordered
    f["unknown_texts"] = [t for c, t in f["reasons"] if c == "unknown"]

verdicts = {f["verdict"] for f in files}
rc = 3 if "ineligible" in verdicts else 4 if "unknown" in verdicts else 5 if "waiting" in verdicts else 0

if as_json:
    print(json.dumps({
        "host": host, "wm_build": version, "wm_build_path": wb, "prd_dir": dest,
        "files": [{"slug": f["slug"], "file": f["file"], "verdict": f["verdict"], "reasons": f["reason_texts"],
                   "lint": f["lint"], "explain": f["explain"], "urls": f["urls"], "unknown": f["unknown_texts"]}
                  for f in files],
    }, indent=2))
else:
    print(f"dream-dryrun: host={host} wm-build={version} prd-dir={dest}")
    for f in files:
        rs = f" — {'; '.join(f['reason_texts'])}" if f["reason_texts"] else ""
        print(f"admit-would: {f['slug']} {f['verdict']}{rs}{TAIL}")
sys.exit(rc)
PY
