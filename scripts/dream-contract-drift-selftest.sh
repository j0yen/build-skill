#!/usr/bin/env bash
# dream-contract-drift-selftest.sh — fails when build-contract.md's Frontmatter
# table and Lint rules drift from the things that read or write them. Read-only.
#
#   (a) every key the /dream skill's code-fenced frontmatter guidance names
#       (lines `- Key:` inside code fences of ~/.claude/skills/dream/SKILL.md) is
#       a row of the contract's Frontmatter table. Skipped with a note when
#       SKILL.md has no code-fenced key list.
#   (b) every key in the `match key.as_str()` arms of wm-build's src/prd.rs at
#       origin/main (git fetch, then `git show origin/main:src/prd.rs`; the
#       working tree is never read) is a row of the table.
#   (c) every key used in the header block (before the first `## `) of >= 10 PRD
#       files across build-queue/, built-prds/ and parked/ is a row of the table.
#   (d) every fleet lint rule id (the contract's `## Lint rules (fleet)` table and
#       the built-in shift-left ids it lists) has a failing/warning fixture AND a
#       passing fixture in prd-lint-selftest.sh.
#   (e) every one of those rule ids is named in prd-lint.sh (LINT_SRC), so the
#       contract list and the lint list cannot drift apart.
#
# Fix a failure by adding the missing key/id to the contract table (or its
# fixture), never by weakening the check.
#
# Usage: dream-contract-drift-selftest.sh [--selftest]
# Env:   CONTRACT (default: sibling ../build-contract.md), DREAM_SKILL_MD,
#        WM_BUILD_SRC (default ~/wintermute/wm-build), PRD_DIR (default
#        ~/Documents/PRDs), DRIFT_MIN_PRDS (default 10), DRIFT_NO_FETCH=1,
#        LINT_SELFTEST (default: sibling prd-lint-selftest.sh).
# Exit 0 no drift | 1 drift (one FAIL line per missing key/id)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="${CONTRACT:-$HERE/../build-contract.md}"
SKILL_MD="${DREAM_SKILL_MD:-$HOME/.claude/skills/dream/SKILL.md}"
WM_SRC="${WM_BUILD_SRC:-$HOME/wintermute/wm-build}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
MIN="${DRIFT_MIN_PRDS:-10}"
LINT_SELFTEST="${LINT_SELFTEST:-$HERE/prd-lint-selftest.sh}"

# Frontmatter keys + fleet/built-in rule ids parsed from the contract (normalised: lowercase, _ for space/-)
contract_keys() {
  python3 - "$CONTRACT" <<'PY'
import re, sys
sec = ""
for ln in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if ln.startswith("## "):
        sec = ln[3:].strip(); continue
    if sec == "Frontmatter" and ln.startswith("| `"):
        cell = re.split(r"(?<!\\)\|", ln)[1]
        for k in re.findall(r"`([^`]+)`", cell):
            print(k.strip().lower().replace("-", "_").replace(" ", "_"))
PY
}

contract_rule_ids() {
  python3 - "$CONTRACT" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec, ids = "", []
for ln in text.splitlines():
    if ln.startswith("## "):
        sec = ln[3:].strip(); continue
    if ln.startswith("### "):
        sec = "sub:" + ln[4:].strip(); continue
    if sec.startswith("Lint rules (fleet)") and ln.startswith("| `") and "rule id" not in ln:
        cell = re.split(r"(?<!\\)\|", ln)[1]
        ids += re.findall(r"`([a-z0-9-]+)`", cell)
# built-in shift-left ids: the contract paragraph "The `prd-lint.sh` built-in shift-left ids are ..."
m = re.search(r"built-in shift-left\s+ids\s+are(.*?)\(see", text, re.S)
if m:
    ids += re.findall(r"`([a-z0-9-]+)`", m.group(1))
print("\n".join(dict.fromkeys(ids)))
PY
}

norm() { tr 'A-Z-' 'a-z_' | tr ' ' '_'; }

skill_keys() { # lines `- Key:` inside code fences
  [ -f "$SKILL_MD" ] || return 0
  awk '/^[[:space:]]*```/ { f = !f; next } f && /^- [A-Za-z_-]+:/ { sub(/^- /, ""); sub(/:.*/, ""); print }' "$SKILL_MD" | norm | sort -u
}

prs_keys() { # match key.as_str() arms at origin/main
  [ -d "$WM_SRC/.git" ] || [ -f "$WM_SRC/HEAD" ] || return 3
  [ -n "${DRIFT_NO_FETCH:-}" ] || timeout 15 git -C "$WM_SRC" fetch -q origin 2>/dev/null || true
  local src; src="$(git -C "$WM_SRC" show origin/main:src/prd.rs 2>/dev/null)" || return 3
  local builtkey; builtkey="$(grep -oE 'const BUILT_KEY: *&str *= *"[^"]+"' <<<"$src" | grep -oE '"[^"]+"' | tr -d '"' | head -1)"
  awk -v built="${builtkey:-Built}" '
    /match key\.as_str\(\) *\{/ { f = 1; next }
    f && /^            _ *=>/ { exit }
    f && /^            ("[^"]+"|BUILT_KEY)( |$)/ {
      s = $1; gsub(/"/, "", s); if (s == "BUILT_KEY") s = built; print s
    }' <<<"$src" | norm | sort -u
}

corpus_keys() { # keys in >= MIN PRD headers
  python3 - "$PRD_DIR" "$MIN" <<'PY'
import collections, os, re, sys
root, minn = sys.argv[1], int(sys.argv[2])
cnt = collections.Counter()
for d in ("build-queue", "built-prds", "parked"):
    p = os.path.join(root, d)
    if not os.path.isdir(p): continue
    for fn in os.listdir(p):
        if not (fn.startswith("PRD-") and fn.endswith(".md")): continue
        seen, fence = set(), False
        try: lines = open(os.path.join(p, fn), encoding="utf-8", errors="replace").read().splitlines()[:80]
        except OSError: continue
        for ln in lines:
            if ln.startswith("## "): break
            if ln.strip().startswith("```"): fence = not fence; continue
            if fence: continue
            k = re.sub(r"^[-*+]\s+", "", ln)
            k = re.sub(r"^\*\*([A-Za-z][A-Za-z _-]*):\*\*", r"\1:", k)
            m = re.match(r"^([A-Za-z][A-Za-z_-]*)\s*:\s*\S", k)   # one-word keys only: prose "Foo bar:" is not frontmatter
            if m: seen.add(m.group(1).lower().replace("-", "_"))
        cnt.update(seen)
for k, n in sorted(cnt.items()):
    if n >= minn: print(f"{k} {n}")
PY
}

check() {
  local fails=0
  local keys; keys="$(contract_keys)"
  [ -n "$keys" ] || { echo "FAIL: no Frontmatter table rows parsed from $CONTRACT"; return 1; }
  has_key() { grep -qxF -- "$1" <<<"$keys"; }

  # (a)
  local sk; sk="$(skill_keys)"
  if [ -z "$sk" ]; then
    echo "note: (a) skipped: $SKILL_MD has no code-fenced \`- Key:\` list"
  else
    local k miss=0
    while IFS= read -r k; do has_key "$k" || { echo "FAIL (a): SKILL.md frontmatter key '$k' is not a row of the contract Frontmatter table"; miss=$((miss+1)); }; done <<<"$sk"
    [ "$miss" -eq 0 ] && echo "ok (a): $(wc -l <<<"$sk") SKILL.md frontmatter keys all in the contract table" || fails=$((fails+miss))
  fi
  # (b)
  local pk; pk="$(prs_keys)"; local prc=$?
  if [ "$prc" -eq 3 ] || [ -z "$pk" ]; then
    echo "FAIL (b): could not read the match arms of src/prd.rs at origin/main of $WM_SRC"; fails=$((fails+1))
  else
    local k miss=0
    while IFS= read -r k; do has_key "$k" || { echo "FAIL (b): wm-build src/prd.rs key '$k' is not a row of the contract Frontmatter table"; miss=$((miss+1)); }; done <<<"$pk"
    [ "$miss" -eq 0 ] && echo "ok (b): $(wc -l <<<"$pk") src/prd.rs match-arm keys all in the contract table" || fails=$((fails+miss))
  fi
  # (c)
  local ck; ck="$(corpus_keys)"
  if [ -z "$ck" ]; then
    echo "note: (c) skipped: no key reached $MIN files under $PRD_DIR/{build-queue,built-prds,parked}"
  else
    local miss=0 k n
    while read -r k n; do has_key "$k" || { echo "FAIL (c): key '$k' is used in $n PRD files but is not a row of the contract Frontmatter table"; miss=$((miss+1)); }; done <<<"$ck"
    [ "$miss" -eq 0 ] && echo "ok (c): $(wc -l <<<"$ck") corpus keys (>= $MIN files) all in the contract table" || fails=$((fails+miss))
  fi
  # (d)
  local id miss=0 ids; ids="$(contract_rule_ids)"
  if [ -z "$ids" ]; then echo "FAIL (d): no rule ids parsed from the contract's Lint rules (fleet) section"; fails=$((fails+1)); else
    while IFS= read -r id; do
      grep -qE "^expect_(fail|warn) .* $id " "$LINT_SELFTEST" || { echo "FAIL (d): rule '$id' has no expect_fail/expect_warn fixture in $(basename "$LINT_SELFTEST")"; miss=$((miss+1)); }
      grep -qE "^expect_clean_no_id .* $id " "$LINT_SELFTEST" || { echo "FAIL (d): rule '$id' has no passing (expect_clean_no_id) fixture in $(basename "$LINT_SELFTEST")"; miss=$((miss+1)); }
    done <<<"$ids"
    [ "$miss" -eq 0 ] && echo "ok (d): $(wc -l <<<"$ids") rule ids each have a fail/warn and a pass fixture" || fails=$((fails+miss))
  fi
  # (e) every contract rule id is named in prd-lint.sh itself (contract list and lint list cannot drift apart)
  if [ -n "$ids" ]; then
    local lint_src="${LINT_SRC:-$HERE/prd-lint.sh}" lmiss=0
    while IFS= read -r id; do
      grep -qF -- "$id" "$lint_src" || { echo "FAIL (e): contract rule id '$id' is not named in $(basename "$lint_src")"; lmiss=$((lmiss+1)); }
    done <<<"$ids"
    [ "$lmiss" -eq 0 ] && echo "ok (e): $(wc -l <<<"$ids") contract rule ids all named in $(basename "$lint_src")" || fails=$((fails+lmiss))
  fi
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  echo "(--selftest: the drift test is itself the selftest; it also proves it can fail)"
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  total=0; bad=0
  # a contract missing a key must FAIL (a),(b),(c)
  sed '/^| `Absorbs`/d;/^| `Vision`/d' "$CONTRACT" > "$t/contract.md"
  total=$((total+1))
  if out="$(CONTRACT="$t/contract.md" "$0" 2>&1)"; then echo "FAIL: drift test passed on a contract with Absorbs/Vision rows removed"; bad=$((bad+1)); else
    grep -q "FAIL (b).*'absorbs'" <<<"$out" && echo "ok: removed key is caught by (b)" || { echo "FAIL: (b) did not name 'absorbs': $out"; bad=$((bad+1)); }; fi
  # a selftest file without a fixture for one id must FAIL (d)
  grep -v 'seed-missing' "$LINT_SELFTEST" > "$t/lint-selftest.sh"
  total=$((total+1))
  if out="$(LINT_SELFTEST="$t/lint-selftest.sh" "$0" 2>&1)"; then echo "FAIL: drift test passed with seed-missing fixtures removed"; bad=$((bad+1)); else
    grep -q "FAIL (d): rule 'seed-missing'" <<<"$out" && echo "ok: missing fixture is caught by (d)" || { echo "FAIL: (d) did not name seed-missing: $out"; bad=$((bad+1)); }; fi
  # the real contract passes
  total=$((total+1))
  if out="$("$0" 2>&1)"; then echo "ok: real contract has no drift"; else echo "FAIL: real contract drifts: $out"; bad=$((bad+1)); fi
  [ "$bad" -eq 0 ] && { echo "SELFTEST PASSED ($total checks)"; exit 0; } || { echo "SELFTEST FAILED ($bad/$total checks)"; exit 1; }
fi

check
rc=$?
[ "$rc" -eq 0 ] && echo "DRIFT TEST PASSED" || echo "DRIFT TEST FAILED"
exit $rc
