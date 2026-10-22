#!/usr/bin/env bash
# prd-slug-check.sh <slug> — the shared writer check every in-repo PRD
# writer calls before minting `build-queue/PRD-<slug>.md` (PRD-build-prd-
# slug-uniqueness, "weakest link 5"). A slug is used as a primary key
# across the manifest, claims, receipts, and test_prefix pairing, but
# nothing enforced that it names exactly one PRD -- gate-debt.sh and a
# hand-drafted /dream follow-on both minted `PRD-build-post-ship-reality-
# check.md` without either one knowing the other's copy existed.
#
# Usage:
#   prd-slug-check.sh <slug>
#   prd-slug-check.sh --similar <PRD file>   (WARN-only; /dream shift-left)
#   prd-slug-check.sh --selftest
#
# Env:
#   PRD_DIR   PRD workspace root (default $HOME/Documents/PRDs).
#
# --similar <file>: compare the new PRD's title tokens (H1 minus stopwords)
#   against every build-queue/ PRD with Status queued|building and the same
#   build_into (its Vision is shown for context); Jaccard >= 0.6 prints
#   "prd-slug-check: WARN similar: ..." plus "add Absorbs: or Superseded-by:".
#   Always exits 0 (a warning, never a gate; the file itself is skipped), 2 on
#   a usage error. The default slug mode below is unchanged.
#
# Exit 0, no stdout: the slug is free in build-queue/, built-prds/, AND
#   parked/ -- safe to write build-queue/PRD-<slug>.md.
# Exit 1, stdout names the existing location(s) and (when one can be found)
#   a free candidate slug: the slug is already taken by at least one file
#   anywhere in the corpus.
# Exit 2: usage error.
set -uo pipefail

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# similar_main <file>: Jaccard >= 0.6 on title tokens, same build_into, against
# build-queue PRDs that are queued|building.
similar_main() {
  PRD_DIR="$PRD_DIR" python3 - "$1" <<'PY'
import os, re, sys
STOP = set("a an and the of to for in on at by with from into as is are be it its this that "
           "prd vision add adds make makes via per so no not or when then".split())
THRESH = 0.6

def tokens(title):
    return {w for w in re.findall(r"[a-z0-9]+", title.lower()) if w not in STOP and len(w) > 1}

def head(path):
    title, kv = "", {}
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()[:80]
    except OSError:
        return None
    for ln in lines:
        if not title and ln.startswith("# "):
            title = re.sub(r"^#\s+(?:PRD\s*[\u2014\u2013:-]\s*)?", "", ln).strip()
            continue
        k = re.sub(r"^[-*+]\s+", "", ln)
        k = re.sub(r"^\*\*([A-Za-z_ -]+):\*\*", r"\1:", k)
        m = re.match(r"^([A-Za-z_][A-Za-z_ -]*):\s*(.*)$", k)
        if m and m.group(1).strip().lower() not in kv:
            kv[m.group(1).strip().lower()] = m.group(2).strip()
    return title, kv

new = sys.argv[1]
h = head(new)
if h is None:
    print(f"prd-slug-check: cannot read {new}", file=sys.stderr); sys.exit(2)
ntitle, nkv = h
ntok = tokens(ntitle)
nbi = nkv.get("build_into", "").rstrip("/")
qdir = os.path.join(os.environ["PRD_DIR"], "build-queue")
hits = 0
if ntok and os.path.isdir(qdir):
    for fn in sorted(os.listdir(qdir)):
        path = os.path.join(qdir, fn)
        if not (fn.startswith("PRD-") and fn.endswith(".md")) or os.path.abspath(path) == os.path.abspath(new):
            continue
        r = head(path)
        if r is None:
            continue
        otitle, okv = r
        if okv.get("status", "").split()[:1] not in (["queued"], ["building"]):
            continue
        if okv.get("build_into", "").rstrip("/") != nbi:
            continue
        otok = tokens(otitle)
        if not otok:
            continue
        j = len(ntok & otok) / len(ntok | otok)
        if j >= THRESH:
            hits += 1
            same_v = " (same Vision)" if nkv.get("vision") and nkv.get("vision") == okv.get("vision") else ""
            print(f"prd-slug-check: WARN similar: {fn} [{okv.get('status','?')}] jaccard={j:.2f} on title tokens, "
                  f"same build_into{same_v}")
if hits:
    print("prd-slug-check: add Absorbs: or Superseded-by: (or amend the existing PRD) before queueing a near-duplicate")
sys.exit(0)
PY
}

selftest() {
  local t fails=0 total=0 out rc
  t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  mkdir -p "$t/build-queue" "$t/built-prds" "$t/parked"
  mk() { printf '# PRD — %s\n\n- Status: %s\n- build_into: %s\n- Vision: visions/v.md\n' "$2" "$3" "$4" > "$1"; }
  mk "$t/build-queue/PRD-a.md" "Lint the signup path for orphan tenants" queued /r/mcphost
  mk "$t/build-queue/PRD-b.md" "Lint the signup path for orphan tenants" queued /r/other
  mk "$t/build-queue/PRD-c.md" "Lint the signup path for orphan tenants" built /r/mcphost
  mk "$t/build-queue/PRD-d.md" "Totally different thing about billing" building /r/mcphost
  mk "$t/new-dup.md" "Lint signup path for orphan tenants" queued /r/mcphost
  mk "$t/new-diff.md" "Rewrite the dashboard colour theme" queued /r/mcphost
  chk() { # $1=label $2=file $3=expected substring ('' = no WARN)
    total=$((total+1))
    out="$(PRD_DIR="$t" "$SELF" --similar "$2" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then echo "FAIL: $1 exit=$rc"; fails=$((fails+1)); return; fi
    if [ -n "$3" ]; then
      if grep -q "$3" <<<"$out" && grep -q 'Absorbs:' <<<"$out"; then echo "ok: $1"; else echo "FAIL: $1: $out"; fails=$((fails+1)); fi
    else
      if [ -z "$out" ]; then echo "ok: $1"; else echo "FAIL: $1 expected silence: $out"; fails=$((fails+1)); fi
    fi
  }
  chk "similar/queued same build_into -> WARN" "$t/new-dup.md" "WARN similar: PRD-a.md"
  total=$((total+1))
  out="$(PRD_DIR="$t" "$SELF" --similar "$t/new-dup.md" 2>&1)"
  if grep -q 'PRD-b.md' <<<"$out" || grep -q 'PRD-c.md' <<<"$out" || grep -q 'PRD-d.md' <<<"$out"; then
    echo "FAIL: similar flagged a different build_into / built / dissimilar PRD: $out"; fails=$((fails+1))
  else echo "ok: similar ignores other build_into, non-queued/building, and dissimilar titles"; fi
  chk "similar/dissimilar title -> silent" "$t/new-diff.md" ""
  total=$((total+1))
  out="$(PRD_DIR="$t" "$SELF" --similar "$t/build-queue/PRD-a.md" 2>&1)"
  if ! grep -q 'PRD-a.md' <<<"$out"; then echo "ok: similar skips the file itself"; else echo "FAIL: similar matched itself: $out"; fails=$((fails+1)); fi
  total=$((total+1))
  PRD_DIR="$t" "$SELF" PRD-a >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 1 ]; then echo "ok: default slug mode unchanged (taken slug -> exit 1)"; else echo "FAIL: default mode exit=$rc (want 1)"; fails=$((fails+1)); fi
  total=$((total+1))
  PRD_DIR="$t" "$SELF" free-slug >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok: default slug mode unchanged (free slug -> exit 0)"; else echo "FAIL: free slug exit=$rc"; fails=$((fails+1)); fi
  total=$((total+1))
  "$SELF" --similar >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then echo "ok: --similar without a file -> exit 2"; else echo "FAIL: --similar usage exit=$rc"; fails=$((fails+1)); fi
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --similar)
    [ -n "${2:-}" ] || { echo "usage: prd-slug-check.sh --similar <PRD file>" >&2; exit 2; }
    similar_main "$2"; exit $? ;;
esac

slug="${1:-}"
if [ -z "$slug" ]; then
  echo "usage: prd-slug-check.sh <slug>" >&2
  exit 2
fi
# Tolerate being handed a filename or a `PRD-`-prefixed slug by mistake.
slug="$(basename "$slug")"
slug="${slug#PRD-}"
slug="${slug%.md}"

fname="PRD-$slug.md"
existing=()
for d in build-queue built-prds parked; do
  p="$PRD_DIR/$d/$fname"
  [ -f "$p" ] && existing+=("$p")
done

if [ "${#existing[@]}" -eq 0 ]; then
  exit 0
fi

is_free() {
  local cand="$1" d
  for d in build-queue built-prds parked; do
    [ -f "$PRD_DIR/$d/PRD-$cand.md" ] && return 1
  done
  return 0
}

proposed=""
for cand in "${slug}-v2" "${slug}-v3" "${slug}-v4" "${slug}-followup"; do
  if is_free "$cand"; then
    proposed="$cand"
    break
  fi
done

echo "prd-slug-check: slug '$slug' is already taken: ${existing[*]}"
if [ -n "$proposed" ]; then
  echo "prd-slug-check: proposed free slug: $proposed"
else
  echo "prd-slug-check: no free suffix found among -v2/-v3/-v4/-followup; choose a new slug by hand"
fi
exit 1
