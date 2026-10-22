#!/usr/bin/env bash
# dream-persist.sh — /dream hook `dream.persist` (Phase 4, per batch of <= 4 PRDs):
# lint, refresh MANIFEST.md, commit ONLY this batch, push, and report whether the
# daemon would admit each PRD. WRITES: the PRDs repo's MANIFEST.md, one commit,
# one push, and touches ~/.claude/.dream-active.
#
# Usage:
#   dream-persist.sh <PRD file>...       (1..4 files, all inside one PRDs git clone)
#   dream-persist.sh --selftest          (throwaway git repos; no network)
#
# Steps, in order (each failure stops the run before anything is committed):
#   1. refuse > 4 PRDs (exit 2); refuse when the repo is a daemon's PRD clone: its
#      toplevel equals `prd_dir` in ~/.config/wm-build/config.toml on this host, or
#      it holds a `.wm-build-daemon` marker (exit 2). Never persist in a daemon clone.
#   2. touch ~/.claude/.dream-active (the dream-write gate reads it)
#   3. scripts/dream-lint.sh <files>           (any FAIL: stop, exit 1)
#   4. `git pull --rebase --autostash` (when origin exists), so the manifest is
#      computed on the latest tip and cannot conflict
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
#       | 2 refused (count / daemon clone) | 1 lint FAIL, guard, git or usage error
#
# Env (selftest seams): DREAM_PERSIST_LINT, DREAM_ACTIVE_FILE, WM_BUILD_CONFIG,
#   DREAM_PERSIST_WM_BUILD (command for explain, default wm-build), DREAM_PERSIST_SSH,
#   DREAM_PERSIST_NO_PULL=1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${DREAM_PERSIST_LINT:-$HERE/dream-lint.sh}"
ACTIVE="${DREAM_ACTIVE_FILE:-$HOME/.claude/.dream-active}"
CONFIG="${WM_BUILD_CONFIG:-$HOME/.config/wm-build/config.toml}"
WB="${DREAM_PERSIST_WM_BUILD:-wm-build}"
SSH="${DREAM_PERSIST_SSH:-ssh -o ConnectTimeout=8}"
PATHX='export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH;'

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

run_main() {
  [ "$#" -ge 1 ] || { die "usage: dream-persist.sh <PRD file>... (<= 4)"; return 1; }
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

  # 3. lint
  if ! "$LINT" "${rels[@]/#/$top/}"; then die "dream-lint reported a FAIL: nothing committed"; return 1; fi

  cd "$top" || return 1
  local has_origin=0
  git remote get-url origin >/dev/null 2>&1 && has_origin=1

  # 4. latest tip first (autostash: the drafted files and a dirty manifest ride along)
  if [ "$has_origin" -eq 1 ] && [ -z "${DREAM_PERSIST_NO_PULL:-}" ]; then
    git pull --rebase --autostash -q || { die "git pull --rebase failed: nothing committed"; return 1; }
  fi

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
  if [ "$has_origin" -eq 1 ]; then
    git push -q origin HEAD || { die "git push failed (committed locally as $(git rev-parse --short HEAD))"; return 1; }
    echo "pushed: origin"
  else
    echo "pushed: no origin remote, commit stays local"
  fi

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
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
esac
run_main "$@"
