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
# Exit: 0 ran (see the printed verdict; a per-AC failure is reflected in
#         `reality: failed`, not a nonzero exit — this command's own job is
#         to RECORD reality, not to gate on it) | 2 usage/resolution error.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
PRD_LINT="$HERE/prd-lint.sh"
JOURNAL_DIR="${BUILD_JOURNAL_DIR:-$HOME/brain/journal/build}"
RECEIPTS_DIR="${BUILD_RECEIPTS_DIR:-$JOURNAL_DIR/receipts}"
JQ="${JQ:-$(command -v jq || echo /usr/bin/jq)}"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c "user.name=Joe Yen")

log() { printf 'reality-check: %s\n' "$*" >&2; }
die() { printf 'reality-check: %s\n' "$*" >&2; exit "${2:-2}"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
  sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
            # `<cmd>` against the live lane").
            plan.append({"ac": n, "kind": "box", "command": literal_cmds[0],
                          "text": text, "reason": None})
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

journal_line() {
  mkdir -p "$JOURNAL_DIR"
  printf '%s\n' "$1" >>"$JOURNAL_DIR/$(date -u +%F).md"
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
    log "no non-manual substrate ACs for $slug — nothing to run"
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

  local overall=unreachable
  local -a failing_items=()
  local i count; count="$("$JQ" 'length' <<<"$plan_json")"
  for ((i=0; i<count; i++)); do
    local item kind cmd ac
    item="$("$JQ" -c ".[$i]" <<<"$plan_json")"
    kind="$("$JQ" -r '.kind' <<<"$item")"
    [ "$kind" = manual ] && continue
    cmd="$("$JQ" -r '.command' <<<"$item")"
    ac="$("$JQ" -r '.ac' <<<"$item")"

    local reach evidence
    case "$kind" in
      box) IFS=$'\t' read -r reach evidence < <(probe_box) ;;
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
      [ "$overall" = unreachable ] && overall=ok
    else
      printf 'result: failed\n\n' >>"$receipt"
      overall=failed
      failing_items+=("$("$JQ" -c --arg cmd "$cmd" --arg out "$out" '. + {command:$cmd, output_tail:$out}' <<<"$item")")
    fi
  done

  write_frontmatter_keys "$prd" "reality=$overall" "reality_receipt=$receipt"
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

case "$cmd" in
  plan) do_plan "$@" ;;
  run)  do_run "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
