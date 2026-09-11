#!/usr/bin/env bash
# gatedebt_ac6_resurrection_guard_tags_union_resolve.sh — PRD-build-gate-
# debt-auto-prd AC6.
#
# Given a fake union-resolve merge that re-adds an unsafe block without a
# SAFETY comment, When the tick's resurrection check runs, Then
# `merge  resurrection-check  (findings=1)` is journaled and the finding
# is tagged `origin=union-resolve`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$HERE/../scripts/resurrection-guard.sh"
[ -x "$RG" ] || { echo "ac6: $RG not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac6.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

git init -q "$ROOT/repo"
mkdir -p "$ROOT/repo/src"

# Commit A: the unsafe block exists WITH a SAFETY comment (one side of history).
cat > "$ROOT/repo/src/runs.rs" <<'EOF'
fn run() {
    // SAFETY: fd is owned exclusively by this thread here.
    unsafe { do_thing() }
}
EOF
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q -m "add safe unsafe block"
side_a="$(git -C "$ROOT/repo" rev-parse HEAD)"

# A later fix on side A removes the block entirely.
cat > "$ROOT/repo/src/runs.rs" <<'EOF'
fn run() {
    do_thing_safely()
}
EOF
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q -m "remove unsafe block (the fix)"
fix_commit="$(git -C "$ROOT/repo" rev-parse HEAD)"

# A parallel branch (side B), diverging from side_a, unaware of the fix.
git -C "$ROOT/repo" checkout -q -b side-b "$side_a"
echo "// unrelated side-b change" >> "$ROOT/repo/src/other.rs" 2>/dev/null || { echo "// unrelated side-b change" > "$ROOT/repo/src/other.rs"; }
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q -m "side-b unrelated change"

# The stale-base recovery merge (union-resolve): merges side-b into the
# fixed mainline but RESURRECTS the unsafe block (simulating a union
# conflict resolution that kept both sides' content instead of the fix).
git -C "$ROOT/repo" checkout -q main 2>/dev/null || git -C "$ROOT/repo" checkout -q master
before_merge="$(git -C "$ROOT/repo" rev-parse HEAD)"
git -C "$ROOT/repo" merge -q --no-ff -X ours side-b -m "union-resolve merge" || true
cat > "$ROOT/repo/src/runs.rs" <<'EOF'
fn run() {
    do_thing_safely();
    unsafe { do_thing() }
}
EOF
git -C "$ROOT/repo" add -A
git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q --amend -m "union-resolve merge (resurrected unsafe block)"
after_merge="$(git -C "$ROOT/repo" rev-parse HEAD)"

JOURNAL="$ROOT/journal.md"
: > "$JOURNAL"
OUT="$ROOT/findings.json"

out="$("$RG" check "$ROOT/repo" "$before_merge" "$after_merge" --journal "$JOURNAL" --out "$OUT")"; rc=$?
expect "exits 0" "[ $rc -eq 0 ]"
expect "journal has resurrection-check with findings=1" \
  "grep -q 'merge  resurrection-check  (findings=1)' '$JOURNAL'"
expect "findings file has exactly one entry" "[ \"\$(python3 -c 'import json;print(len(json.load(open(\"'$OUT'\"))))')\" -eq 1 ]"
expect "finding tagged origin=union-resolve" \
  "python3 -c 'import json,sys; d=json.load(open(\"'$OUT'\")); sys.exit(0 if d[0][\"origin\"]==\"union-resolve\" else 1)'"
expect "finding tagged scope=inherited" \
  "python3 -c 'import json,sys; d=json.load(open(\"'$OUT'\")); sys.exit(0 if d[0][\"scope\"]==\"inherited\" else 1)'"
expect "finding names the resurrected file" \
  "python3 -c 'import json,sys; d=json.load(open(\"'$OUT'\")); sys.exit(0 if d[0][\"path\"]==\"src/runs.rs\" else 1)'"

exit $fail
