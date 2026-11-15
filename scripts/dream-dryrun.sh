#!/usr/bin/env bash
# dream-dryrun.sh — /dream hook `dream.dryrun` (end of Phase 3, every PRD): before persist,
# ask the destination's own intake and admission checks, and the public URLs a PRD's Live
# ACs or `Premise:` name, what they would say about each drafted PRD
# (PRD-dream-dryrun-hook, with the A1710 explain-lifetime amendment).
#
# Read-only toward the destination corpus, and toward every live clone the composed lint
# reaches. Steps:
#   (a) stage one temporary corpus: build-queue/ = a COPY of every given file plus
#       symlinks to the destination's other build-queue/PRD-*.md (a given file wins over a
#       same-named link); built-prds/ and parked/ = symlinks to the destination's
#       directories; visions/ = copies of each given file's own home's visions (home = the
#       parent of build-queue/|built-prds/|parked/, else the file's own directory); an
#       empty state/. The lint and `explain` then answer about ONE corpus, the
#       destination's view. Two given files with one file name are both `ineligible —
#       lint: slug-not-unique` and neither is linted or explained.
#   (b) scripts/dream-lint.sh on each staged copy (reused), with DREAM_LINT_WM_BUILD set to a
#       one-line wrapper running the resolved binary with `--prd-dir <tmp>` (named relative
#       to the run's temporary directory, so a TMPDIR holding spaces or glob characters
#       still works with dream-lint.sh's unquoted expansion), PRD_LINT_NO_FETCH=1 and
#       GIT_OPTIONAL_LOCKS=0 (prd-lint's referent check reads each build_into's existing
#       origin/main: no `git fetch`, no network, no write into a live clone; its answer is
#       as fresh as that clone's last fetch). A FAIL yields `ineligible — lint: <first
#       failing id>` and skips (c) and the URL probe.
#   (c) `<wm-build> explain --prd-dir <tmp> --state-dir <tmp>/state <slug>`, waited for to
#       completion: there is NO default deadline (A1710 amendment; a healthy real explain
#       takes 7.8–11.6 s on a loaded build host). DREAM_DRYRUN_EXPLAIN_TIMEOUT=<seconds> is
#       an optional caller-selected diagnostic, unset by default; when it fires the verdict
#       is `unknown — explain: diagnostic-timeout <n>s`, never a refusal or eligibility.
#       Only the `tick-would:` line is parsed — never the JSON `eligible` flag, never the exit:
#         admit                          -> eligible
#         skip:depends-unresolved:<dep>  -> waiting — … when <dep> is a batch member or a
#                                           destination build-queue/ file, else ineligible — …
#         skip:prefix-denied             -> ineligible — prefix-denied@<hostname>
#         skip:<reason>                  -> ineligible — <reason>
#         no/unparseable line            -> unknown — explain: <first stderr line | no tick-would line>
#   Every child (lint, explain, prober) runs in a new process group the script creates;
#   its output goes to files, so the script waits for the child itself and never for a
#   pipe a grandchild holds. When the child exits, or the caller cancels the run
#   (SIGTERM, SIGINT, SIGHUP), what is left of that group is killed; nothing outside it
#   is signalled, and the temporary directory goes on every exit path.
#   URL probe (R7), for a file not already ineligible: every distinct scheme:// URL in a Live
#   AC's evidence or the `Premise:` value, IPv6 literals included. Never probed, each
#   `unknown — url: <url> <why>`: a non-http(s) scheme, a loopback/private/link-local/
#   reserved IP literal (legacy IPv4 spellings such as 127.1, 0x7f.0.0.1, 2130706433 and
#   IPv6 forms embedding one, ::ffff:127.0.0.1, 64:ff9b::7f00:1, 2002:7f00:1::, included)
#   or a local name (localhost, a single label, .local/.internal/…) -> not-public; userinfo
#   in the URL -> credentials (shown as scheme://***@host…, never printed); a host that is
#   not an IP literal or an ASCII letters-digits-hyphen name -> invalid-host. At most 10
#   probed per file (more: unknown — url: over-limit). One HEAD (5 s, no body, no
#   credentials, no redirects); 2xx/3xx ok (a 3xx Location is not followed or checked);
#   405 -> one ranged GET decides (405 again: unknown — url: <url> head-not-allowed);
#   other 4xx/5xx -> ineligible — url: <url> <code>; an error or timeout -> unknown — url:
#   <url> <error>.
#   Default prober trust boundary: a name is resolved first (5 s); if any answer is not a
#   global address the URL is `not-public (resolves to <addr>)` and nothing connects; else
#   curl is pinned to exactly the checked addresses (--resolve), so a second lookup cannot
#   land elsewhere; curl runs with -q (no .curlrc), --noproxy '*', -g, --proto =http,https,
#   no -L. A probe seam is trusted to do its own network handling.
# Every line ends ` claims=unknown open-runs=unknown`: the empty state dir cannot know them.
#
# wm-build discovery (R8): $DREAM_DRYRUN_WM_BUILD when set (a path; non-executable or
# missing = absent); else the first executable of `command -v wm-build`,
# $HOME/.cargo/bin/wm-build, $HOME/.local/bin/wm-build (the daemon unit's PATH order), so
# a judge's bare `bash -c` PATH still finds it. None: header wm-build=absent and every
# verdict that reaches (c) is `unknown — wm-build not found` (the lint half still runs).
# The header version is the first x.y.z[-pre][+build] token of `--version`'s first line,
# `unknown` when there is none.
# Seams: $DREAM_DRYRUN_URL_PROBE, a command given `<METHOD> <url>` that prints the status
# code (default: curl as above, -o /dev/null -w '%{http_code}', --max-time 5);
# $DREAM_DRYRUN_RESOLVE, a command given `<host>` that prints one address per line (default:
# the system resolver; used by the default prober only).
#
# Usage:
#   dream-dryrun.sh [--prd-dir <destination corpus>] [--json] <PRD file>...
#   dream-dryrun.sh --selftest        (runs tests/dreamdry_ac0[1-7]_*.sh on fixtures)
# Destination default: $DREAM_PRD_DIR, else ~/Documents/PRDs.
# Output: `dream-dryrun: host=<hostname> wm-build=<version|absent|unknown> prd-dir=<path>`, then
# one `admit-would: <slug> <verdict>[ — <reason>[; <reason>…]] claims=unknown open-runs=unknown`
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
import ipaddress, json, math, os, re, shlex, shutil, signal, socket, subprocess, sys, tempfile, threading, time
import urllib.parse

SELF = os.path.realpath(sys.argv[1])
HERE = os.path.dirname(SELF)
DREAM_LINT = os.path.join(HERE, "dream-lint.sh")
USAGE = "usage: dream-dryrun.sh [--prd-dir <destination corpus>] [--json] <PRD file>..."
TAIL = " claims=unknown open-runs=unknown"
URL_LIMIT = 10
PROBE_SECONDS = 5
RANK = {"eligible": 0, "waiting": 1, "unknown": 2, "ineligible": 3}
WRAPPER = "wm-build-prd-dir"


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

# Explain lifetime (A1710 amendment): no default deadline. An optional, caller-selected
# diagnostic deadline only when DREAM_DRYRUN_EXPLAIN_TIMEOUT is set and non-empty.
EXPLAIN_TIMEOUT = None
_raw = os.environ.get("DREAM_DRYRUN_EXPLAIN_TIMEOUT", "")
if _raw != "":
    try:
        EXPLAIN_TIMEOUT = float(_raw)
    except ValueError:
        EXPLAIN_TIMEOUT = None
    if EXPLAIN_TIMEOUT is None or not math.isfinite(EXPLAIN_TIMEOUT) or EXPLAIN_TIMEOUT <= 0:
        usage(f"DREAM_DRYRUN_EXPLAIN_TIMEOUT must be a positive number of seconds, got {_raw!r} "
              "(an optional diagnostic; unset means no deadline)")

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
VERSION_RE = re.compile(r"(?<![\w.])(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?![\w.])")


def slug_of(path):
    n = os.path.basename(path)
    n = n[:-3] if n.endswith(".md") else n
    return n[4:] if n.startswith("PRD-") else n


def home_of(path):
    d = os.path.dirname(os.path.abspath(path))
    return os.path.dirname(d) if os.path.basename(d) in ("build-queue", "built-prds", "parked") else d


# ---- URL extraction and classification (R7) ---------------------------------
URL_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://(?:\[[^\]\s`'\"<>]*\]|[^\s`'\"<>()\[\]{}])+")
LIVE_RE = re.compile(r"\(Live;\s*evidence:\s*(.*)\)\s*$")
PRIVATE_SUFFIX = (".localhost", ".local", ".internal", ".lan", ".home.arpa", ".ts.net")
LABEL_RE = re.compile(r"^[a-z0-9_-]+$")
NUMERIC_LABEL_RE = re.compile(r"^(?:0x[0-9a-f]*|[0-9]+)$")
EMBEDS_V4 = [ipaddress.ip_network(n) for n in ("::/96", "64:ff9b::/96", "64:ff9b:1::/48")]


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


def redact(url):
    """The URL with any userinfo replaced by ***: a credential is never printed."""
    return re.sub(r"^([A-Za-z][A-Za-z0-9+.-]*://)[^/?#]*@", r"\1***@", url)


def ip_public(ip):
    """A global address that embeds no non-global IPv4 (mapped, 6to4, Teredo, NAT64,
    IPv4-compatible)."""
    if not ip.is_global:
        return False
    if ip.version == 6:
        emb = [ip.ipv4_mapped, ip.sixtofour] + list(ip.teredo or ())
        if any(ip in n for n in EMBEDS_V4):
            emb.append(ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF))
        if any(e is not None and not e.is_global for e in emb):
            return False
    return True


def classify(url):
    """('probe', host, port, ip-or-None) for a URL the prober may ask, else
    (outcome,) with outcome not-public | credentials | invalid-host."""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return ("invalid-host",)
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https"):
        return ("not-public",)
    if "@" in parts.netloc:
        return ("credentials",)
    try:
        h, port = parts.hostname, parts.port
    except ValueError:
        return ("invalid-host",)
    if not h:
        return ("invalid-host",)
    port = port or (443 if scheme == "https" else 80)
    if parts.netloc.startswith("["):
        try:
            ip = ipaddress.IPv6Address(h.split("%")[0])
        except ValueError:
            return ("invalid-host",)
        return ("probe", h, port, ip) if ip_public(ip) else ("not-public",)
    name = h.rstrip(".")
    labels = name.split(".")
    if not name or not name.isascii() or any(not LABEL_RE.match(x) for x in labels):
        return ("invalid-host",)
    if NUMERIC_LABEL_RE.match(labels[-1]):
        # an IPv4 address in any spelling the URL standard and inet_aton accept
        try:
            ip = ipaddress.IPv4Address(socket.inet_aton(name))
        except OSError:
            return ("invalid-host",)
        return ("probe", h, port, ip) if ip_public(ip) else ("not-public",)
    if name == "localhost" or len(labels) == 1 or ("." + name).endswith(PRIVATE_SUFFIX):
        return ("not-public",)
    return ("probe", h, port, None)


def resolve(name, port):
    """-> ([ip, ...], None) | (None, "resolve: <error>") within PROBE_SECONDS."""
    seam = os.environ.get("DREAM_DRYRUN_RESOLVE", "")
    raw = []
    if seam:
        try:
            rc, out, err = run(shlex.split(seam) + [name], PROBE_SECONDS + 1)
        except OSError as e:
            return None, f"resolve: {e.strerror or e}"
        if rc is None:
            return None, "resolve: timeout"
        raw = [x.strip() for x in out.splitlines() if x.strip()]
        if rc != 0 or not raw:
            return None, "resolve: " + ((err.strip().splitlines() or [""])[0].strip() or f"exit-{rc}")
    else:
        box = {}

        def work():
            try:
                box["r"] = socket.getaddrinfo(name, port, type=socket.SOCK_STREAM)
            except OSError as e:
                box["e"] = e
        th = threading.Thread(target=work, daemon=True)
        th.start()
        th.join(PROBE_SECONDS)
        if th.is_alive():
            return None, "resolve: timeout"
        if "e" in box:
            e = box["e"]
            return None, f"resolve: {getattr(e, 'strerror', None) or e}"
        raw = [ai[4][0] for ai in box.get("r", [])]
        if not raw:
            return None, "resolve: no address"
    addrs = []
    for a in raw:
        try:
            ip = ipaddress.ip_address(a.split("%")[0])
        except ValueError:
            return None, f"resolve: not an address: {a[:60]}"
        if ip not in addrs:
            addrs.append(ip)
    return addrs, None


def probe(method, url, pin=None):
    """-> ("code", "404") | ("error", "<text>")"""
    seam = os.environ.get("DREAM_DRYRUN_URL_PROBE", "")
    if seam:
        cmd = shlex.split(seam) + [method, url]
    else:
        cmd = ["curl", "-q", "-sS", "-g", "--max-time", str(PROBE_SECONDS), "--proto", "=http,https",
               "--noproxy", "*", "-o", "/dev/null", "-w", "%{http_code}"]
        if pin:
            cmd += ["--resolve", f"{pin[0]}:{pin[1]}:" + ",".join(f"[{a}]" if a.version == 6 else str(a) for a in pin[2])]
        cmd += (["-I"] if method == "HEAD" else ["-r", "0-0"]) + ["--", url]
    try:
        rc, sout, serr = run(cmd, PROBE_SECONDS + 1)
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


# ---- children: own process group, output to files, scoped cleanup -----------
def wait_exited(pid, timeout):
    """Wait until the child has exited WITHOUT reaping it (WNOWAIT), so its process-group
    id cannot be reused before the group is cleaned up. True when it exited; False when
    `timeout` seconds passed first (timeout None: no deadline)."""
    if timeout is None:
        os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
        return True
    deadline = time.monotonic() + timeout
    while True:
        if os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT | os.WNOHANG) is not None:
            return True
        left = deadline - time.monotonic()
        if left <= 0:
            return False
        time.sleep(min(0.05, left))


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def run(cmd, timeout=None, env=None, cwd=None):
    """Run cmd in a new process group created here, stdout/stderr to unlinked files in the
    run's temporary directory. Waits for the child itself, never for a pipe a grandchild
    could hold. When the child exits, when `timeout` fires (only when a caller gave one),
    or when this script is stopped mid-call, what remains of the child's own group is
    killed; a process that left the group (setsid) is not this script's to signal.
    -> (rc, stdout, stderr), rc None when the timeout fired."""
    with tempfile.TemporaryFile(dir=tmp) as fo, tempfile.TemporaryFile(dir=tmp) as fe:
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=fo, stderr=fe, env=env, cwd=cwd,
                             start_new_session=True)
        try:
            exited = wait_exited(p.pid, timeout)
        except BaseException:              # this script being stopped mid-call
            kill_group(p.pid)
            p.wait()
            raise
        kill_group(p.pid)                  # leftovers of the owned group (leader not yet reaped)
        p.wait()
        if not exited:
            return None, "", ""
        fo.seek(0); fe.seek(0)
        return (p.returncode, fo.read().decode("utf-8", errors="replace"),
                fe.read().decode("utf-8", errors="replace"))


tmp = None


def on_signal(signum, frame):
    raise SystemExit(128 + signum)


for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(s, on_signal)

files = []
try:
    tmp = tempfile.mkdtemp(prefix="dream-dryrun.")
    if wb:
        try:
            vrc, vout, _ = run([wb, "--version"])
            m = VERSION_RE.search((vout.strip().splitlines() or [""])[0]) if vrc == 0 else None
            version = m.group(1) if m else "unknown"
        except OSError:
            version = "unknown"
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

    # (a) staging: copies of the given files (a given file wins over a same-named link);
    # two given files with one name collide: both are refused, neither is linted or explained
    readable = []
    for path in args:
        f = {"file": path, "slug": slug_of(path), "reasons": [], "lint": {"exit": None, "first_fail": None},
             "explain": {"tick_would": None, "checks": []}, "urls": [], "unknown": [], "staged": None}
        files.append(f)
        try:
            with open(path, "rb") as fh:
                readable.append((f, fh.read()))
        except OSError:
            f["reasons"].append(("unknown", "cannot read"))
    names = {}
    for f, _ in readable:
        names.setdefault(os.path.basename(f["file"]), []).append(f)
    for f, data in readable:
        name = os.path.basename(f["file"])
        if len(names[name]) > 1:
            f["reasons"].append(("ineligible", "lint: slug-not-unique"))
            f["lint"] = {"exit": None, "first_fail": "slug-not-unique"}
            continue
        target = os.path.join(sbq, name)
        if os.path.lexists(target):
            os.unlink(target)                  # removes OUR symlink in <tmp>, never its target
        with open(target, "wb") as fh:
            fh.write(data)
        f["staged"] = target
        vdir = os.path.join(home_of(f["file"]), "visions")
        if os.path.isdir(vdir):
            for vn in sorted(os.listdir(vdir)):
                src, dst = os.path.join(vdir, vn), os.path.join(tmp, "visions", vn)
                if os.path.isfile(src) and not os.path.lexists(dst):
                    shutil.copyfile(src, dst)
    batch = {f["slug"] for f in files}

    env = dict(os.environ)
    env["PRD_LINT_NO_FETCH"] = "1"         # the referent check reads origin/main as fetched: no network, no live-clone write
    env["GIT_OPTIONAL_LOCKS"] = "0"
    if wb:
        with open(os.path.join(tmp, WRAPPER), "w") as fh:
            fh.write(f"#!/bin/sh\nexec {shlex.quote(wb)} \"$@\" --prd-dir {shlex.quote(tmp)}\n")
        os.chmod(os.path.join(tmp, WRAPPER), 0o700)
        env["DREAM_LINT_WM_BUILD"] = "./" + WRAPPER   # relative to cwd=tmp: no space or glob in the word
    else:
        env["DREAM_LINT_WM_BUILD"] = ""

    for f in files:
        if f["staged"] is None:
            continue
        # (b) the lint hook, on the staged copy (no deadline)
        lrc, lo, le = run(["bash", DREAM_LINT, f["staged"]], env=env, cwd=tmp)
        lout = lo + le
        f["lint"] = {"exit": lrc, "first_fail": None if lrc == 0 else first_fail(lout, lrc)}
        if lrc != 0:
            f["reasons"].append(("ineligible", f"lint: {f['lint']['first_fail']}"))
            continue
        # (c) the daemon's own admission check, against the same staged corpus
        if not wb:
            f["reasons"].append(("unknown", "wm-build not found"))
        else:
            try:
                erc, out, err = run([wb, "explain", "--prd-dir", tmp, "--state-dir", os.path.join(tmp, "state"), f["slug"]],
                                    EXPLAIN_TIMEOUT)
            except OSError as e:
                erc, out, err = -1, "", f"{e.strerror or e}"
            if erc is None:
                f["reasons"].append(("unknown", f"explain: diagnostic-timeout {EXPLAIN_TIMEOUT:g}s"))
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
        seam_probe = bool(os.environ.get("DREAM_DRYRUN_URL_PROBE", ""))
        for u in urls:
            shown = redact(u)
            rec = {"url": shown, "probes": [], "outcome": None}
            f["urls"].append(rec)
            c = classify(u)
            if c[0] != "probe":
                rec["outcome"] = c[0]
                f["reasons"].append(("unknown", f"url: {shown} {c[0]}"))
                continue
            if probed >= URL_LIMIT:
                rec["outcome"] = "over-limit"
                continue
            probed += 1
            _, uhost, uport, uip = c
            pin = None
            if not seam_probe and uip is None:
                addrs, rerr = resolve(uhost, uport)
                if rerr:
                    rec["outcome"] = "error"
                    rec["probes"].append({"method": "RESOLVE", "error": rerr})
                    f["reasons"].append(("unknown", f"url: {shown} {rerr}"))
                    continue
                rec["probes"].append({"method": "RESOLVE", "addresses": [str(a) for a in addrs]})
                bad = [a for a in addrs if not ip_public(a)]
                if bad:
                    rec["outcome"] = "not-public"
                    f["reasons"].append(("unknown", f"url: {shown} not-public (resolves to {bad[0]})"))
                    continue
                pin = (uhost, uport, addrs)
            kind, val = probe("HEAD", u, pin)
            rec["probes"].append({"method": "HEAD", kind: val})
            if kind == "code" and val == "405":
                kind, val = probe("GET", u, pin)
                rec["probes"].append({"method": "GET", kind: val})
                if kind == "code" and val == "405":
                    rec["outcome"] = "head-not-allowed"
                    f["reasons"].append(("unknown", f"url: {shown} head-not-allowed"))
                    continue
            if kind == "error":
                rec["outcome"] = "error"
                f["reasons"].append(("unknown", f"url: {shown} {val}"))
            elif val[0] in "23":
                rec["outcome"] = "ok"
            elif val[0] in "45":
                rec["outcome"] = "refused"
                f["reasons"].append(("ineligible", f"url: {shown} {val}"))
            else:
                rec["outcome"] = "unknown"
                f["reasons"].append(("unknown", f"url: {shown} {val}"))
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
