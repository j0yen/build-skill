#!/usr/bin/env bash
# tests/prpath_ac13_idempotent_push.sh — PRD-build-main-push-gate-pr-path
# AC13 (requirement 10, P1): `branch-protection.sh push` run twice for the
# same slug across two ticks ends with exactly one open PR for
# `loop/<slug>` and one landing record carrying one `pr_number` and an
# UPDATED `armed_at` — never a second PR, never a duplicated record.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac13.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
GIT_ID=(-c user.email=test@prpath-selftest.local -c user.name="prpath-selftest")

REPO="$ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
echo one > "$REPO/file.txt"
git -C "$REPO" "${GIT_ID[@]}" add -A
git -C "$REPO" "${GIT_ID[@]}" commit -qm init
git clone -q --bare "$REPO" "$ROOT/origin.git"
git -C "$REPO" remote add origin "$ROOT/origin.git"
git -C "$REPO" push -q origin main
repo_slug="$(basename "$REPO")"

export BUILD_STATE_DIR="$ROOT/state"
mkdir -p "$BUILD_STATE_DIR"
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF

bindir="$ROOT/bin"
prpath_install_gh_stub "$bindir"
export PATH="$bindir:$PATH"

# --- tick 1: no open PR yet -> `push` opens a new one -----------------
echo two >> "$REPO/file.txt"
git -C "$REPO" "${GIT_ID[@]}" commit -qam "second commit"
"$PRPATH_BP" push "$REPO" idempotent-slug >"$ROOT/push1.log" 2>&1
rc1=$?
prpath_expect "AC13: first push exits 0" "[ $rc1 -eq 0 ]"

record="$BUILD_STATE_DIR/landings/$repo_slug/idempotent-slug.json"
prpath_expect "AC13: landing record exists after tick 1" "[ -f \"$record\" ]"
armed_1="$(python3 -c 'import json;print(json.load(open("'"$record"'"))["armed_at"])')"
pr_number_1="$(python3 -c 'import json;print(json.load(open("'"$record"'"))["pr_number"])')"

sleep 1

# --- tick 2: simulate an already-open PR (the reuse path) -- pr list
# returns the SAME URL `pr create` printed on tick 1 -- and re-run push
# for the SAME slug with a NEW head (a later tick landed more commits).
export PRPATH_GH_PR_LIST_URL="${PRPATH_GH_PR_CREATE_URL:-https://github.com/j0yen/fixture-repo/pull/1}"
echo three >> "$REPO/file.txt"
git -C "$REPO" "${GIT_ID[@]}" commit -qam "third commit"
"$PRPATH_BP" push "$REPO" idempotent-slug >"$ROOT/push2.log" 2>&1
rc2=$?
prpath_expect "AC13: second push exits 0" "[ $rc2 -eq 0 ]"

prpath_expect "AC13: exactly one gh pr create call across both ticks" \
  "[ \"\$(wc -l < \"$bindir/pr-create-calls.log\")\" -eq 1 ]"
prpath_expect "AC13: landing record still one file, same pr_number" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"$record\"))[\"pr_number\"])')\" = \"$pr_number_1\" ]"
armed_2="$(python3 -c 'import json;print(json.load(open("'"$record"'"))["armed_at"])')"
prpath_expect "AC13: armed_at was refreshed, not left stale" "[ \"$armed_2\" != \"$armed_1\" ]"
prpath_expect "AC13: exactly one open PR for loop/idempotent-slug (one landings dir entry)" \
  "[ \"\$(find \"$BUILD_STATE_DIR/landings/$repo_slug\" -maxdepth 1 -name 'idempotent-slug.json' | wc -l)\" -eq 1 ]"

exit "$prpath_fail"
