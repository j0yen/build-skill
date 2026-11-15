#!/usr/bin/env bash
# dreamdry_ac06_staging_edges_tmpdir_collision_version — PRD-dream-dryrun-hook R1, R6, R8
# edges from the independent review:
#   DRY-LOW-6 a TMPDIR whose path holds a space or glob characters gave a false
#             `ineligible — lint: exit-1` (dream-lint.sh expands its wm-build command
#             unquoted): such a TMPDIR now answers like any other;
#   DRY-LOW-7 two batch members with one file name: both read slug-not-unique, NEITHER is
#             linted or explained, and the JSON says so (lint.exit null, first_fail
#             slug-not-unique, explain.tick_would null) — no `exit: 0` beside the refusal;
#   DRY-LOW-8 the header version is the version token of `--version`, not its last word;
#             output with no version token reads `unknown`;
#   DM9       a given file wins over the destination's same-named build-queue link;
#   DM6       the explain exit code is never trusted (exit 1 beside `tick-would: admit`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-a

# DRY-LOW-6
for d in "tmp with space" "tmp [g]*?"; do
  mkdir -p "$DD_T/$d"; : > "$DD_T/wb.log"
  TMPDIR="$DD_T/$d" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md"
  dd_expect_line dreamdry-a "admit-would: dreamdry-a eligible claims=unknown open-runs=unknown" "LOW-6 TMPDIR '$d'"
  dd_expect_rc 0 "LOW-6 TMPDIR '$d'"
  grep -q '^lint ' "$DD_T/wb.log" && dd_ok "LOW-6 TMPDIR '$d': wm-build lint really ran through the wrapper" || dd_fail "LOW-6 TMPDIR '$d': wm-build lint never ran: $(cat "$DD_T/wb.log")"
  [ -z "$(ls -A "$DD_T/$d")" ] && dd_ok "LOW-6 TMPDIR '$d': temporary directory removed" || dd_fail "LOW-6 TMPDIR '$d' not empty"
done

# DRY-LOW-7
mkdir -p "$DD_T/drafts2/visions"; cp "$DD_T/drafts/visions/"* "$DD_T/drafts2/visions/"
dd_prd "$DD_T/drafts2" dreamdry-a; dd_prd "$DD_T/drafts" dreamdry-c
: > "$DD_T/wb.log"
dd_run --prd-dir "$DD_T/dest" --json "$DD_T/drafts/PRD-dreamdry-a.md" "$DD_T/drafts2/PRD-dreamdry-a.md" "$DD_T/drafts/PRD-dreamdry-c.md"
dd_expect_rc 3 "LOW-7"
if python3 -I -c '
import json, sys
d = json.loads(sys.argv[1]); fs = d["files"]
assert [f["slug"] for f in fs] == ["dreamdry-a", "dreamdry-a", "dreamdry-c"], fs
for f in fs[:2]:
    assert f["verdict"] == "ineligible" and f["reasons"] == ["lint: slug-not-unique"], f
    assert f["lint"] == {"exit": None, "first_fail": "slug-not-unique"}, f
    assert f["explain"]["tick_would"] is None and f["explain"]["checks"] == [], f
assert fs[2]["verdict"] == "eligible" and fs[2]["lint"]["exit"] == 0, fs[2]
' "$DD_OUT"; then dd_ok "LOW-7 both colliding members read slug-not-unique with consistent JSON; the third is answered"
else dd_fail "LOW-7 JSON: $DD_OUT"; fi
grep -E '^(explain|lint) .*dreamdry-a' "$DD_T/wb.log" && dd_fail "LOW-7 a colliding member was linted or explained" || dd_ok "LOW-7 neither colliding member was linted or explained"
[ "$(grep -c '^explain ' "$DD_T/wb.log")" -eq 1 ] && dd_ok "LOW-7 only the unique member was explained" || dd_fail "LOW-7 explain calls: $(cat "$DD_T/wb.log")"

# DRY-LOW-8
for pair in "0.77.1 (abc123)|0.77.1" "0.77.112|0.77.112" "0.78.0-rc.1+g1a2b|0.78.0-rc.1+g1a2b" "dev build|unknown"; do
  v="${pair%%|*}"; want="${pair#*|}"
  FAKE_WB_VERSION="$v" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md"
  [ "$(head -1 <<<"$DD_OUT")" = "dream-dryrun: host=$DD_HOST wm-build=$want prd-dir=$DD_T/dest" ] \
    && dd_ok "LOW-8 '--version' = 'wm-build $v' -> header wm-build=$want" || dd_fail "LOW-8 '$v': $(head -1 <<<"$DD_OUT")"
done

# DM9: the destination queues a same-named file that would fail lint (missing dependency)
dd_prd "$DD_T/dest/build-queue" dreamdry-q "- Depends-on: PRD-dreamdry-nowhere.md"
dd_prd "$DD_T/drafts" dreamdry-q
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-q.md"
dd_expect_line dreamdry-q "admit-would: dreamdry-q eligible claims=unknown open-runs=unknown" "DM9 the given file wins over the destination's queued link"
grep -q 'Depends-on: PRD-dreamdry-nowhere.md' "$DD_T/dest/build-queue/PRD-dreamdry-q.md" && dd_ok "DM9 the destination's file is unchanged" || dd_fail "DM9 destination file changed"
rm -f "$DD_T/dest/build-queue/PRD-dreamdry-q.md"

# DM6
dd_answer dreamdry-a "EXIT1:tick-would: admit"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md"
dd_expect_line dreamdry-a "admit-would: dreamdry-a eligible claims=unknown open-runs=unknown" "DM6 explain exit 1 beside tick-would: admit is still eligible"
dd_tmp_empty "staging edges"
dd_finish
