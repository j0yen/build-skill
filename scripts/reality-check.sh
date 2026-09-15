#!/usr/bin/env bash
# reality-check.sh — the step after ship: within one tick of archive, every
# acceptance criterion that names a real substrate runs against it, for
# real, when the substrate is reachable (PRD-build-post-ship-reality-check).
#
# Born from one night's why-chain: four PRDs shipped green at their gate
# 2026-09-10/11 (gate-on-casper, gate-tools-scope, gate-tools-toolchain,
# unprivileged-user) and each failed at first real use, because the gate's
# evidence was fixtures written by the agent whose assumptions they encode.
# This script is the missing post-ship reality step: it extracts the ACs
# that name a real substrate, runs them for real when the substrate answers,
# records the verdict on the archived PRD itself, and drafts the follow-up
# PRD when reality disagreed with the fixture.
#
# Usage:
#   reality-check.sh plan <prd-path>
#       Extract substrate-naming ACs into a runnable JSON plan on stdout.
#       Every AC that names a real substrate (patterns: "live lane", "real
#       box", "on casper", "against the RedBaron endpoint", "systemctl
#       --user start", a known fleet hostname, or a URL) but has no
#       derivable command is still listed, as kind:"manual" with a reason
#       — never silently dropped (Technical considerations: "a missed AC is
#       listed manual, never silently skipped").
#
#   reality-check.sh run <prd-path> [--archive-dir DIR] [--no-push]
#       Runs `plan`, probes reachability per AC kind, runs the reachable
#       ones for real, writes `reality:`/`reality_receipt:`
#       (/`reality_followup:` on failure) into <prd-path>'s frontmatter,
#       journals `reality  <slug>  ok|failed|unreachable  (...)`, and on a
#       `failed` verdict drafts build-queue/PRD-<slug>-reality-<n>.md.
#       --no-push: commit the frontmatter edit locally but do not push (for
#       selftests against a scratch clone; still exercises the real git
#       commit path, only skips the network hop).
#
# Reachability probes (Technical considerations — "reuse what the lane
# already has"), each overridable by env var so a selftest can fake either
# side of the reachable/unreachable split without touching real infra:
#   box      $REALITY_CHECK_BURST_LANE (default: burst-lane.sh in this dir)
#            `<cmd> status --json`; reachable iff .active == true.
#   endpoint $REALITY_CHECK_CURL (default: curl); reachable iff
#            `<cmd> -m 8 -sS -o /dev/null -w '%{http_code}' <url>` prints a
#            2xx/3xx code.
#   unit     $REALITY_CHECK_SYSTEMCTL (default: systemctl); reachable iff
#            `<cmd> --user is-active <unit>` is not `unknown`/exit-4 (unit
#            not found at all) — active or inactive both count as
#            "reachable", since the point is "the unit exists to probe",
#            not "the unit happens to be running".
#
#   reality-check.sh pending-run <target>
#       Requirement 3/AC10: runs every registered box-only pending check
#       (state/reality-pending/*.json) against a box the lane just booted
#       for any reason — <target> (ip/hostname) is recorded on the receipt
#       only, this command trusts the caller that the box is up. Writes
#       reality=ok|failed + reality_receipt back onto the ORIGINAL parent
#       PRD (tier=box in the receipt), journals `reality <slug> ok|failed
#       (... tier=box ...)`, and removes the consumed registration so a
#       later boot doesn't re-run it. No dedicated box is ever booted for
#       this alone — see burst-lane.sh's `up` for where a lane would call
#       this opportunistically (wiring that call site is a follow-up, kept
#       out of this PRD's own engineering target of archive-step/receipts/
#       post-ship-tick to avoid destabilizing burst-lane's own gate).
#
#   reality-check.sh alarm-check
#       Requirement 4/AC11: any pending registration ≥6h old
#       ($REALITY_CHECK_ALARM_SECONDS, default 21600) with no boot window
#       fires exactly one alarm (journal line + stderr), then marks itself
#       alarmed so it never repeats for the same pending state. Never
#       boots a box. Meant to be invoked periodically by an existing
#       cadence (e.g. quota-watch); a dedicated timer is a follow-up, same
#       interim-surface posture as requirement 8's `open` below.
#
#   reality-check.sh open [--prd-dir <dir>] [--format json|text]
#       Requirement 8 (P1, visibility — no dedicated numbered AC, matching
#       gate-debt.sh's `open` precedent, so this subcommand doesn't gate
#       archive; it exists as a status surface to query). Lists every
#       archived PRD whose `reality: failed` drafted a `reality_followup:`
#       that is still unresolved (the follow-up PRD file still sits in
#       build-queue/, not yet built-prds/). `--format json` prints
#       `{"reality_open":[{"parent":"PRD-....md","followup":"PRD-....md"}, ...]}`;
#       default text prints `<parent> -> <followup>` one per line, or
#       nothing (exit 0) when none are open. This is the computation only —
#       wiring it into `hawk-probe.sh` (`REALITY:` emission — that script
#       already greps the journal's `  reality  ` lines this PRD's `run`
#       writes, at ~/.cache/hawk-probe.sh, so its producer side is already
#       satisfied; the script itself lives outside any git repo, confirmed
#       via `git rev-parse --show-toplevel` failing there and at every
#       parent up to `/`, same as PRD-build-gate-wall-clock AC8's finding)
#       and into a daily `reality_ok=<n> reality_failed=<n>` rollup line
#       (no existing generic daily-rollup script in this repo to extend —
#       `gate-wedge-rollup.sh` is gate-wedge-specific) or into
#       `burst-lane.sh status --json` (that script is large, shared, and
#       outside this PRD's Engineering target) is left as a follow-up,
#       exactly as gate-debt.sh requirement 6 left the same two wiring
#       points for its own visibility requirement: querying
#       `reality-check.sh open` directly is the interim surface.
#
# Exit: 0 ran (see the printed verdict; a per-AC failure is reflected in
#         `reality: failed`, not a nonzero exit — this command's own job is
#         to RECORD reality, not to gate on it) | 2 usage/resolution error.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

PRD_LINT="$HERE/prd-lint.sh"
JOURNAL_DIR="${BUILD_JOURNAL_DIR:-$HOME/brain/journal/build}"
RECEIPTS_DIR="${BUILD_RECEIPTS_DIR:-$JOURNAL_DIR/receipts}"
JQ="${JQ:-$(command -v jq || echo /usr/bin/jq)}"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c "user.name=Joe Yen")
PRD_DIR_DEFAULT="${PRD_DIR:-$HOME/Documents/PRDs}"

log() { printf 'reality-check: %s\n' "$*" >&2; }
die() { printf 'reality-check: %s\n' "$*" >&2; exit "${2:-2}"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
  sed -n '2,100p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift

# ---- plan: extract substrate-naming ACs into a runnable list -------------
# All the text work happens in one python3 process (matches prd-lint.sh's
# convention) so pattern-matching stays simple and testable in isolation.
do_plan() {
  local prd="$1"
  [ -n "$prd" ] && [ -r "$prd" ] || die "PRD path required and must be readable: '$prd'"
  python3 - "$prd" <<'PY'
import json, re, sys

prd = sys.argv[1]
with open(prd, encoding="utf-8", errors="replace") as fh:
    lines = fh.read().splitlines()

AC_HEADING_RE = re.compile(r"^##\s+Acceptance(?:\s+(criteria|tests))?\s*$", re.I)
AC_NUM_RE = re.compile(r"^(\d+)\.\s+(.*)$")

# Group each numbered AC with its indented continuation lines, same shape
# as prd-lint.sh's item grouping.
items = []
in_section = False
cur = None
for raw in lines:
    s = raw.strip()
    if AC_HEADING_RE.match(s):
        in_section = True
        continue
    if in_section and raw.startswith("## "):
        break
    if not in_section:
        continue
    m = AC_NUM_RE.match(s)
    if m:
        if cur is not None:
            items.append(cur)
        cur = {"ac": int(m.group(1)), "text": s}
    elif cur is not None and s:
        cur["text"] += " " + s
    elif cur is not None and not s:
        items.append(cur)
        cur = None
if cur is not None:
    items.append(cur)

FLEET_HOSTS = ("casper", "redbaron", "carbon", "ryzen7", "wintermute hub", "hetzner")
# Deliberately narrow (requirement 1's own list, verbatim) — an early draft
# widened this to bare "live"/"real" to also catch looser real-world
# phrasing (e.g. unprivileged-user's own AC4: "Given the live mcphost repo
# ... When `parity` runs post-ship..."), but a corpus-wide dry run of
# `plan` against every archived PRD showed why that's unsafe: "real"/"live"
# are common words, and a nearby backtick-quoted token is very often just
# a prose identifier or JSON field name ("box: Delta", "box: Refuted",
# "box: PetFbiPartnerSyndicator"), not a shell command — `run` would eval
# that literally. Staying narrow means a real-substrate AC written in
# looser prose is correctly NOT auto-run; it still surfaces to an operator
# because prd-lint's "Real-environment AC rule" (SKILL.md) requires such a
# PRD to carry a literal, substrate-naming AC in the first place — the
# fix for a miss here is tightening that AC's wording, not loosening this
# regex.
# STRONG_RE: an unambiguous assertion this AC runs against real
# infrastructure — auto-run eligible (paired with a literal backtick
# command). WEAK_HOST_RE (a bare fleet hostname with none of the strong
# phrases) is NOT auto-run eligible on its own: a corpus-wide dry run of
# `plan` against every archived PRD showed a bare hostname mention
# anywhere in an AC's (possibly multi-sentence) text pairing with an
# UNRELATED backtick token elsewhere in the same AC — "SKILL.md", a PRD
# filename, a JSON field name, "box: Delta" — none of them shell commands.
# `run` would `eval` that literally. A weak-only match still enters the
# plan, but always as `manual`, naming the host, so a human can turn it
# into a real check rather than it silently vanishing OR getting executed
# as garbage.
STRONG_RE = re.compile(
    r"\blive lane\b|\breal box\b|\bon casper\b|\bagainst the redbaron endpoint\b", re.I)
WEAK_HOST_RE = re.compile(
    r"\b(" + "|".join(re.escape(h) for h in FLEET_HOSTS) + r")\b", re.I)
# Requirement 3 (P0, PRD-build-post-ship-reality-check, 2026-09-12): every
# "box" kind AC is further tagged container-coverable (default — a fresh,
# empty, non-root container on RedBaron can stand in for the real box; the
# 09-10/11 failure classes named in this PRD — no-op installs, wrong
# toolchain, uid-0 refusal — are all about behavior in an empty environment,
# not about the box's own cloud specifics) or box-only (needs hcloud API /
# snapshots / cloud-init / real disk sizing — a container cannot fake these,
# only a real boot can exercise them). Narrow keyword match, same posture as
# STRONG_RE/WEAK_HOST_RE above: false-negative (missed box-only, treated as
# container-coverable) is safe because run() still records a real pass/fail
# either way; false-positive box-only would just mean an AC that could have
# run this tick instead waits for the lane's next boot, also safe, never
# silent.
BOX_ONLY_RE = re.compile(
    r"\bhcloud\b|\bsnapshot\b|\bcloud-init\b|\bdisk siz|\bprovision|\bparity\b", re.I)
# `parity` (burst-lane.sh's own remote-vs-local tree diff, cmd_parity) is
# named explicitly: it inherently compares against the REAL box's actual
# disk state, which a fresh empty container has none of to compare —
# classifying it container-coverable would make an unreachable box's parity
# check spuriously "fail" on a missing binary instead of correctly waiting
# for the box, the wrong failure for the wrong reason.
URL_RE = re.compile(r"https?://[^\s`)]+[^\s`),.]")
BACKTICK_CMD_RE = re.compile(r"`([^`]+)`")
SYSTEMCTL_CMD_RE = re.compile(r"systemctl\s+--user\s+[^\s`]+(?:\s+[^\s`]+)?")
FAKE_RE = re.compile(r"\bfake\b", re.I)
PLACEHOLDER_RE = re.compile(r"<[^<>`\s]+>")

plan = []
for it in items:
    n, text = it["ac"], it["text"]
    url_m = URL_RE.search(text)
    systemctl_m = SYSTEMCTL_CMD_RE.search(text)
    backtick_cmds = BACKTICK_CMD_RE.findall(text)
    strong_m = STRONG_RE.search(text)
    weak_m = WEAK_HOST_RE.search(text)

    if not (url_m or strong_m or weak_m or systemctl_m):
        continue  # not a substrate-naming AC at all — not in the plan

    # Guard against a fixture AC that's DESCRIBING a fake/mock substrate
    # ("Given a fake box whose test run differs...") rather than asserting
    # a real one. A strong, unambiguous real-substrate phrase (or a URL)
    # still counts even if "fake" appears elsewhere in the same AC's text;
    # a bare hostname alone next to "fake" is exactly the fixture-
    # description shape this guard exists for.
    if FAKE_RE.search(text) and not (url_m or strong_m):
        continue

    if systemctl_m:
        # Auto-run only read-only/idempotent verbs. A post-ship reality
        # check's job is to confirm something IS running, not to disrupt a
        # live unit — `restart`/`stop`/`disable`/etc. downgrade to manual
        # so a human decides whether to actually run them.
        verb = systemctl_m.group(0).split()[2] if len(systemctl_m.group(0).split()) > 2 else ""
        SAFE_VERBS = {"status", "is-active", "is-failed", "is-enabled",
                      "show", "list-timers", "list-units", "cat", "start"}
        if verb in SAFE_VERBS:
            plan.append({"ac": n, "kind": "unit", "command": systemctl_m.group(0),
                          "text": text, "reason": None})
        else:
            plan.append({"ac": n, "kind": "manual", "command": None, "text": text,
                          "reason": f"systemctl verb {verb!r} is state-changing "
                                    "(not in the auto-run allowlist) — needs manual review"})
        continue
    if url_m and PLACEHOLDER_RE.search(url_m.group(0)):
        # A URL containing an angle-bracket placeholder (e.g.
        # `https://<fqdn>/healthz`) is a template, not a literal address —
        # curl would try to resolve the hostname "<fqdn>" verbatim. Manual.
        plan.append({"ac": n, "kind": "manual", "command": None, "text": text,
                      "reason": f"URL {url_m.group(0)!r} contains a <placeholder> "
                                "token, not a literal address"})
        continue
    if url_m and any(url_m.group(0) in c for c in backtick_cmds):
        # URL appears inside a backtick command — prefer the literal command.
        cmd = next(c for c in backtick_cmds if url_m.group(0) in c)
        plan.append({"ac": n, "kind": "endpoint", "command": cmd,
                      "text": text, "reason": None})
        continue
    if url_m:
        plan.append({"ac": n, "kind": "endpoint", "command": url_m.group(0),
                      "text": text, "reason": None})
        continue
    if strong_m:
        # A backtick command containing an angle-bracket placeholder (e.g.
        # `burst-lane.sh parity <repo>`) is documentation shorthand, not a
        # literal invocation — running it verbatim would shell-redirect
        # stdin from a file literally named "repo". Manual, naming why.
        literal_cmds = [c for c in backtick_cmds if not PLACEHOLDER_RE.search(c)]
        if backtick_cmds and not literal_cmds:
            plan.append({"ac": n, "kind": "manual", "command": None, "text": text,
                          "reason": f"backtick command {backtick_cmds[0]!r} contains "
                                    "a <placeholder> token, not a literal invocation"})
            continue
        if literal_cmds:
            # A strong substrate phrase plus a literal backtick command —
            # run the command against the box (the common shape: "run
            # `<cmd>` against the live lane"). Tag its tier (requirement 3).
            tier = "box-only" if BOX_ONLY_RE.search(text) else "container-coverable"
            plan.append({"ac": n, "kind": "box", "command": literal_cmds[0],
                          "text": text, "reason": None, "tier": tier})
            continue
        # Strong phrase, no derivable command — manual, never dropped.
        plan.append({"ac": n, "kind": "manual", "command": None, "text": text,
                      "reason": "AC names a real substrate but no runnable command "
                                "(no backtick command, URL, or systemctl invocation) "
                                "could be derived from its text"})
        continue
    # Only a bare fleet hostname matched (no strong phrase, no URL, no
    # systemctl) — always manual, never auto-run (see WEAK_HOST_RE above).
    plan.append({"ac": n, "kind": "manual", "command": None, "text": text,
                  "reason": f"AC mentions fleet host {weak_m.group(1)!r} but not "
                            "a strong real-substrate phrase — a command near it "
                            "cannot be safely auto-derived, needs manual review"})

print(json.dumps(plan, indent=2))
PY
}

# ---- reachability probes (each overridable for selftests) ----------------
probe_box() {
  local cmd="${REALITY_CHECK_BURST_LANE:-$HERE/burst-lane.sh}"
  local out
  out="$($cmd status --json 2>/dev/null)" || { printf 'unreachable\t(status probe failed: %s status --json exited nonzero)\n' "$cmd"; return; }
  if printf '%s' "$out" | "$JQ" -e '.active == true' >/dev/null 2>&1; then
    printf 'reachable\t%s\n' "$out"
  else
    printf 'unreachable\t%s\n' "$out"
  fi
}

probe_endpoint() {
  local url="$1" cmd="${REALITY_CHECK_CURL:-curl}" code
  code="$($cmd -m 8 -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  case "$code" in
    2??|3??) printf 'reachable\thttp_code=%s\n' "$code" ;;
    *) printf 'unreachable\thttp_code=%s\n' "$code" ;;
  esac
}

probe_unit() {
  local unit="$1" cmd="${REALITY_CHECK_SYSTEMCTL:-systemctl}" out rc
  out="$($cmd --user is-active "$unit" 2>&1)"; rc=$?
  # exit 4 with "unknown"/"could not be found" = unit does not exist at all
  # (not reachable to probe); exit 0 (active) or exit 3 (inactive/failed)
  # both mean the unit exists and can be probed.
  if [ "$rc" -eq 4 ] || printf '%s' "$out" | grep -qiE 'could not be found|no such'; then
    printf 'unreachable\t%s\n' "$out"
  else
    printf 'reachable\t%s\n' "$out"
  fi
}

# ---- frontmatter writer: set arbitrary bullet keys in a PRD's first 80
# lines, inserting after Status if absent, atomic write (temp + rename).
# Same shape as lane-claim.sh's write_claim, generalized to N key/value
# pairs so run() can set reality/reality_receipt/reality_followup in one
# pass. Accepts pairs as "<key>=<value>" args.
write_frontmatter_keys() {
  local f="$1"; shift
  python3 - "$f" "$@" <<'PYEOF'
import re, sys
f = sys.argv[1]
pairs = []
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    pairs.append((k, v))
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]
status_idx = None
status_re = re.compile(r'^(?:-\s*Status:|Status:|\*\*Status:\*\*)')
for i, ln in enumerate(head):
    if status_re.match(ln.rstrip("\n")):
        status_idx = i
        break
insert_at = (status_idx + 1) if status_idx is not None else 1
for key, val in pairs:
    key_re = re.compile(r'^(?:-\s*' + re.escape(key) + r':|' + re.escape(key) + r':|\*\*' + re.escape(key) + r':\*\*)\s*.*$')
    idx = None
    for i, ln in enumerate(head):
        if key_re.match(ln.rstrip("\n")):
            idx = i
            break
    line = f"- {key}: {val}\n"
    if idx is not None:
        head[idx] = line
    else:
        head.insert(insert_at, line)
        insert_at += 1
with open(f, "w") as fh:
    fh.writelines(head + rest)
PYEOF
}

# ---- commit + push a PRD frontmatter edit (best-effort; --no-push for
# selftests against a scratch clone, mirroring lane-claim.sh's discipline
# of never touching the real ~/Documents/PRDs clone from a test).
commit_and_push() {
  local prd="$1" msg="$2" no_push="$3" root
  root="$(git -C "$(dirname "$prd")" rev-parse --show-toplevel 2>/dev/null)" || { log "not a git repo, skipping commit: $prd"; return 0; }
  git -C "$root" pull --rebase -q 2>/dev/null || log "pull --rebase failed (continuing with local commit only)"
  local rel; rel="$(realpath --relative-to="$root" "$prd")"
  git -C "$root" add -- "$rel"
  if git -C "$root" diff --cached --quiet -- "$rel"; then
    return 0
  fi
  git -C "$root" "${GIT_ID[@]}" commit -q -m "$msg" -- "$rel"
  if [ "$no_push" = true ]; then
    log "committed locally, --no-push: $rel"
    return 0
  fi
  local branch; branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" || return 0
  if ! git -C "$root" push origin "$branch" -q 2>/tmp/reality-check.push.err; then
    if git -C "$root" fetch origin -q 2>/dev/null && git -C "$root" rebase "origin/$branch" -q 2>/dev/null; then
      git -C "$root" push origin "$branch" -q 2>/tmp/reality-check.push2.err || log "push failed after rebase (frontmatter edit stays local): $(cat /tmp/reality-check.push2.err 2>/dev/null)"
    else
      git -C "$root" rebase --abort >/dev/null 2>&1 || true
      log "push failed, rebase failed (frontmatter edit stays local): $(cat /tmp/reality-check.push.err 2>/dev/null)"
    fi
  fi
}

# journal_line is now the shared scripts/lib/journal.sh one (sourced
# above): its default target ($(journal_root)/<date>.md) already matches
# this script's own JOURNAL_DIR/<date>.md convention, and BUILD_JOURNAL_DIR
# is one of the lib's honored legacy aliases, so call sites below are
# unchanged (PRD-build-test-isolation-by-default).

# ---- container tier (requirement 3, P0, container-coverable ACs) ---------
# Runs `cmd` in a fresh, empty, non-root sandbox on THIS host (RedBaron) via
# bwrap — never RedBaron's own environment, which would hide every missing-
# tool/toolchain/uid failure class the PRD is named for (the 09-10/11
# no-op-install / wrong-toolchain / uid-0-refusal defects). The rootfs is an
# empty tmpfs with only busybox (+ its dynamic-linker deps) bound in — no
# `/usr/bin`, no `~/.cargo/bin`, no gate tools reachable via PATH — and the
# process runs as uid/gid 65534 (nobody), never root. Overridable for
# selftests so a fake/broken bwrap can be exercised without touching the
# real sandbox.
PENDING_DIR="${REALITY_CHECK_PENDING_DIR:-$SKILL_DIR/state/reality-pending}"
run_in_container() {
  local cmd="$1"
  local bwrap_bin="${REALITY_CHECK_BWRAP:-bwrap}"
  local bb="${REALITY_CHECK_BUSYBOX:-/usr/bin/busybox}"
  if ! command -v "$bwrap_bin" >/dev/null 2>&1; then
    printf 'container tier unavailable: %s not found\n' "$bwrap_bin"
    return 127
  fi
  if [ ! -x "$bb" ]; then
    printf 'container tier unavailable: busybox not found at %s\n' "$bb"
    return 127
  fi
  local -a args=(
    --unshare-all --die-with-parent
    --uid 65534 --gid 65534
    --tmpfs / --dir /tmp --dir /bin
    --ro-bind "$bb" /bin/busybox
    --ro-bind /lib /lib
    --ro-bind /usr/lib /usr/lib
    --proc /proc --dev /dev
    --setenv HOME /tmp --setenv PATH /bin
    --chdir /tmp
  )
  [ -d /lib64 ] && args+=(--ro-bind /lib64 /lib64)
  "$bwrap_bin" "${args[@]}" /bin/busybox sh -c "$cmd" 2>&1
}

# ---- box-only pending registration (requirement 3/AC2/AC10) --------------
# A box-only AC whose real substrate is down on BOTH of two spaced probes
# registers here instead of just recording `unreachable` — the lane's next
# boot (for any reason) runs it first via `pending-run` before its ordinary
# work, per AC10. One file per (slug, AC) under state/reality-pending/, so a
# second `run` re-registering the same AC overwrites cleanly (idempotent).
register_pending() {
  local prd="$1" slug="$2" ac="$3" cmd="$4" reg_ts="$5" ev1="$6" ev2="$7"
  mkdir -p "$PENDING_DIR"
  local f="$PENDING_DIR/${slug}-ac${ac}.json"
  python3 - "$f" "$prd" "$slug" "$ac" "$cmd" "$reg_ts" "$ev1" "$ev2" <<'PY'
import json, sys
f, prd, slug, ac, cmd, reg_ts, ev1, ev2 = sys.argv[1:9]
data = {
    "prd": prd, "slug": slug, "ac": int(ac), "command": cmd,
    "registered_at": reg_ts,
    "probes": [{"ts": reg_ts, "reach": "unreachable", "evidence": ev1},
               {"ts": reg_ts, "reach": "unreachable", "evidence": ev2}],
    "alarmed": False,
}
with open(f, "w") as fh:
    json.dump(data, fh, indent=2)
PY
  journal_line "$(now_iso)  reality  pending  registered  (lane=$(hostname) slug=$slug ac=$ac file=$f)"
}

# ---- follow-up PRD drafting (requirement 5) -------------------------------
# Drafts build-queue/PRD-<slug>-reality-<n>.md, lints it with prd-lint.sh
# before it is written to the real queue, and never writes a PRD that
# doesn't pass. Returns the drafted filename on stdout.
draft_followup() {
  local prd="$1" slug="$2" failing_json="$3"
  local queue_dir; queue_dir="$(cd "$(dirname "$prd")/../build-queue" 2>/dev/null && pwd)"
  [ -n "$queue_dir" ] || queue_dir="$(dirname "$prd")"
  local n=1
  while [ -f "$queue_dir/PRD-${slug}-reality-${n}.md" ]; do n=$((n+1)); done
  local out="$queue_dir/PRD-${slug}-reality-${n}.md"
  # Write directly at the real destination (inside the real build-queue/)
  # before linting: prd-lint.sh resolves a relative `Vision:` path against
  # the file's OWN build-queue/built-prds sibling layout, so linting a
  # /tmp scratch file (whose dirname isn't named build-queue) would
  # false-fail vision-not-found even when the real destination is fine.
  # Never left behind on a lint failure (see below).
  local tmp="$out"
  python3 - "$prd" "$slug" "$n" "$failing_json" "$tmp" <<'PY'
import json, re, sys
prd_path, slug, n, failing_json, tmp = sys.argv[1:6]

def fm_get(lines, key):
    key_re = re.compile(r'^(?:-\s*' + re.escape(key) + r':|' + re.escape(key) + r':|\*\*' + re.escape(key) + r':\*\*)\s*(.*)$')
    for ln in lines[:80]:
        m = key_re.match(ln.rstrip("\n"))
        if m:
            return m.group(1).strip()
    return ""

with open(prd_path, encoding="utf-8", errors="replace") as fh:
    lines = fh.readlines()

build_target = fm_get(lines, "build_target") or "shell"
build_into = fm_get(lines, "build_into")
vision = fm_get(lines, "Vision")
publish = fm_get(lines, "publish") or "j0yen/private"
failing = json.loads(failing_json)

title = f"# PRD — {slug}-reality-{n}: post-ship reality check found {slug} failing on first real use\n\n"
fm = ["- Status: queued\n", f"- build_target: {build_target}\n"]
if build_into:
    fm.append(f"- build_into: {build_into}\n")
fm += [
    "- build_priority: high\n",
    f"- publish: {publish}\n",
]
if vision:
    fm.append(f"- Vision: {vision}\n")
fm += ["- PM: Joe\n", "- Drafted: (reality-check.sh)\n",
       f"- Engineering target: fix PRD-{slug}.md's failing acceptance "
       f"criteria found by reality-check.sh's post-ship run\n\n"]

first_cmd = failing[0]["command"] if failing else "(no command recorded)"
first_out = failing[0].get("output_tail", "") if failing else ""
first_ac = failing[0]["ac"] if failing else "?"

tldr = (
    "## TL;DR\n\n"
    f"reality-check.sh ran PRD-{slug}.md's post-ship reality check against "
    f"the real substrate and found it failing: `{first_cmd}` exited nonzero "
    f"where the shipped fixture asserted success.\n\n"
)

body = (
    "## Problem statement\n\n"
    f"Observation: `{first_cmd}` was run for real against the reachable "
    f"substrate named in PRD-{slug}.md's AC{first_ac}, and it exited "
    "nonzero. Output excerpt (last 20 lines):\n\n```\n"
    + "\n".join(first_out.splitlines()[-20:]) + "\n```\n\n"
    "First why: the acceptance criterion's fixture (mock ssh/rsync/state) "
    "asserted this path's success without ever executing it against the "
    "real substrate, so the gate could not see this failure before ship.\n\n"
)

ac_lines = ["## Acceptance criteria\n\n"]
for i, f in enumerate(failing, start=1):
    ac_lines.append(
        f"{i}. P0 — Given the real substrate reachable, When `{f['command']}` "
        f"runs (restating PRD-{slug}.md AC{f['ac']}), Then it exits 0 and "
        f"the original acceptance holds against reality, not only a fixture.\n"
    )
ac_lines.append("\n")

with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(title)
    fh.writelines(fm)
    fh.write(tldr)
    fh.write(body)
    fh.writelines(ac_lines)
PY
  if [ -x "$PRD_LINT" ] && ! "$PRD_LINT" "$tmp" >/tmp/reality-check.followup-lint.out 2>&1; then
    log "follow-up draft failed prd-lint.sh — not writing it:"
    cat /tmp/reality-check.followup-lint.out >&2
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$out"
}

# ---- run: probe + execute + record ----------------------------------------
do_run() {
  local prd="" no_push=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --archive-dir) shift 2 ;;  # accepted, currently unused (prd path is already the archive path)
      --no-push) no_push=true; shift ;;
      *) prd="$1"; shift ;;
    esac
  done
  [ -n "$prd" ] && [ -r "$prd" ] || die "PRD path required and must be readable: '$prd'"

  local base slug; base="$(basename "$prd")"; slug="${base#PRD-}"; slug="${slug%.md}"

  local plan_json; plan_json="$(do_plan "$prd")" || die "plan extraction failed for $prd"
  local n_runnable; n_runnable="$("$JQ" '[.[] | select(.kind != "manual")] | length' <<<"$plan_json")"
  if [ "${n_runnable:-0}" -eq 0 ]; then
    # AC7: a pure-fixture ship still gets a receipt saying so — never a
    # silently-skipped run that could be mistaken for a false pending.
    local receipt; mkdir -p "$RECEIPTS_DIR"
    receipt="$RECEIPTS_DIR/$(date -u +%F)-${slug}-reality.txt"
    {
      printf 'reality-check receipt for %s\n' "$slug"
      printf 'started-at: %s\n' "$(now_iso)"
      printf 'hostname: %s\n\n' "$(hostname)"
      printf 'result: fixture-only (no substrate-naming AC with a runnable command)\n'
    } >"$receipt"
    write_frontmatter_keys "$prd" "reality=fixture-only" "reality_receipt=$receipt"
    commit_and_push "$prd" "$slug: reality-check fixture-only (post-ship)" "$no_push"
    journal_line "$(now_iso)  reality  $slug  fixture-only  (lane=$(hostname) receipt=$receipt)"
    log "no non-manual substrate ACs for $slug — fixture-only, receipt recorded at $receipt"
    exit 0
  fi

  local ts; ts="$(now_iso)"
  local receipt; mkdir -p "$RECEIPTS_DIR"
  receipt="$RECEIPTS_DIR/$(date -u +%F)-${slug}-reality.txt"
  {
    printf 'reality-check receipt for %s\n' "$slug"
    printf 'started-at: %s\n' "$ts"
    printf 'hostname: %s\n\n' "$(hostname)"
  } >"$receipt"

  # Rank-ordered overall verdict: failed beats pending beats ok beats
  # unreachable, so one bad AC among several never gets masked by the
  # others' success, and a pending AC is never silently swallowed by an ok
  # one that happened to run first.
  local overall=unreachable
  declare -A REALITY_RANK=([unreachable]=0 [ok]=1 [pending]=2 [failed]=3)
  bump_overall() {
    local new="$1"
    if [ "${REALITY_RANK[$new]}" -gt "${REALITY_RANK[$overall]}" ]; then overall="$new"; fi
  }

  local -a failing_items=()
  local i count; count="$("$JQ" 'length' <<<"$plan_json")"
  for ((i=0; i<count; i++)); do
    local item kind cmd ac tier
    item="$("$JQ" -c ".[$i]" <<<"$plan_json")"
    kind="$("$JQ" -r '.kind' <<<"$item")"
    [ "$kind" = manual ] && continue
    cmd="$("$JQ" -r '.command' <<<"$item")"
    ac="$("$JQ" -r '.ac' <<<"$item")"
    tier="$("$JQ" -r '.tier // "n/a"' <<<"$item")"

    if [ "$kind" = box ]; then
      # Requirement 3 (P0): box kind gets the tier-aware path — reachable
      # runs live as before; unreachable + container-coverable runs in a
      # fresh RedBaron container THIS SAME TICK (AC9); unreachable +
      # box-only needs a second spaced probe before it's trusted as
      # genuinely down, then registers pending for the lane's next boot
      # (AC2/AC10) instead of a bare `unreachable`.
      local reach1 ev1
      IFS=$'\t' read -r reach1 ev1 < <(probe_box)
      {
        printf -- '--- AC%s (box, tier=%s) ---\n' "$ac" "$tier"
        printf 'command: %s\n' "$cmd"
        printf 'probe-1: %s (%s)\n' "$reach1" "$ev1"
      } >>"$receipt"

      if [ "$reach1" = reachable ]; then
        local out rc
        out="$(eval "$cmd" 2>&1)"; rc=$?
        printf 'ran: live (tier=live), exit=%s\n' "$rc" >>"$receipt"
        printf 'output (tail 20 lines):\n%s\n\n' "$(printf '%s' "$out" | tail -n 20)" >>"$receipt"
        if [ "$rc" -eq 0 ]; then
          printf 'result: ok (tier=live)\n\n' >>"$receipt"; bump_overall ok
        else
          printf 'result: failed (tier=live)\n\n' >>"$receipt"; bump_overall failed
          failing_items+=("$("$JQ" -c --arg cmd "$cmd" --arg out "$out" --arg tier live '. + {command:$cmd, output_tail:$out, tier:$tier}' <<<"$item")")
        fi
        continue
      fi

      if [ "$tier" = container-coverable ]; then
        local cout crc
        cout="$(run_in_container "$cmd")"; crc=$?
        printf 'ran: container (tier=container), exit=%s\n' "$crc" >>"$receipt"
        printf 'output (tail 20 lines):\n%s\n\n' "$(printf '%s' "$cout" | tail -n 20)" >>"$receipt"
        if [ "$crc" -eq 0 ]; then
          printf 'result: ok (tier=container)\n\n' >>"$receipt"; bump_overall ok
        else
          printf 'result: failed (tier=container)\n\n' >>"$receipt"; bump_overall failed
          failing_items+=("$("$JQ" -c --arg cmd "$cmd" --arg out "$cout" --arg tier container '. + {command:$cmd, output_tail:$out, tier:$tier}' <<<"$item")")
        fi
        continue
      fi

      # box-only: second spaced probe before trusting "genuinely down".
      sleep "${REALITY_CHECK_PROBE_SPACING:-5}"
      local reach2 ev2
      IFS=$'\t' read -r reach2 ev2 < <(probe_box)
      printf 'probe-2: %s (%s)\n' "$reach2" "$ev2" >>"$receipt"
      journal_line "$(now_iso)  reality  probe  probe-1  (lane=$(hostname) slug=$slug ac=$ac reach=$reach1 evidence=$ev1)"
      journal_line "$(now_iso)  reality  probe  probe-2  (lane=$(hostname) slug=$slug ac=$ac reach=$reach2 evidence=$ev2)"
      if [ "$reach2" = reachable ]; then
        # Came back up between probes — run it live after all.
        local out rc
        out="$(eval "$cmd" 2>&1)"; rc=$?
        printf 'ran: live-after-second-probe (tier=live), exit=%s\n' "$rc" >>"$receipt"
        printf 'output (tail 20 lines):\n%s\n\n' "$(printf '%s' "$out" | tail -n 20)" >>"$receipt"
        if [ "$rc" -eq 0 ]; then
          printf 'result: ok (tier=live)\n\n' >>"$receipt"; bump_overall ok
        else
          printf 'result: failed (tier=live)\n\n' >>"$receipt"; bump_overall failed
          failing_items+=("$("$JQ" -c --arg cmd "$cmd" --arg out "$out" --arg tier live '. + {command:$cmd, output_tail:$out, tier:$tier}' <<<"$item")")
        fi
        continue
      fi
      local reg_ts; reg_ts="$(now_iso)"
      register_pending "$prd" "$slug" "$ac" "$cmd" "$reg_ts" "$ev1" "$ev2"
      printf 'result: pending (tier=box, registered=%s)\n\n' "$reg_ts" >>"$receipt"
      bump_overall pending
      continue
    fi

    local reach evidence
    case "$kind" in
      endpoint) IFS=$'\t' read -r reach evidence < <(probe_endpoint "$cmd") ;;
      unit) IFS=$'\t' read -r reach evidence < <(probe_unit "${cmd##* }") ;;
      *) reach=unreachable; evidence="unknown kind $kind" ;;
    esac

    {
      printf -- '--- AC%s (%s) ---\n' "$ac" "$kind"
      printf 'command: %s\n' "$cmd"
      printf 'reachability: %s (%s)\n' "$reach" "$evidence"
    } >>"$receipt"

    if [ "$reach" != reachable ]; then
      printf 'result: unreachable\n\n' >>"$receipt"
      continue
    fi

    local out rc
    out="$(eval "$cmd" 2>&1)"; rc=$?
    printf 'exit: %s\n' "$rc" >>"$receipt"
    printf 'output (tail 20 lines):\n%s\n\n' "$(printf '%s' "$out" | tail -n 20)" >>"$receipt"
    if [ "$rc" -eq 0 ]; then
      printf 'result: ok\n\n' >>"$receipt"
      bump_overall ok
    else
      printf 'result: failed\n\n' >>"$receipt"
      bump_overall failed
      failing_items+=("$("$JQ" -c --arg cmd "$cmd" --arg out "$out" '. + {command:$cmd, output_tail:$out}' <<<"$item")")
    fi
  done

  write_frontmatter_keys "$prd" "reality=$overall" "reality_receipt=$receipt"
  if [ "$overall" = pending ]; then
    write_frontmatter_keys "$prd" "reality_pending_since=$(now_iso)"
  fi
  local commit_msg="$slug: reality-check $overall (post-ship)"
  local followup=""
  if [ "$overall" = failed ]; then
    local failing_json; failing_json="[$(IFS=,; echo "${failing_items[*]}")]"
    if followup="$(draft_followup "$prd" "$slug" "$failing_json")"; then
      write_frontmatter_keys "$prd" "reality_followup=$(basename "$followup")"
      journal_line "$(now_iso)  reality  follow-up  drafted  (lane=$(hostname) slug=$slug prd=$(basename "$followup"))"
      commit_msg="$commit_msg; follow-up $(basename "$followup")"
      commit_and_push "$followup" "reality-check: draft $(basename "$followup") (post-ship failure on $slug)" "$no_push"
    else
      log "reality:failed for $slug but follow-up drafting failed lint — see log above"
    fi
  fi
  commit_and_push "$prd" "$commit_msg" "$no_push"

  journal_line "$(now_iso)  reality  $slug  $overall  (lane=$(hostname) receipt=$receipt)"
  printf '[reality-verdict] %s: %s (receipt: %s)\n' "$slug" "$overall" "$receipt" >&2
  exit 0
}

# ---- open: list unresolved reality follow-ups (requirement 8's interim
# status surface — see the `open` doc comment above for why the full
# hawk-probe.sh/rollup/status --json wiring is a separate follow-up). -----
do_open() {
  local prd_dir="$PRD_DIR_DEFAULT" format="text"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prd-dir) prd_dir="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local f parent followup rows=()
  for f in "$prd_dir"/built-prds/PRD-*.md; do
    [ -f "$f" ] || continue
    grep -qE '^- reality: *failed' "$f" || continue
    followup="$(grep -m1 -E '^- reality_followup:' "$f" | sed -E 's/^- reality_followup: *//')"
    [ -n "$followup" ] || continue
    [ -f "$prd_dir/build-queue/$followup" ] || continue
    parent="$(basename "$f")"
    rows+=("$parent:$followup")
  done
  if [ "$format" = json ]; then
    python3 -c '
import json, sys
rows = []
for r in sys.argv[1:]:
    parent, _, followup = r.partition(":")
    rows.append({"parent": parent, "followup": followup})
print(json.dumps({"reality_open": rows}))
' "${rows[@]:-}"
  else
    local r
    for r in "${rows[@]:-}"; do
      [ -n "$r" ] || continue
      printf '%s -> %s\n' "${r%%:*}" "${r#*:}"
    done
  fi
}

# ---- pending-run: execute every registered box-only pending AC against a
# just-booted box (requirement 3/AC10 — "the next box the lane boots for
# ANY reason runs the pending checks first, before its ordinary work"). The
# caller (a lane's own boot sequence) passes the box identity through for
# the receipt only; this command doesn't itself decide reachability — if
# the box just came up, the caller already knows it's up. One receipt per
# consumed registration, written back onto the ORIGINAL PRD's frontmatter
# (tier=box), then the registration file is removed so a second boot
# doesn't re-run the same check. No dedicated box is ever booted for this —
# it only runs opportunistically inside an existing boot.
do_pending_run() {
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      *) target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || die "pending-run requires a target (ip/hostname) argument"
  [ -d "$PENDING_DIR" ] || { log "no pending dir — nothing to run"; exit 0; }
  local f found=false
  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    found=true
    local slug ac cmd prd
    slug="$("$JQ" -r '.slug' "$f")"
    ac="$("$JQ" -r '.ac' "$f")"
    cmd="$("$JQ" -r '.command' "$f")"
    prd="$("$JQ" -r '.prd' "$f")"

    local out rc
    out="$(eval "$cmd" 2>&1)"; rc=$?
    local receipt; mkdir -p "$RECEIPTS_DIR"
    receipt="$RECEIPTS_DIR/$(date -u +%F)-${slug}-ac${ac}-reality-boxrun.txt"
    {
      printf 'pending box-only reality check for %s AC%s\n' "$slug" "$ac"
      printf 'run-at: %s\n' "$(now_iso)"
      printf 'target: %s\n' "$target"
      printf 'command: %s\n' "$cmd"
      printf 'exit: %s\n' "$rc"
      printf 'output (tail 20 lines):\n%s\n' "$(printf '%s' "$out" | tail -n 20)"
    } >"$receipt"
    local verdict; if [ "$rc" -eq 0 ]; then verdict=ok; else verdict=failed; fi

    if [ -f "$prd" ]; then
      write_frontmatter_keys "$prd" "reality=$verdict" "reality_receipt=$receipt"
      commit_and_push "$prd" "$slug: reality-check $verdict (box-only pending run on $target, tier=box)" false
    else
      log "pending-run: parent PRD $prd no longer exists — receipt still recorded at $receipt"
    fi
    journal_line "$(now_iso)  reality  $slug  $verdict  (lane=$(hostname) receipt=$receipt tier=box ac=$ac target=$target)"
    rm -f "$f"
  done
  [ "$found" = true ] || log "no pending box-only checks registered — nothing to run"
  exit 0
}

# ---- alarm-check: exactly one alarm per pending registration once it has
# sat 6h with no boot window (requirement 4/AC11). Idempotent — a fired
# registration is marked alarmed=true so re-running this (meant to be
# invoked periodically, e.g. from the existing quota-watch timer cadence;
# wiring a dedicated timer is left as a follow-up, same interim-surface
# posture as requirement 8's `open`) never re-alarms the same pending
# state. The loop never boots a paid box solely for a reality check — this
# command only ever journals + prints, it never calls burst-lane.sh.
do_alarm_check() {
  [ -d "$PENDING_DIR" ] || exit 0
  local now_epoch; now_epoch="$(date -u +%s)"
  local f
  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    local alarmed reg_ts reg_epoch slug ac age
    alarmed="$("$JQ" -r '.alarmed // false' "$f")"
    [ "$alarmed" = true ] && continue
    reg_ts="$("$JQ" -r '.registered_at' "$f")"
    reg_epoch="$(date -u -d "$reg_ts" +%s 2>/dev/null || echo "$now_epoch")"
    slug="$("$JQ" -r '.slug' "$f")"
    ac="$("$JQ" -r '.ac' "$f")"
    age=$(( now_epoch - reg_epoch ))
    if [ "$age" -ge "${REALITY_CHECK_ALARM_SECONDS:-21600}" ]; then
      journal_line "$(now_iso)  reality  alarm  pending-6h  (lane=$(hostname) slug=$slug ac=$ac age_s=$age file=$f)"
      printf '[reality-alarm] %s AC%s pending %ss with no boot window\n' "$slug" "$ac" "$age" >&2
      local tmp; tmp="$("$JQ" '.alarmed = true' "$f")" && printf '%s\n' "$tmp" >"$f"
    fi
  done
  exit 0
}

case "$cmd" in
  plan)         do_plan "$@" ;;
  run)          do_run "$@" ;;
  open)         do_open "$@" ;;
  pending-run)  do_pending_run "$@" ;;
  alarm-check)  do_alarm_check "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
