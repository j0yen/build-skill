#!/usr/bin/env bash
# landres_ac5_ledger_regen_and_union.sh —
# PRD-build-land-conflict-resolver AC5-adjacent (R5, the ledger slice):
# given two real fixture-repo rebase conflicts resolved by
# `land-resolve.sh resolve` — one `generated`/regen, one `append_only`/
# union — When both resolutions succeed, Then
# state/land-conflicts.jsonl gains one record per file with the right
# class/resolution/slug/repo fields, and
# `scripts/land-conflicts-report.sh` prints both files ordered with their
# class and last resolution.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../scripts/land-resolve.sh"
REPORT="$HERE/../scripts/land-conflicts-report.sh"
[ -x "$RESOLVE" ] || { echo "FAIL: $RESOLVE not executable" >&2; exit 2; }
[ -x "$REPORT" ] || { echo "FAIL: $REPORT not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BUILD_STATE_DIR="$WORK/state"
mkdir -p "$BUILD_STATE_DIR/land-policy"
# Two distinct repo basenames (repo1, repo) each need their own policy
# file — land-resolve.sh's policy-path is keyed on `basename <repo>`.
cat >"$BUILD_STATE_DIR/land-policy/repo1.json" <<'EOF'
{"generated": [{"path": "gen.txt", "regen": "./regen.sh"}], "append_only": []}
EOF
cat >"$BUILD_STATE_DIR/land-policy/repo.json" <<'EOF'
{"generated": [], "append_only": ["CHANGELOG.md"]}
EOF
LEDGER="$BUILD_STATE_DIR/land-conflicts.jsonl"

fail=0

# --- repo 1: generated/regen conflict --------------------------------------
REPO1="$WORK/repo1"
git init -q -b main "$REPO1"
git -C "$REPO1" config user.email a@b.c
git -C "$REPO1" config user.name test
cat >"$REPO1/regen.sh" <<'EOF'
#!/usr/bin/env bash
echo "canonical" > gen.txt
EOF
chmod +x "$REPO1/regen.sh"
( cd "$REPO1" && ./regen.sh )
git -C "$REPO1" add -A
git -C "$REPO1" commit -q -m base
git -C "$REPO1" checkout -q -b autobuilder/fix1
echo "branch-variant" > "$REPO1/gen.txt"
git -C "$REPO1" commit -q -am "branch variant"
git -C "$REPO1" checkout -q main
echo "main-variant" > "$REPO1/gen.txt"
git -C "$REPO1" commit -q -am "main variant"
git -C "$REPO1" checkout -q autobuilder/fix1
git -C "$REPO1" rebase main >/dev/null 2>&1 || true

out1="$("$RESOLVE" resolve "$REPO1" fix1 2>/dev/null)"; rc1=$?
if [ "$rc1" -eq 0 ] && [ "$out1" = "resolved=all" ]; then
  echo "ok  AC5: repo1 (generated/regen) resolved"
else
  echo "FAIL: repo1 resolve expected rc=0/resolved=all, got rc=$rc1 out='$out1'" >&2
  fail=1
fi

# --- repo 2: append_only/union conflict, DIFFERENT repo basename so the ---
# --- report's per-file grouping is exercised with two distinct files. -----
REPO2="$WORK/repo"
git init -q -b main "$REPO2"
git -C "$REPO2" config user.email a@b.c
git -C "$REPO2" config user.name test
printf '# Changelog\n- v1: initial\n' >"$REPO2/CHANGELOG.md"
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m base
git -C "$REPO2" checkout -q -b autobuilder/fix2
printf '# Changelog\n- v1: initial\n- v2: branch entry\n' >"$REPO2/CHANGELOG.md"
git -C "$REPO2" commit -q -am "branch appended v2 entry"
git -C "$REPO2" checkout -q main
printf '# Changelog\n- v1: initial\n- v2: main entry\n' >"$REPO2/CHANGELOG.md"
git -C "$REPO2" commit -q -am "main appended v2 entry"
git -C "$REPO2" checkout -q autobuilder/fix2
git -C "$REPO2" rebase main >/dev/null 2>&1 || true

out2="$("$RESOLVE" resolve "$REPO2" fix2 2>/dev/null)"; rc2=$?
if [ "$rc2" -eq 0 ] && [ "$out2" = "resolved=all" ]; then
  echo "ok  AC5: repo2 (append_only/union) resolved"
else
  echo "FAIL: repo2 resolve expected rc=0/resolved=all, got rc=$rc2 out='$out2'" >&2
  fail=1
fi

# --- ledger assertions -------------------------------------------------
if [ -f "$LEDGER" ] && [ "$(wc -l <"$LEDGER")" -eq 2 ]; then
  echo "ok  AC5: ledger has exactly one record per resolved file (2 total)"
else
  echo "FAIL: expected 2 ledger lines, got: $(cat "$LEDGER" 2>/dev/null)" >&2
  fail=1
fi

gen_rec="$(jq -c 'select(.file=="gen.txt")' "$LEDGER" 2>/dev/null)"
if [ "$(jq -r '.class' <<<"$gen_rec")" = "generated" ] && \
   [ "$(jq -r '.resolution' <<<"$gen_rec")" = "regen" ] && \
   [ "$(jq -r '.slug' <<<"$gen_rec")" = "fix1" ] && \
   [ "$(jq -r '.repo' <<<"$gen_rec")" = "repo1" ]; then
  echo "ok  AC5: gen.txt ledger record has class=generated resolution=regen slug=fix1 repo=repo1"
else
  echo "FAIL: gen.txt ledger record wrong: $gen_rec" >&2
  fail=1
fi

ao_rec="$(jq -c 'select(.file=="CHANGELOG.md")' "$LEDGER" 2>/dev/null)"
if [ "$(jq -r '.class' <<<"$ao_rec")" = "append_only" ] && \
   [ "$(jq -r '.resolution' <<<"$ao_rec")" = "union" ] && \
   [ "$(jq -r '.slug' <<<"$ao_rec")" = "fix2" ]; then
  echo "ok  AC5: CHANGELOG.md ledger record has class=append_only resolution=union slug=fix2"
else
  echo "FAIL: CHANGELOG.md ledger record wrong: $ao_rec" >&2
  fail=1
fi

# --- report assertions --------------------------------------------------
report_out="$("$REPORT" "$LEDGER")"
if grep -q 'gen.txt.*class=generated last_resolution=regen' <<<"$report_out" && \
   grep -q 'CHANGELOG.md.*class=append_only last_resolution=union' <<<"$report_out"; then
  echo "ok  AC5: land-conflicts-report.sh prints both files with class + last resolution"
else
  echo "FAIL: report output missing expected lines:" >&2
  echo "$report_out" >&2
  fail=1
fi

exit $fail
