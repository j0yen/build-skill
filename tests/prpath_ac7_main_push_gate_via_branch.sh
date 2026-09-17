#!/usr/bin/env bash
# tests/prpath_ac7_main_push_gate_via_branch.sh — PRD-build-main-push-gate-pr-path
# AC7 (requirement 5): given a push_via_branch=true repo and a branch-scope
# verdict delta-pass at head H, main-push-gate.sh for a push of H exits 0
# and journals `main-push ok ... via=pr-path gated=H head=H delta=0`; given
# the verdict head is H' != H, exit 4 with `main-push refused` naming both
# shas. A repo with no recorded protection (push_via_branch=false, the
# default) is unaffected -- covered by the pre-existing mainpush_ac*.sh
# suite, which this fixture also re-runs unmodified as a byte-for-byte
# regression check via main-push-gate-selftest.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"
GATE="$PRPATH_SCRIPTS/main-push-gate.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-ac7.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR"

work="$(prpath_mk_repo "$ROOT/repo")"
repo_slug="$(basename "$work")"
head_h="$(git -C "$work" rev-parse HEAD)"

cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF

write_verdict() {  # $1=head $2=verdict
  mkdir -p "$work/target/autobuilder"
  python3 -c "
import json, sys
json.dump({'head': sys.argv[1], 'head_sha': sys.argv[1], 'verdict': sys.argv[2], 'scope': 'branch'},
          open(sys.argv[3], 'w'))
" "$1" "$2" "$work/target/autobuilder/last-verdict.json"
}

# --- match: verdict head == head being pushed, delta-pass -----------------
write_verdict "$head_h" "delta-pass"
out="$("$GATE" "$work" --head "$head_h" 2>"$ROOT/err-match.log")"
rc=$?
cat "$ROOT/err-match.log" >&2
prpath_expect "AC7: matching head+delta-pass exits 0" "[ $rc -eq 0 ]"
prpath_expect "AC7: stdout mentions via=pr-path" "printf '%s' \"$out\" | grep -q 'via=pr-path'"

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
prpath_expect "AC7: journal has the via=pr-path ok line" \
  "grep -q \"main-push  ok  (repo=$repo_slug via=pr-path gated=$head_h head=$head_h delta=0)\" \"$journal_file\""

# --- mismatch: verdict head H' != head being pushed H ----------------------
other_sha="$(git -C "$work" commit-tree "$(git -C "$work" rev-parse HEAD^{tree})" -m "fixture-other" -p "$head_h")"
write_verdict "$other_sha" "delta-pass"
out2="$("$GATE" "$work" --head "$head_h" 2>"$ROOT/err-mismatch.log")"
rc2=$?
err2="$(cat "$ROOT/err-mismatch.log")"
echo "$err2" >&2
prpath_expect "AC7: mismatched head exits 4" "[ $rc2 -eq 4 ]"
prpath_expect "AC7: stderr names main-push refused" "printf '%s' \"$err2\" | grep -q 'main-push refused'"
prpath_expect "AC7: stderr names the pushed head" "printf '%s' \"$err2\" | grep -q \"$head_h\""
prpath_expect "AC7: stderr names the gated (verdict) sha" "printf '%s' \"$err2\" | grep -q \"$other_sha\""
prpath_expect "AC7: journal has a refused via=pr-path line" \
  "grep -q \"main-push  refused  (repo=$repo_slug via=pr-path\" \"$journal_file\""

# --- a block verdict at the exact matching head is still refused ----------
write_verdict "$head_h" "block"
out3="$("$GATE" "$work" --head "$head_h" 2>"$ROOT/err-block.log")"
rc3=$?
prpath_expect "AC7: a 'block' verdict at head H is still refused (exit 4)" "[ $rc3 -eq 4 ]"

exit "$prpath_fail"
