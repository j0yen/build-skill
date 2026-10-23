#!/usr/bin/env bash
# dream-persist.sh — /dream hook `dream.persist` (Phase 4, per batch of <= 4 PRDs):
# lint, refresh MANIFEST.md, commit ONLY this batch, push, and report whether the
# daemon would admit each PRD. WRITES: the PRDs repo's MANIFEST.md, one commit,
# one push, and touches ~/.claude/.dream-active.
#
# Usage:
#   dream-persist.sh [--review <file>] <PRD file>...   (1..4 files, all inside one PRDs git clone)
#   dream-persist.sh --review-status     (one line from the review log, last 24 h)
#   dream-persist.sh --selftest          (throwaway git repos; no network)
#
# Steps, in order (each failure stops the run before anything is committed):
#   1. refuse > 4 PRDs (exit 2); refuse when the repo is a daemon's PRD clone: its
#      toplevel equals `prd_dir` in ~/.config/wm-build/config.toml on this host, or
#      it holds a `.wm-build-daemon` marker (exit 2). Never persist in a daemon clone.
#   2. touch ~/.claude/.dream-active (the dream-write gate reads it)
#   3. scripts/dream-lint.sh <files>           (any FAIL: stop, exit 1). Its stdout is
#      captured to a temp file and replayed unchanged, so the review guard below can
#      read it; then the REVIEW GUARD (below) runs before anything is pulled or committed
#   4. `git pull --rebase --autostash` (when origin exists), so the manifest is
#      computed on the latest tip and cannot conflict; then the hooksPath self-heal
#      (below)
#      then the review iter_log normalisation: a `Fable FIX applied before persist` iter_log line
#      is rewritten to `amended by /dream (review) — Fable FIX applied before persist: …` so
#      dream-amend.sh does not read it as a dispatch line (see review_iterlog_normalize)
#   5. MANIFEST.md: upsert one line per given PRD (`- PRD-x.md — status · target ·
#      Drafted`), replacing an existing line or inserting in filename order, plus the
#      header timestamp. There is no manifest generator script in this repo
#      (manifest-set.sh writes state/manifest.json, not MANIFEST.md), so this is the
#      minimal edit, never a full regeneration; keys parse as `- Key: v`, bare
#      `Key: v` or `**Key:** v`.
#   6. diff guard: `git diff --numstat MANIFEST.md` added+deleted lines must be
#      <= 3 x PRDs + 5, else the manifest is restored and the run stops (exit 1)
#   7. stage ONLY the given files + MANIFEST.md, commit `dream: <N> PRDs (<slugs>)`
#      (pathspec commit: anything else staged is left out), push (when origin exists)
#   8. per slug, `wm-build explain <slug>` (local when wm-build + config exist, else
#      `ssh redbaron` with the PATH export; wm-build scan is NOT run here) and print
#      `<slug>: eligible | ineligible — <check>: <detail> | pending scan`
# Exit: 0 persisted, all eligible or pending scan | 3 persisted, >= 1 ineligible
#       | 2 refused (count / daemon clone / enforced review guard)
#       | 1 lint FAIL, guard, git or usage error
#
# REVIEW GUARD (`--review <file>`): the file holds one line per PRD,
# `<slug> APPROVE|FIX|REJECT <reviewer>` (slug = PRD filename minus `PRD-` and `.md`;
# `#` comments and blank lines ignored; a malformed line = `review-malformed <lineno>`).
# A slug may carry several lines (a FIX round, then the re-review): the LAST verdict line
# for a slug in the file is its verdict (`x FIX r1` then `x APPROVE r2` = approved; the
# reverse = review-not-approved).
# Conditions, evaluated from the lint output + frontmatter after lint and before the pull:
#   review-missing                no --review given
#   review-not-approved <slug>    a batch PRD has no line, or its verdict is not APPROVE
#   review-unknown-slug <slug>    a line names a slug that is not in the batch
#   review-solo-required <slug>   batch > 1 and the PRD is solo-required: frontmatter
#                                 `Grounding: creative`, lint reported `ac-names-foreign-surface`
#                                 for it, or it carries `foreign_surface_ok`.
#                                 `cross-repo-path-in-ac` ALONE is not solo-required: it only
#                                 prints an informational `NOTE review-cross-repo-path <slug>`.
# Mode: REVIEW_MODE=warn|enforce (constant below; env DREAM_PERSIST_REVIEW_MODE overrides).
#   warn    each condition prints `WARN <id> ...` to STDERR and the run continues. STDOUT
#           content and exit codes (0/3/2/1) are byte-identical to the pre-review script
#           for an existing caller (callers parse stdout for the per-slug explain lines).
#   enforce each condition prints `FAIL <id> ...` to STDERR and the run exits 2 before
#           anything is pulled or committed.
# REVIEW LOG: one JSON line per PRD appended to ${DREAM_REVIEW_LOG:-~/.local/state/dream/review-log.jsonl}
# once per run, with the final outcome (pushed | refused | failed); an EXIT trap writes it
# even when the run dies. Fields: ts host slug verdict reviewer mode batch_size outcome commit
# warnings. Outcome refused = a deliberate stop (count, daemon clone, lint FAIL, enforced review
# guard); failed = a git/manifest/guard error; pushed = committed and pushed (or committed with
# no origin remote). `--review-status` reads it, over the last 24 h by ts: persists_24h = rows with
# outcome pushed, with_review = of those, rows that had a review line, review_missing = pushed rows
# with no review line, refused = rows with outcome refused.
#
# HOOKSPATH SELF-HEAL (after the pull, before the commit): the PRDs repo's
# `.githooks/pre-commit` (prd-lint on added+modified queue PRDs) only runs when
# core.hooksPath points at it. See PREMISE / EXPIRES below.
#
# Env (selftest seams): DREAM_PERSIST_LINT, DREAM_ACTIVE_FILE, WM_BUILD_CONFIG,
#   DREAM_PERSIST_WM_BUILD (command for explain, default wm-build), DREAM_PERSIST_SSH,
#   DREAM_PERSIST_NO_PULL=1, DREAM_REVIEW_LOG, DREAM_PERSIST_REVIEW_MODE,
#   DREAM_PERSIST_TODAY (YYYY-MM-DD; overrides today's date for the EXPIRES test).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${DREAM_PERSIST_LINT:-$HERE/dream-lint.sh}"
ACTIVE="${DREAM_ACTIVE_FILE:-$HOME/.claude/.dream-active}"
CONFIG="${WM_BUILD_CONFIG:-$HOME/.config/wm-build/config.toml}"
WB="${DREAM_PERSIST_WM_BUILD:-wm-build}"
SSH="${DREAM_PERSIST_SSH:-ssh -o ConnectTimeout=8}"
PATHX='export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH;'

# Review guard mode (warn first; flip to enforce once `--review-status` shows callers pass --review).
REVIEW_MODE=warn
REVIEW_LOG="${DREAM_REVIEW_LOG:-$HOME/.local/state/dream/review-log.jsonl}"
# hooksPath self-heal guard: premise + expiry (after EXPIRES it prints one line and does nothing).
PREMISE="seat PRD clones lacked core.hooksPath (found 2026-10-22)"
EXPIRES=2026-11-22

die() { echo "dream-persist: $*" >&2; }

# manifest_upsert <manifest> <repo-relative PRD path>... (cwd = repo toplevel)
manifest_upsert() {
  python3 - "$@" <<'PY'
import datetime, os, re, sys, tempfile
manifest, files = sys.argv[1], sys.argv[2:]

def head(path):
    kv, fence = {}, False
    for ln in open(path, encoding="utf-8", errors="replace").read().splitlines()[:80]:
        if ln.strip().startswith("```"):
            fence = not fence; continue
        if fence: continue
        k = re.sub(r"^[-*+]\s+", "", ln)
        k = re.sub(r"^\*\*([A-Za-z_ -]+):\*\*", r"\1:", k)
        m = re.match(r"^([A-Za-z_][A-Za-z_ -]*):\s*(.*)$", k)
        if m and m.group(1).strip().lower() not in kv:
            kv[m.group(1).strip().lower()] = m.group(2).strip()
    return kv

lines = open(manifest, encoding="utf-8").read().split("\n") if os.path.exists(manifest) else []
trail = bool(lines) and lines[-1] == ""
if trail:
    lines.pop()
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
header = f"# MANIFEST — derived index (regenerated {ts} by dream-persist.sh)"
if lines and lines[0].startswith("# MANIFEST"):
    lines[0] = header
else:
    lines.insert(0, header)

def fname(l):
    m = re.match(r"^- (PRD-\S+?\.md)\s", l)
    return m.group(1) if m else None

for f in files:
    kv = head(f)
    st = (kv.get("status", "").split() or [""])[0].lower()
    bt = (kv.get("build_target", "").split() or [""])[0]
    dm = re.search(r"\d{4}-\d{2}-\d{2}", kv.get("drafted", ""))
    name = os.path.basename(f)
    entry = f"- {name} — {st} · {bt} · {dm.group(0) if dm else ''}".rstrip()
    idx = next((i for i, l in enumerate(lines) if fname(l) == name), None)
    if idx is not None:
        lines[idx] = entry
        continue
    pos = len(lines)
    for i, l in enumerate(lines[1:], 1):
        n = fname(l)
        if n is not None and n > name:
            pos = i; break
    lines.insert(pos, entry)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(manifest)) or ".", prefix=".MANIFEST.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(tmp, manifest)
PY
}

# review_mode -> warn|enforce (env override of REVIEW_MODE; anything else falls back to warn)
review_mode() {
  local m="${DREAM_PERSIST_REVIEW_MODE:-$REVIEW_MODE}"
  case "$m" in warn|enforce) echo "$m" ;; *) echo "dream-persist: unknown review mode '$m', using warn" >&2; echo warn ;; esac
}

# review_eval <review file or ""> <lint stdout file> <batch size> <abs PRD path>...
# Prints tab-separated protocol lines: W <slug or -> <text> (a warning), N <text> (a note),
# V <slug> <verdict or -> <reviewer or -> (the review line per PRD).
review_eval() {
  python3 - "$@" <<'PY'
import os, re, sys
review, lintout, batch = sys.argv[1], sys.argv[2], int(sys.argv[3])
files = sys.argv[4:]
slug_of = lambda f: re.sub(r"\.md$", "", re.sub(r"^PRD-", "", os.path.basename(f)))
slugs = [slug_of(f) for f in files]

# which lint ids the lint run reported per PRD (dream-lint prints `== <file>` before each file's findings)
seen = {s: [] for s in slugs}
cur = None
for ln in open(lintout, encoding="utf-8", errors="replace").read().splitlines():
    m = re.match(r"^== (.*)$", ln)
    if m:
        cur = slug_of(m.group(1)); continue
    if cur in seen:
        m = re.match(r"^\s*\d+\.\s+(?:WARN|FAIL)\s+(ac-names-foreign-surface|cross-repo-path-in-ac):", ln)
        if m: seen[cur].append(m.group(1))

def head(path):
    kv, fence = {}, False
    for ln in open(path, encoding="utf-8", errors="replace").read().splitlines()[:80]:
        if ln.strip().startswith("```"):
            fence = not fence; continue
        if fence: continue
        k = re.sub(r"^[-*+]\s+", "", ln)
        k = re.sub(r"^\s*\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
        m = re.match(r"^\s*([A-Za-z][A-Za-z _-]*)\s*:\s*(.*)$", k)
        if m:
            kv.setdefault(m.group(1).strip().lower().replace(" ", "_"), m.group(2).strip())
    return kv

W, N, verdicts = [], [], {}   # W: (slug or "-", text)
if not review:
    W.append(("-", "review-missing (no --review file given)"))
else:
    try:
        rl = open(review, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        rl = None
        W.append(("-", f"review-missing (cannot read {review})"))
    if rl is not None:
        rows = {}
        for i, ln in enumerate(rl, 1):
            t = ln.strip()
            if not t or t.startswith("#"): continue
            p = t.split()
            if len(p) < 3 or p[1] not in ("APPROVE", "FIX", "REJECT"):
                W.append(("-", f"review-malformed {i}")); continue
            rows.setdefault(p[0], []).append((p[1], " ".join(p[2:])))
        for s in slugs:
            if s in rows:
                verdicts[s] = rows[s][-1]   # the LAST verdict line for a slug is the verdict
        for s in slugs:
            if s not in verdicts or verdicts[s][0] != "APPROVE":
                got = verdicts[s][0] if s in verdicts else "no line"
                W.append((s, f"review-not-approved {s} ({got})"))
        for s in rows:
            if s not in slugs:
                W.append(("-", f"review-unknown-slug {s}"))
for f, s in zip(files, slugs):
    kv = head(f)
    why = []
    if kv.get("grounding", "").lower().startswith("creative"): why.append("Grounding: creative")
    if "ac-names-foreign-surface" in seen[s]: why.append("lint ac-names-foreign-surface")
    if "foreign_surface_ok" in kv: why.append("foreign_surface_ok")
    if batch > 1 and why:
        W.append((s, f"review-solo-required {s} ({', '.join(why)}; persist it as a batch of one)"))
    if "cross-repo-path-in-ac" in seen[s]:
        N.append(f"review-cross-repo-path {s}")
for sl, t in W: print(f"W\t{sl}\t{t}")
for t in N: print(f"N\t{t}")
for s in slugs:
    v = verdicts.get(s)
    print(f"V\t{s}\t{v[0] if v else '-'}\t{v[1] if v else '-'}")
PY
}

# review_log_write -- appends one JSON line per slug, once per run, with the final outcome
RV_LOGGED=0; RV_OUTCOME=failed; RV_SHA=""; RV_MODE=warn; RV_BATCH=0
declare -a RV_SLUGS=() RV_BW=()
declare -A RV_VERDICT=() RV_REVIEWER=() RV_SW=()
review_log_write() {
  [ "$RV_LOGGED" -eq 0 ] && [ "${#RV_SLUGS[@]}" -gt 0 ] || return 0
  RV_LOGGED=1
  local s w
  mkdir -p "$(dirname "$REVIEW_LOG")" 2>/dev/null || return 0
  for s in "${RV_SLUGS[@]}"; do
    w="$( { [ "${#RV_BW[@]}" -gt 0 ] && printf '%s\n' "${RV_BW[@]}"; printf '%s\n' "${RV_SW[$s]:-}"; } | sed '/^$/d')"
    python3 - "$s" "${RV_VERDICT[$s]:--}" "${RV_REVIEWER[$s]:--}" "$RV_MODE" "$RV_BATCH" "$RV_OUTCOME" "$RV_SHA" "$w" >> "$REVIEW_LOG" 2>/dev/null <<'PY' || true
import datetime, json, socket, sys
slug, verdict, reviewer, mode, batch, outcome, sha, warns = sys.argv[1:9]
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname(), "slug": slug,
    "verdict": None if verdict == "-" else verdict, "reviewer": None if reviewer == "-" else reviewer,
    "mode": mode, "batch_size": int(batch), "outcome": outcome, "commit": sha or None,
    "warnings": [w for w in warns.split("\n") if w],
}))
PY
  done
}

# review_iterlog_normalize <repo top> <rel PRD>... -- the /dream reviewer step leaves a free-form
# `iter_log: <ts> Fable FIX applied before persist ...` line in a PRD it fixed. dream-amend.sh and the
# daemon read an iter_log line that is not an `amended by /dream (...)` line as a daemon dispatch line,
# so that form made every reviewed PRD un-amendable from birth. Rewrite only the prefix, in the
# gate-allowed form, keeping the detail: `<ts> amended by /dream (review) — Fable FIX applied before
# persist: <detail>`. Idempotent (the new form starts with `amended`); stderr NOTE only, stdout unchanged.
review_iterlog_normalize() {
  local top="$1" rel; shift
  for rel in "$@"; do
    if grep -qE '^([-*+][[:space:]]+)?iter_log:[[:space:]]+[^[:space:]]+[[:space:]]+Fable FIX applied before persist' "$top/$rel" 2>/dev/null; then
      sed -i -E 's/^(([-*+][[:space:]]+)?iter_log:[[:space:]]+[^[:space:]]+[[:space:]]+)Fable FIX applied before persist:?/\1amended by \/dream (review) — Fable FIX applied before persist:/' "$top/$rel"
      echo "NOTE review-iterlog-normalized ${rel##*/}" >&2
    fi
  done
}

# review_status -> `persists_24h=N with_review=N review_missing=N refused=N` (last 24 h of the log)
review_status() {
  python3 - "$REVIEW_LOG" <<'PY'
import datetime, json, os, sys
now = datetime.datetime.now(datetime.timezone.utc)
c = dict(persists_24h=0, with_review=0, review_missing=0, refused=0)
if os.path.exists(sys.argv[1]):
    for ln in open(sys.argv[1], encoding="utf-8", errors="replace"):
        try:
            r = json.loads(ln)
            ts = datetime.datetime.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        except (ValueError, KeyError, TypeError):
            continue
        if (now - ts).total_seconds() > 86400: continue
        if r.get("outcome") == "pushed":
            c["persists_24h"] += 1
            c["with_review" if r.get("verdict") else "review_missing"] += 1
        elif r.get("outcome") == "refused":
            c["refused"] += 1
print(" ".join(f"{k}={v}" for k, v in c.items()))
PY
}

# hooks_selfheal (cwd = repo toplevel) -- the PRDs repo's .githooks/pre-commit only runs when
# core.hooksPath names it, and seat clones lacked it (PREMISE). Messages go to STDERR so
# stdout stays what callers parse. `git config --local` edits .git/config only: dirty or
# staged files in the work tree do not matter to it. Touches no other config.
hooks_selfheal() {
  local today="${DREAM_PERSIST_TODAY:-$(date +%F)}" cur rc top
  if [[ "$today" > "$EXPIRES" ]]; then echo "hooksPath: guard expired (EXPIRES=$EXPIRES)" >&2; return 0; fi
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  top="$(git rev-parse --show-toplevel)"
  [ -f "$top/.githooks/pre-commit" ] || return 0
  cur="$(git config --local --get core.hooksPath 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$cur" = ".githooks" ]; then return 0; fi
  if [ ! -x "$top/.githooks/pre-commit" ]; then echo "hooksPath: skipped (.githooks/pre-commit not executable)" >&2; return 0; fi
  if [ "$rc" -eq 0 ]; then echo "hooksPath: skipped (set to $cur)" >&2; return 0; fi
  if git config --local core.hooksPath .githooks; then echo "hooksPath: enabled .githooks in $top" >&2; fi
  return 0
}

# explain_one <slug> -> prints the verdict line; returns 3 when ineligible
explain_one() {
  local slug="$1" out
  if command -v "${WB%% *}" >/dev/null 2>&1 && [ -f "$CONFIG" ]; then
    out="$($WB explain "$slug" 2>&1)"
  else
    out="$($SSH redbaron "$PATHX wm-build explain $slug" 2>&1)"
  fi
  python3 - "$slug" "$out" <<'PY'
import json, sys
slug, out = sys.argv[1], sys.argv[2]
if "no PRD found" in out:
    print(f"{slug}: pending scan (explain: no PRD found yet; the daemon scans on its next tick)"); sys.exit(0)
i = out.find("{")
try:
    d, _ = json.JSONDecoder().raw_decode(out[i:]) if i >= 0 else (None, 0)
except ValueError:
    d = None
if not isinstance(d, dict) or "eligible" not in d:
    print(f"{slug}: pending scan (explain gave no verdict: {out.strip().splitlines()[0][:120] if out.strip() else 'empty'})"); sys.exit(0)
if d["eligible"]:
    print(f"{slug}: eligible"); sys.exit(0)
bad = [c for c in d.get("checks", []) if not c.get("passed")]
why = "; ".join(f"{c.get('name')}: {c.get('detail')}" for c in bad) or "unknown"
print(f"{slug}: ineligible — {why}"); sys.exit(3)
PY
}

# run_main: parse --review, run the persist, and write the review log with the final outcome
run_main() {
  local review="" rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --review) [ "$#" -ge 2 ] || { die "--review needs a file"; return 1; }; review="$2"; shift 2 ;;
      --review=*) review="${1#--review=}"; shift ;;
      *) break ;;
    esac
  done
  RV_LOGGED=0; RV_OUTCOME=failed; RV_SHA=""; RV_SLUGS=(); RV_BW=(); RV_VERDICT=(); RV_REVIEWER=(); RV_SW=()
  RV_MODE="$(review_mode)"
  persist_batch "$review" "$@"; rc=$?
  review_log_write
  return $rc
}

persist_batch() {
  local review="$1"; shift
  [ "$#" -ge 1 ] || { die "usage: dream-persist.sh [--review <file>] <PRD file>... (<= 4)"; return 1; }
  if [ "$#" -gt 4 ]; then die "refusing $# PRDs: a batch is at most 4"; return 2; fi
  local f first_dir top ftop
  first_dir="$(dirname "$1")"
  top="$(git -C "$first_dir" rev-parse --show-toplevel 2>/dev/null)" || { die "$1 is not inside a git repo"; return 1; }
  top="$(cd "$top" && pwd -P)"
  local rels=() slugs=()
  for f in "$@"; do
    [ -f "$f" ] || { die "no such file: $f"; return 1; }
    ftop="$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null)"
    [ "$(cd "$ftop" && pwd -P)" = "$top" ] || { die "$f is in a different repo than $1"; return 1; }
    local abs; abs="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
    rels+=("${abs#"$top"/}")
    local b; b="$(basename "$f")"; b="${b#PRD-}"; slugs+=("${b%.md}")
  done
  RV_SLUGS=("${slugs[@]}"); RV_BATCH=${#slugs[@]}; RV_OUTCOME=refused

  # 1. never persist in a daemon's PRD clone
  local pd=""
  [ -f "$CONFIG" ] && pd="$(sed -nE 's/^[[:space:]]*prd_dir[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$CONFIG" | head -1)"
  if [ -n "$pd" ] && [ -d "$pd" ] && [ "$(cd "$pd" && pwd -P)" = "$top" ]; then
    die "refusing: $top is this host's daemon PRD clone (prd_dir in $CONFIG). Persist from your own clone"; return 2
  fi
  if [ -e "$top/.wm-build-daemon" ]; then
    die "refusing: $top carries a .wm-build-daemon marker (a daemon's PRD clone). Persist from your own clone"; return 2
  fi

  # 2. dream-write gate flag
  mkdir -p "$(dirname "$ACTIVE")" 2>/dev/null; touch "$ACTIVE" 2>/dev/null || true

  # 3. lint (stdout captured, then replayed unchanged; stderr stays inherited)
  local lintout lrc; lintout="$(mktemp)"
  "$LINT" "${rels[@]/#/$top/}" > "$lintout"; lrc=$?
  cat "$lintout"
  if [ "$lrc" -ne 0 ]; then rm -f "$lintout"; die "dream-lint reported a FAIL: nothing committed"; return 1; fi

  # 3b. review guard: warn (stderr, continue) or enforce (stderr FAIL, exit 2 before pull/commit)
  local kind tag a b2 c line nwarn=0
  local -a rwarns=()
  while IFS=$'\t' read -r kind a b2 c; do
    case "$kind" in
      W) rwarns+=("$b2"); nwarn=$((nwarn+1))
         if [ "$a" = "-" ]; then RV_BW+=("$b2"); else RV_SW[$a]="${RV_SW[$a]:+${RV_SW[$a]}$'\n'}$b2"; fi ;;
      N) echo "NOTE $a" >&2 ;;
      V) RV_VERDICT[$a]="$b2"; RV_REVIEWER[$a]="$c" ;;
    esac
  done < <(review_eval "$review" "$lintout" "${#rels[@]}" "${rels[@]/#/$top/}")
  rm -f "$lintout"
  if [ "$RV_MODE" = "enforce" ]; then tag=FAIL; else tag=WARN; fi
  for line in "${rwarns[@]}"; do echo "$tag $line" >&2; done
  if [ "$RV_MODE" = "enforce" ] && [ "$nwarn" -gt 0 ]; then
    die "review guard (enforce): $nwarn condition(s): nothing pulled or committed"; return 2
  fi
  RV_OUTCOME=failed

  cd "$top" || return 1
  local has_origin=0
  git remote get-url origin >/dev/null 2>&1 && has_origin=1

  # 4. latest tip first (autostash: the drafted files and a dirty manifest ride along)
  if [ "$has_origin" -eq 1 ] && [ -z "${DREAM_PERSIST_NO_PULL:-}" ]; then
    git pull --rebase --autostash -q || { die "git pull --rebase failed: nothing committed"; return 1; }
  fi
  hooks_selfheal
  review_iterlog_normalize "$top" "${rels[@]}"

  # 5. manifest upsert, 6. diff guard
  local saved; saved="$(mktemp)"
  [ -f MANIFEST.md ] && cp -p MANIFEST.md "$saved" || : > "$saved"
  local had_manifest=0; [ -f MANIFEST.md ] && had_manifest=1
  manifest_upsert MANIFEST.md "${rels[@]}" || { die "manifest upsert failed"; cp -p "$saved" MANIFEST.md; rm -f "$saved"; return 1; }
  local added deleted limit=$((3 * ${#rels[@]} + 5))
  read -r added deleted _ < <(git diff --numstat -- MANIFEST.md)
  if [ "$had_manifest" -eq 0 ]; then added=$(wc -l < MANIFEST.md); deleted=0; fi
  added="${added:-0}"; deleted="${deleted:-0}"
  [ "$added" = "-" ] && added=0; [ "$deleted" = "-" ] && deleted=0
  if [ $((added + deleted)) -gt "$limit" ]; then
    cp -p "$saved" MANIFEST.md; rm -f "$saved"
    die "diff guard: MANIFEST.md would change $((added + deleted)) lines (> $limit = 3 x ${#rels[@]} PRDs + 5): restored, nothing committed"
    return 1
  fi
  rm -f "$saved"
  echo "manifest: +$added/-$deleted lines (limit $limit)"

  # 7. stage ONLY this batch, commit, push
  git add -- "${rels[@]}" MANIFEST.md || { die "git add failed"; return 1; }
  local msg; msg="dream: ${#rels[@]} PRDs ($(IFS=,; echo "${slugs[*]}"))"
  git commit -q -m "$msg" -- "${rels[@]}" MANIFEST.md || { die "git commit failed"; return 1; }
  echo "committed: $(git rev-parse --short HEAD) $msg"
  RV_SHA="$(git rev-parse --short HEAD)"
  if [ "$has_origin" -eq 1 ]; then
    git push -q origin HEAD || { die "git push failed (committed locally as $(git rev-parse --short HEAD))"; return 1; }
    echo "pushed: origin"
  else
    echo "pushed: no origin remote, commit stays local"
  fi
  RV_OUTCOME=pushed

  # 8. admission check per slug
  local s rc=0 line
  for s in "${slugs[@]}"; do
    line="$(explain_one "$s")"; [ $? -eq 3 ] && rc=3
    echo "$line"
  done
  return $rc
}

selftest() {
  local t fails=0 total=0 out rc
  t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q --bare -b main "$t/origin.git"
  git clone -q "$t/origin.git" "$t/seed" 2>/dev/null
  ( cd "$t/seed" && git checkout -q -b main 2>/dev/null; mkdir -p build-queue
    printf '# MANIFEST — derived index (regenerated old\n- PRD-aaa.md — queued · shell · 2026-10-01\n- PRD-ccc.md — queued · shell · 2026-10-01\n' > MANIFEST.md
    echo keep > unrelated.txt; touch build-queue/.gitkeep
    git add -A && git commit -q -m init && git push -q origin main ) >/dev/null 2>&1
  mkprd() { printf '# PRD — %s\n\n- Status: queued\n- build_target: shell\nDrafted: 2026-10-22\n\n## Acceptance criteria\n\n1. P0 — x.\n' "$2" > "$1"; }
  fresh() { rm -rf "$t/w"; git clone -q "$t/origin.git" "$t/w" 2>/dev/null; }
  printf '#!/usr/bin/env bash\ncase "$*" in *FAILME*) echo "FAIL lint"; exit 1 ;; *) echo OK; exit 0 ;; esac\n' > "$t/lint"
  printf '#!/usr/bin/env bash\ncase "$2" in\n ok-*) printf "{\\n \\"slug\\": \\"%%s\\",\\n \\"eligible\\": true,\\n \\"checks\\": []\\n}\\nlast-signature: none\\n" "$2" ;;\n bad-*) printf "{\\n \\"eligible\\": false,\\n \\"checks\\": [{\\"name\\":\\"claim\\",\\"passed\\":false,\\"detail\\":\\"claimed-by:x\\"}]\\n}\\n" ;;\n *) echo "wm-build: no PRD found for slug \\"$2\\"" ;;\nesac\n' > "$t/wb"
  chmod +x "$t/lint" "$t/wb"
  export DREAM_PERSIST_LINT="$t/lint" DREAM_ACTIVE_FILE="$t/active"
  # CONFIG exists (a real local daemon config) so explain runs the fake wm-build, never ssh
  printf 'prd_dir = "%s/not-this-clone"\n' "$t" > "$t/cfg-ok.toml"
  DREAM_PERSIST_WM_BUILD="$t/wb"; WB="$t/wb"; LINT="$t/lint"; ACTIVE="$t/active"; CONFIG="$t/cfg-ok.toml"
  ck() { # $1=label $2=want-rc $3=pattern(s, newline sep) ; rest=args
    local label="$1" want="$2" pats="$3"; shift 3
    total=$((total+1)); out="$(run_main "$@" 2>&1)"; rc=$?
    local bad=""; [ "$rc" -eq "$want" ] || bad="exit=$rc want $want"
    while IFS= read -r p; do [ -z "$p" ] && continue; grep -q -- "$p" <<<"$out" || bad="$bad; missing /$p/"; done <<<"$pats"
    if [ -z "$bad" ]; then echo "ok: $label"; else echo "FAIL: $label: $bad :: $out"; fails=$((fails+1)); fi
  }
  # happy path: pull --rebase onto a newer origin tip, manifest upsert, only the batch committed, push, 3 explain verdicts
  fresh
  ( git clone -q "$t/origin.git" "$t/other" 2>/dev/null && cd "$t/other" && echo n > newer.txt && git add -A && git commit -q -m newer && git push -q origin main ) >/dev/null 2>&1
  mkprd "$t/w/build-queue/PRD-ok-one.md" one; mkprd "$t/w/build-queue/PRD-bad-two.md" two; mkprd "$t/w/build-queue/PRD-new-three.md" three
  echo dirty >> "$t/w/unrelated.txt"
  ck "persist 3 PRDs: committed + pushed, eligible/ineligible/pending reported, exit 3" 3 \
"^committed: .* dream: 3 PRDs (ok-one,bad-two,new-three)
^pushed: origin
^ok-one: eligible
^bad-two: ineligible — claim: claimed-by:x
^new-three: pending scan" "$t/w/build-queue/PRD-ok-one.md" "$t/w/build-queue/PRD-bad-two.md" "$t/w/build-queue/PRD-new-three.md"
  total=$((total+1))
  if [ -f "$t/active" ]; then echo "ok: ~/.claude/.dream-active touched"; else echo "FAIL: .dream-active not touched"; fails=$((fails+1)); fi
  total=$((total+1))
  local files; files="$(git -C "$t/w" show --name-only --format= HEAD | LC_ALL=C sort | tr '\n' ' ')"
  if [ "$files" = "MANIFEST.md build-queue/PRD-bad-two.md build-queue/PRD-new-three.md build-queue/PRD-ok-one.md " ]; then echo "ok: commit holds ONLY the 3 PRDs + MANIFEST.md (dirty unrelated.txt left out)"; else echo "FAIL: commit files: $files"; fails=$((fails+1)); fi
  total=$((total+1))
  if git -C "$t/origin.git" show main:MANIFEST.md | grep -q '^- PRD-ok-one.md — queued · shell · 2026-10-22$' \
     && git -C "$t/origin.git" show main:MANIFEST.md | awk '/^- PRD-/{print $2}' | sort -c 2>/dev/null; then
    echo "ok: origin has the upserted manifest lines in filename order"
  else echo "FAIL: origin MANIFEST.md: $(git -C "$t/origin.git" show main:MANIFEST.md)"; fails=$((fails+1)); fi
  total=$((total+1))
  if [ "$(git -C "$t/origin.git" log --format=%s -1 main)" = "dream: 3 PRDs (ok-one,bad-two,new-three)" ] && [ -n "$(git -C "$t/w" status --porcelain | grep unrelated)" ]; then
    echo "ok: pushed, and the unrelated dirty file stayed dirty after the autostash"
  else echo "FAIL: push/autostash state: $(git -C "$t/w" status --porcelain)"; fails=$((fails+1)); fi
  # existing line replaced, not duplicated
  fresh; mkprd "$t/w/build-queue/PRD-aaa.md" aaa
  ck "existing manifest line is replaced in place" 0 "^manifest: " "$t/w/build-queue/PRD-aaa.md"
  total=$((total+1))
  [ "$(git -C "$t/w" show HEAD:MANIFEST.md | grep -c '^- PRD-aaa.md')" = "1" ] && echo "ok: no duplicate manifest line" || { echo "FAIL: duplicate PRD-aaa line"; fails=$((fails+1)); }
  # > 4 PRDs
  fresh; for i in 1 2 3 4 5; do mkprd "$t/w/build-queue/PRD-n$i.md" n$i; done
  ck "> 4 PRDs refused" 2 "at most 4" "$t"/w/build-queue/PRD-n[1-5].md
  # daemon clone: marker, and prd_dir match
  fresh; mkprd "$t/w/build-queue/PRD-d1.md" d1; touch "$t/w/.wm-build-daemon"
  ck "daemon clone (.wm-build-daemon marker) refused" 2 "wm-build-daemon marker" "$t/w/build-queue/PRD-d1.md"
  rm -f "$t/w/.wm-build-daemon"; printf 'prd_dir = "%s"\n' "$t/w" > "$t/cfg.toml"; CONFIG="$t/cfg.toml"
  ck "daemon clone (prd_dir match) refused" 2 "daemon PRD clone" "$t/w/build-queue/PRD-d1.md"
  CONFIG="$t/cfg-ok.toml"
  total=$((total+1)); if [ -z "$(git -C "$t/w" log --format=%s origin/main..HEAD)" ]; then echo "ok: refusals committed nothing"; else echo "FAIL: refusal committed"; fails=$((fails+1)); fi
  # lint FAIL
  fresh; mkprd "$t/w/build-queue/PRD-FAILME.md" f
  ck "lint FAIL -> nothing committed" 1 "dream-lint reported a FAIL" "$t/w/build-queue/PRD-FAILME.md"
  total=$((total+1)); if [ -z "$(git -C "$t/w" log --format=%s origin/main..HEAD)" ]; then echo "ok: lint FAIL committed nothing"; else echo "FAIL: lint FAIL committed"; fails=$((fails+1)); fi
  # diff guard: a pre-existing 40-line manifest drift trips 3N+5
  fresh; mkprd "$t/w/build-queue/PRD-g1.md" g1
  for i in $(seq 1 40); do echo "- PRD-zz$i.md — queued · shell · 2026-10-01" >> "$t/w/MANIFEST.md"; done
  cp "$t/w/MANIFEST.md" "$t/drift.md"
  ck "diff guard trips on > 3N+5 changed lines" 1 "diff guard" "$t/w/build-queue/PRD-g1.md"
  total=$((total+1)); if cmp -s "$t/w/MANIFEST.md" "$t/drift.md" && [ -z "$(git -C "$t/w" log --format=%s origin/main..HEAD)" ]; then echo "ok: guard restored the manifest and committed nothing"; else echo "FAIL: guard left state changed"; fails=$((fails+1)); fi
  # ---- review guard, review log, hooksPath self-heal ----
  REVIEW_LOG="$t/review-log.jsonl"; : > "$REVIEW_LOG"
  mkprdx() { # <file> <slug> <extra header line or ""> : a PRD with optional extra frontmatter
    printf '# PRD — %s\n\n- Status: queued\n- build_target: shell\nDrafted: 2026-10-22\n%s\n\n## Acceptance criteria\n\n1. P0 — x.\n' "$2" "$3" > "$1"
  }
  lastlog() { tail -n 1 "$REVIEW_LOG"; }
  # stdout-only and stderr-only capture of one run
  runsplit() { RS_OUT="$(run_main "$@" 2>"$t/rs.err")"; RS_RC=$?; RS_ERR="$(cat "$t/rs.err")"; }
  chk() { # <label> <ok-condition-result 0/1> <detail>
    total=$((total+1)); if [ "$2" -eq 0 ]; then echo "ok: $1"; else echo "FAIL: $1 :: $3"; fails=$((fails+1)); fi
  }
  unset DREAM_PERSIST_REVIEW_MODE
  ORIGIN0="$(git -C "$t/origin.git" rev-parse main)"
  rewind() { git -C "$t/origin.git" update-ref refs/heads/main "$ORIGIN0"; }
  # warn, no --review: WARN on stderr, commits, stdout identical to a reviewed run, exit unchanged
  rewind; fresh; mkprd "$t/w/build-queue/PRD-ok-r1.md" r1; mkprd "$t/w/build-queue/PRD-r2.md" r2
  runsplit "$t/w/build-queue/PRD-ok-r1.md" "$t/w/build-queue/PRD-r2.md"
  local out_noreview="$RS_OUT" rc_noreview=$RS_RC
  chk "warn/no --review: WARN review-missing on stderr, nothing on stdout" \
    "$(grep -q '^WARN review-missing' <<<"$RS_ERR" && ! grep -qi 'review\|WARN' <<<"$RS_OUT"; echo $?)" "err=$RS_ERR out=$RS_OUT"
  chk "warn/no --review: committed (exit 0, ok-r1 eligible)" "$([ "$rc_noreview" -eq 0 ] && git -C "$t/w" log --format=%s -1 | grep -q '^dream: 2 PRDs' && echo 0 || echo 1)" "rc=$rc_noreview"
  printf '# review\nok-r1 APPROVE fable\n\nr2 APPROVE fable\n' > "$t/rev-ok.txt"
  rewind; fresh; mkprd "$t/w/build-queue/PRD-ok-r1.md" r1; mkprd "$t/w/build-queue/PRD-r2.md" r2
  runsplit --review "$t/rev-ok.txt" "$t/w/build-queue/PRD-ok-r1.md" "$t/w/build-queue/PRD-r2.md"
  chk "APPROVE file for 2 grounded PRDs: no warnings, no NOTE" "$([ -z "$RS_ERR" ] && echo 0 || echo 1)" "err=$RS_ERR"
  chk "stdout and exit identical with and without --review (sha normalised)" \
    "$([ "$(sed -E 's/committed: [0-9a-f]+/committed: SHA/' <<<"$out_noreview")" = "$(sed -E 's/committed: [0-9a-f]+/committed: SHA/' <<<"$RS_OUT")" ] && [ "$rc_noreview" -eq "$RS_RC" ] && echo 0 || echo 1)" "a=$out_noreview b=$RS_OUT"
  chk "review log: pushed row carries verdict, reviewer, mode, batch_size, commit" \
    "$(lastlog | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d["outcome"]=="pushed" and d["verdict"]=="APPROVE" and d["reviewer"]=="fable" and d["mode"]=="warn" and d["batch_size"]==2 and d["commit"] and d["warnings"]==[] and d["slug"]=="r2" else 1)'; echo $?)" "$(lastlog)"
  # enforce, no --review: exit 2, nothing pulled or committed, log outcome refused
  fresh; mkprd "$t/w/build-queue/PRD-r3.md" r3
  DREAM_PERSIST_REVIEW_MODE=enforce runsplit "$t/w/build-queue/PRD-r3.md"
  chk "enforce/no --review: exit 2 with FAIL review-missing on stderr" "$([ "$RS_RC" -eq 2 ] && grep -q '^FAIL review-missing' <<<"$RS_ERR" && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  chk "enforce/no --review: nothing committed, manifest untouched" "$([ -z "$(git -C "$t/w" log --format=%s origin/main..HEAD)" ] && git -C "$t/w" diff --quiet -- MANIFEST.md && echo 0 || echo 1)" "$(git -C "$t/w" status --short)"
  chk "enforce/no --review: log outcome refused" "$(lastlog | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d["outcome"]=="refused" and d["mode"]=="enforce" and d["commit"] is None and any("review-missing" in w for w in d["warnings"]) else 1)'; echo $?)" "$(lastlog)"
  # batch of 2 with one creative -> review-solo-required (warn: still persists)
  fresh; mkprdx "$t/w/build-queue/PRD-g1.md" g1 "Grounding: grounded"; mkprdx "$t/w/build-queue/PRD-c1.md" c1 "Grounding: creative"
  printf 'g1 APPROVE fable\nc1 APPROVE fable\n' > "$t/rev-gc.txt"
  runsplit --review "$t/rev-gc.txt" "$t/w/build-queue/PRD-g1.md" "$t/w/build-queue/PRD-c1.md"
  chk "2-PRD batch with a creative PRD: WARN review-solo-required c1 (not g1), rc 0" \
    "$(grep -q '^WARN review-solo-required c1' <<<"$RS_ERR" && ! grep -q 'solo-required g1' <<<"$RS_ERR" && [ "$RS_RC" -eq 0 ] && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  # the same creative PRD alone: no warning
  rewind; fresh; mkprdx "$t/w/build-queue/PRD-c1.md" c1 "Grounding: creative"; printf 'c1 APPROVE fable\n' > "$t/rev-c.txt"
  runsplit --review "$t/rev-c.txt" "$t/w/build-queue/PRD-c1.md"
  chk "creative PRD in a batch of one: no warning" "$([ -z "$RS_ERR" ] && echo 0 || echo 1)" "err=$RS_ERR"
  # foreign_surface_ok in frontmatter, and a lint that reports ac-names-foreign-surface -> solo-required
  fresh; mkprdx "$t/w/build-queue/PRD-g1.md" g1 ""; mkprdx "$t/w/build-queue/PRD-f1.md" f1 "foreign_surface_ok: [1]"
  printf 'g1 APPROVE x\nf1 APPROVE x\n' > "$t/rev-gf.txt"
  runsplit --review "$t/rev-gf.txt" "$t/w/build-queue/PRD-g1.md" "$t/w/build-queue/PRD-f1.md"
  chk "foreign_surface_ok frontmatter -> review-solo-required" "$(grep -q '^WARN review-solo-required f1' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  printf '#!/usr/bin/env bash\nfor f in "$@"; do echo "== $f"; case "$f" in *fsx*) echo "1. FAIL ac-names-foreign-surface: AC 1 names x" ;; *xrp*) echo "2. WARN cross-repo-path-in-ac: AC 1 names a path" ;; *) echo OK ;; esac; done\nexit 0\n' > "$t/lint-ids"; chmod +x "$t/lint-ids"
  fresh; mkprd "$t/w/build-queue/PRD-g1.md" g1; mkprd "$t/w/build-queue/PRD-fsx.md" fsx
  printf 'g1 APPROVE x\nfsx APPROVE x\n' > "$t/rev-gx.txt"
  LINT="$t/lint-ids" runsplit --review "$t/rev-gx.txt" "$t/w/build-queue/PRD-g1.md" "$t/w/build-queue/PRD-fsx.md"
  chk "lint-reported ac-names-foreign-surface -> review-solo-required" "$(grep -q '^WARN review-solo-required fsx' <<<"$RS_ERR" && ! grep -q 'solo-required g1' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  # cross-repo-path-in-ac ALONE: NOTE, no solo
  fresh; mkprd "$t/w/build-queue/PRD-g1.md" g1; mkprd "$t/w/build-queue/PRD-xrp.md" xrp
  printf 'g1 APPROVE x\nxrp APPROVE x\n' > "$t/rev-gp.txt"
  LINT="$t/lint-ids" runsplit --review "$t/rev-gp.txt" "$t/w/build-queue/PRD-g1.md" "$t/w/build-queue/PRD-xrp.md"
  chk "cross-repo-path alone: NOTE review-cross-repo-path, no WARN, still persists" "$(grep -q '^NOTE review-cross-repo-path xrp' <<<"$RS_ERR" && ! grep -q 'WARN' <<<"$RS_ERR" && [ "$RS_RC" -eq 0 ] && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  # malformed line, unknown slug, not-approved verdict, missing line
  fresh; mkprd "$t/w/build-queue/PRD-m1.md" m1; mkprd "$t/w/build-queue/PRD-m2.md" m2
  printf 'm1 APPROVE\nm1 MAYBE x\nghost APPROVE x\nm2 FIX fable\n' > "$t/rev-bad.txt"
  runsplit --review "$t/rev-bad.txt" "$t/w/build-queue/PRD-m1.md" "$t/w/build-queue/PRD-m2.md"
  chk "malformed lines: review-malformed 1 and 2 (line numbers)" "$(grep -q '^WARN review-malformed 1$' <<<"$RS_ERR" && grep -q '^WARN review-malformed 2$' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  chk "unknown slug: review-unknown-slug ghost" "$(grep -q '^WARN review-unknown-slug ghost' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  chk "FIX verdict and a missing line: review-not-approved m2 and m1" "$(grep -q '^WARN review-not-approved m2 (FIX)' <<<"$RS_ERR" && grep -q '^WARN review-not-approved m1 (no line)' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  chk "warn mode with all of the above still persists (rc 0)" "$([ "$RS_RC" -eq 0 ] && git -C "$t/w" log --format=%s -1 | grep -q '^dream: 2 PRDs' && echo 0 || echo 1)" "rc=$RS_RC"
  # last verdict line for a slug wins: FIX r1 then APPROVE r2 -> approved; APPROVE r1 then FIX r2 -> not approved
  rewind; fresh; mkprd "$t/w/build-queue/PRD-lv1.md" lv1
  printf 'lv1 FIX r1\nlv1 APPROVE r2\n' > "$t/rev-lv-fa.txt"
  runsplit --review "$t/rev-lv-fa.txt" "$t/w/build-queue/PRD-lv1.md"
  chk "review last-line: 'FIX r1' then 'APPROVE r2' -> approved (no warning)" "$(! grep -q 'review-not-approved' <<<"$RS_ERR" && [ "$RS_RC" -eq 0 ] && lastlog | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d["verdict"]=="APPROVE" and d["reviewer"]=="r2" else 1)' && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR $(lastlog)"
  rewind; fresh; mkprd "$t/w/build-queue/PRD-lv2.md" lv2
  printf 'lv2 APPROVE r1\nlv2 FIX r2\n' > "$t/rev-lv-af.txt"
  runsplit --review "$t/rev-lv-af.txt" "$t/w/build-queue/PRD-lv2.md"
  chk "review last-line: 'APPROVE r1' then 'FIX r2' -> review-not-approved (FIX)" "$(grep -q '^WARN review-not-approved lv2 (FIX)' <<<"$RS_ERR" && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  rewind; fresh; mkprd "$t/w/build-queue/PRD-lv2.md" lv2
  DREAM_PERSIST_REVIEW_MODE=enforce runsplit --review "$t/rev-lv-af.txt" "$t/w/build-queue/PRD-lv2.md"
  chk "review last-line (enforce): trailing FIX refuses, exit 2" "$([ "$RS_RC" -eq 2 ] && grep -q '^FAIL review-not-approved lv2 (FIX)' <<<"$RS_ERR" && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  rewind; fresh; mkprd "$t/w/build-queue/PRD-lv1.md" lv1
  DREAM_PERSIST_REVIEW_MODE=enforce runsplit --review "$t/rev-lv-fa.txt" "$t/w/build-queue/PRD-lv1.md"
  chk "review last-line (enforce): FIX then APPROVE persists, exit 0" "$([ "$RS_RC" -eq 0 ] && [ -z "$RS_ERR" ] && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  # enforce with a clean review proceeds
  fresh; mkprd "$t/w/build-queue/PRD-e1.md" e1; printf 'e1 APPROVE fable\n' > "$t/rev-e.txt"
  DREAM_PERSIST_REVIEW_MODE=enforce runsplit --review "$t/rev-e.txt" "$t/w/build-queue/PRD-e1.md"
  chk "enforce with an APPROVE line persists" "$([ "$RS_RC" -eq 0 ] && [ -z "$RS_ERR" ] && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  # --review-status counts: pushed with/without a review line, refused, and a row older than 24 h
  python3 - "$REVIEW_LOG" <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
def row(h, outcome, verdict):
    return json.dumps({"ts": (now - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"), "host": "h", "slug": "s",
                       "verdict": verdict, "reviewer": "r" if verdict else None, "mode": "warn", "batch_size": 1,
                       "outcome": outcome, "commit": None, "warnings": []})
open(sys.argv[1], "w").write("\n".join([row(1, "pushed", "APPROVE"), row(2, "pushed", "APPROVE"), row(3, "pushed", None),
    row(4, "refused", None), row(5, "failed", None), row(30, "pushed", "APPROVE"), row(30, "refused", None)]) + "\n")
PY
  chk "--review-status counts the last 24 h only" "$([ "$(review_status)" = "persists_24h=3 with_review=2 review_missing=1 refused=1" ] && echo 0 || echo 1)" "$(review_status)"
  total=$((total+1))
  if [ "$("$0" --review-status 2>/dev/null | cut -d' ' -f1)" = "persists_24h=0" ] || DREAM_REVIEW_LOG="$REVIEW_LOG" "$0" --review-status | grep -q '^persists_24h=3 with_review=2 review_missing=1 refused=1$'; then echo "ok: --review-status CLI prints the one line"; else echo "FAIL: --review-status CLI"; fails=$((fails+1)); fi
  # hooksPath self-heal
  fresh; mkprd "$t/w/build-queue/PRD-h1.md" h1
  mkdir -p "$t/w/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$t/w/.githooks/pre-commit"; chmod +x "$t/w/.githooks/pre-commit"
  git -C "$t/w" config --local --unset core.hooksPath 2>/dev/null
  runsplit "$t/w/build-queue/PRD-h1.md"
  chk "hooksPath unset -> .githooks, message on stderr only" "$([ "$(git -C "$t/w" config --local core.hooksPath)" = ".githooks" ] && grep -q '^hooksPath: enabled .githooks in ' <<<"$RS_ERR" && ! grep -q hooksPath <<<"$RS_OUT" && [ "$RS_RC" -eq 0 ] && echo 0 || echo 1)" "err=$RS_ERR rc=$RS_RC"
  fresh; mkprd "$t/w/build-queue/PRD-h2.md" h2
  mkdir -p "$t/w/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$t/w/.githooks/pre-commit"; chmod +x "$t/w/.githooks/pre-commit"
  git -C "$t/w" config --local core.hooksPath .githooks
  runsplit "$t/w/build-queue/PRD-h2.md"
  chk "hooksPath already .githooks -> silent" "$(! grep -q hooksPath <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  fresh; mkprd "$t/w/build-queue/PRD-h3.md" h3
  mkdir -p "$t/w/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$t/w/.githooks/pre-commit"; chmod +x "$t/w/.githooks/pre-commit"
  git -C "$t/w" config --local core.hooksPath /nonexistent/hooks
  runsplit "$t/w/build-queue/PRD-h3.md"
  chk "hooksPath foreign -> skipped, value untouched" "$([ "$(git -C "$t/w" config --local core.hooksPath)" = "/nonexistent/hooks" ] && grep -q '^hooksPath: skipped (set to /nonexistent/hooks)' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  fresh; mkprd "$t/w/build-queue/PRD-h4.md" h4
  mkdir -p "$t/w/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$t/w/.githooks/pre-commit"; chmod -x "$t/w/.githooks/pre-commit"
  runsplit "$t/w/build-queue/PRD-h4.md"
  chk "hooksPath, hook not executable -> skipped, config stays unset" "$(git -C "$t/w" config --local core.hooksPath >/dev/null 2>&1; [ $? -ne 0 ] && grep -q '^hooksPath: skipped (.githooks/pre-commit not executable)' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  fresh; mkprd "$t/w/build-queue/PRD-h5.md" h5
  mkdir -p "$t/w/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$t/w/.githooks/pre-commit"; chmod +x "$t/w/.githooks/pre-commit"
  DREAM_PERSIST_TODAY=2026-12-01 runsplit "$t/w/build-queue/PRD-h5.md"
  chk "hooksPath guard expired -> message, no-op" "$(git -C "$t/w" config --local core.hooksPath >/dev/null 2>&1; [ $? -ne 0 ] && grep -q '^hooksPath: guard expired (EXPIRES=2026-11-22)' <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  fresh; mkprd "$t/w/build-queue/PRD-h6.md" h6
  runsplit "$t/w/build-queue/PRD-h6.md"
  chk "no .githooks dir -> no hooksPath line, config unset" "$(git -C "$t/w" config --local core.hooksPath >/dev/null 2>&1; [ $? -ne 0 ] && ! grep -q hooksPath <<<"$RS_ERR" && echo 0 || echo 1)" "err=$RS_ERR"
  chk "PREMISE / EXPIRES constants exist" "$([ -n "$PREMISE" ] && [ "$EXPIRES" = "2026-11-22" ] && grep -q '^PREMISE="seat PRD clones lacked core.hooksPath' "$0" && grep -q '^EXPIRES=2026-11-22$' "$0" && echo 0 || echo 1)" "PREMISE=$PREMISE EXPIRES=$EXPIRES"
  # review iter_log normalisation: the old free-form `Fable FIX applied before persist` line becomes the
  # gate-allowed `amended by /dream (review) — …` form, detail kept, committed that way; idempotent
  rewind; fresh; mkprd "$t/w/build-queue/PRD-il1.md" il1; mkprd "$t/w/build-queue/PRD-il2.md" il2
  printf -- '- iter_log: 2026-10-22T22:4xZ Fable FIX applied before persist (8 binding: a, b); kept x\n' >> "$t/w/build-queue/PRD-il1.md"
  printf -- '- iter_log: 2026-10-22T22:4xZ amended by /dream (review) — Fable FIX applied before persist: (already new)\n' >> "$t/w/build-queue/PRD-il2.md"
  runsplit "$t/w/build-queue/PRD-il1.md" "$t/w/build-queue/PRD-il2.md"
  chk "review iter_log: old form rewritten to 'amended by /dream (review) — Fable FIX applied before persist: <detail>'" \
    "$(git -C "$t/w" show HEAD:build-queue/PRD-il1.md | grep -qxF -- '- iter_log: 2026-10-22T22:4xZ amended by /dream (review) — Fable FIX applied before persist: (8 binding: a, b); kept x' && echo 0 || echo 1)" "$(git -C "$t/w" show HEAD:build-queue/PRD-il1.md | grep iter_log)"
  chk "review iter_log: new-form line left byte-identical (idempotent)" \
    "$(git -C "$t/w" show HEAD:build-queue/PRD-il2.md | grep -qxF -- '- iter_log: 2026-10-22T22:4xZ amended by /dream (review) — Fable FIX applied before persist: (already new)' && echo 0 || echo 1)" "$(git -C "$t/w" show HEAD:build-queue/PRD-il2.md | grep iter_log)"
  chk "review iter_log: NOTE on stderr for il1 only, stdout unchanged, rc 0" \
    "$(grep -q '^NOTE review-iterlog-normalized PRD-il1.md' <<<"$RS_ERR" && ! grep -q 'il2.md' <<<"$RS_ERR" && ! grep -qi 'iterlog' <<<"$RS_OUT" && [ "$RS_RC" -eq 0 ] && echo 0 || echo 1)" "rc=$RS_RC err=$RS_ERR"
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --review-status) review_status; exit $? ;;
  -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d'; exit 0 ;;
esac
trap 'review_log_write' EXIT   # a refusal or a crash still writes its log rows
run_main "$@"
