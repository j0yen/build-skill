#!/usr/bin/env bash
# day-ledger-selftest.sh — PRD-build-day-ledger AC11. Replays AC1-AC7 (and
# P1 AC9/AC10) against ONE shared set of frozen fixture sources, including
# the negative cases (a missing source, an unwritable output dir, an
# identifier-closure violation injected into a produced file), each
# printing "ok  <label>" or "FAIL: <label>  <detail>" — same convention
# tests/dayledger_ac*.sh's shared-helper wrappers grep for (mirrors
# tests/fixtures/archatomic-ac-common.sh: one real implementation here,
# never duplicated per-AC). Then it runs day-ledger.sh once for real
# (today, real PRD_DIR, real push) and checks the identifier-closure and
# secrets checks on THAT file too.
#
# Isolation: every fixture below lives under a mktemp -d workspace; the
# only writes outside it are (a) the real live-run phase at the very end,
# which deliberately targets the real $HOME/Documents/PRDs (that IS
# day-ledger.sh's job) and (b) journal_line calls, which honor
# BUILD_JOURNAL_ROOT like every other script in this repo — set it before
# running this file's fixture phases from a shared/production checkout if
# you want those isolated too; the worktree-extend.sh reminder's
# BUILD_STATE_DIR export already isolates day-ledger.sh's own push-fail
# streak file.
#
# Exit: 0 iff every assertion (including every negative-case detection)
# passed; prints "PASS" with a 0 FAIL count on success, "FAIL n" with a
# nonzero count otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL="$HERE/day-ledger.sh"
JQ="${JQ:-jq}"

PASS=0
FAIL=0
fails=()

ok() { PASS=$((PASS + 1)); printf 'ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); fails+=("$1"); printf 'FAIL: %s\n' "$1"; }
assert() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1 (got=$2 want=$3)"; }

WORK="$(mktemp -d /tmp/day-ledger-selftest.XXXXXX)"
cleanup() { [ "${DAY_LEDGER_SELFTEST_KEEP_WORK:-0}" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURE_DATE="2030-06-15"
FIXTURE_PREV_DATE="2030-06-14"

# ======================================================================
# Fixture construction (one shared set, per AC1's own framing: "Given
# frozen fixture sources for one day")
# ======================================================================

# ---- PRDs fixture repo (bare origin + working clone) ------------------
ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
PRD_DIR="$WORK/prd-repo"
git clone -q "$ORIGIN" "$PRD_DIR" 2>/dev/null
git -C "$PRD_DIR" -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q --allow-empty -m "init"
DEFAULT_BRANCH="$(git -C "$PRD_DIR" symbolic-ref --short HEAD)"
# Push local HEAD to origin under its OWN name, once, with -u — this is
# the first-ever push to an empty bare repo, so it also becomes origin's
# HEAD symref; every later plain `git push`/`git pull --rebase` (inside
# day-ledger.sh, and $SIBLING below) then resolves to the SAME ref. An
# earlier version of this fixture pushed to a hardcoded "main" once and
# to $DEFAULT_BRANCH later, silently diverging local upstream tracking
# from origin's real default branch — day-ledger.sh's own commits landed
# on a ref nothing else ever read.
git -C "$PRD_DIR" push -q -u origin "$DEFAULT_BRANCH"

mk_archive_commit() {  # $1 = slug, $2 = ISO ts
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
    git -C "$PRD_DIR" -c user.email=fixture@example.com -c user.name=Fixture \
    commit -q --allow-empty -m "archive: $1 shipped"
}
mk_archive_commit "fixture-slug-a" "${FIXTURE_DATE}T16:00:00"
mk_archive_commit "fixture-slug-b" "${FIXTURE_DATE}T16:05:00"
git -C "$PRD_DIR" push -q origin "$DEFAULT_BRANCH"

# ---- gate-red.summary fixture -----------------------------------------
GATE_SUMMARY="$WORK/gate-red.summary"
printf '%sT15:00:00Z GATES(3h): green=3 red=1 incomplete=0 blockers: none oldest-red=%sT14:30:00Z red_slugs: fixture-slug-c\n' \
  "$FIXTURE_DATE" "$FIXTURE_DATE" > "$GATE_SUMMARY"

# ---- decisions.jsonl fixture -------------------------------------------
DECISIONS="$WORK/decisions.jsonl"
cat > "$DECISIONS" <<EOF
{"id":"aaaa1111","repo":"fixture-repo","blocks":["fixture-slug-a"],"opened_ts":"${FIXTURE_DATE}T10:00:00Z","status":"open"}
{"id":"bbbb2222","repo":"fixture-repo","blocks":[],"opened_ts":"${FIXTURE_DATE}T11:00:00Z","closed_ts":"${FIXTURE_DATE}T12:00:00Z","status":"closed"}
{"id":"cccc3333","repo":"fixture-repo","blocks":["fixture-slug-b"],"opened_ts":"${FIXTURE_PREV_DATE}T09:00:00Z","closed_ts":"${FIXTURE_DATE}T13:00:00Z","status":"closed"}
EOF

# ---- branch-protection.json + gh stub -----------------------------------
BRANCH_PROT="$WORK/branch-protection.json"
cat > "$BRANCH_PROT" <<'EOF'
{"fixture-repo": {"owner": "fixtureowner"}}
EOF
GH_STUB="$WORK/gh-stub.sh"
cat > "$GH_STUB" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  echo '[{"number":42,"headRefName":"loop/fixture-slug-d","mergedAt":"${FIXTURE_DATE}T17:00:00Z"}]'
  exit 0
fi
exit 1
EOF
chmod +x "$GH_STUB"

# ---- journal dir + journalctl stub --------------------------------------
JOURNAL_DIR="$WORK/journal"
mkdir -p "$JOURNAL_DIR"
cat > "$JOURNAL_DIR/$FIXTURE_DATE.md" <<EOF
${FIXTURE_DATE}T10:05:00Z  chain: fixture-slug-a step 1 foo -> bar
${FIXTURE_DATE}T10:06:00Z  gate-then-land  fixture-slug-b  landed attempt=1
EOF
JOURNALCTL_STUB="$WORK/journalctl-stub.sh"
cat > "$JOURNALCTL_STUB" <<'EOF'
#!/usr/bin/env bash
echo "Starting claude-build.service - fixture tick 1"
echo "Finished claude-build.service - fixture tick 1"
echo "Starting claude-build.service - fixture tick 2"
echo "Finished claude-build.service - fixture tick 2"
EOF
chmod +x "$JOURNALCTL_STUB"

# ---- burst-lane + systemctl-show stubs -----------------------------------
BURST_STUB="$WORK/burst-lane-stub.sh"
cat > "$BURST_STUB" <<'EOF'
#!/usr/bin/env bash
echo "no active session"
EOF
chmod +x "$BURST_STUB"
SVCENV_STUB="$WORK/svcenv-stub.sh"
cat > "$SVCENV_STUB" <<'EOF'
#!/usr/bin/env bash
echo "HOME=/home/jsy PATH=/x BUILD_BURST_ENABLED=1 OTHER=2"
EOF
chmod +x "$SVCENV_STUB"

# ---- common env for every fixture-mode invocation ------------------------
common_env=(
  PRD_DIR="$PRD_DIR"
  GATE_RED_SUMMARY_FILE="$GATE_SUMMARY"
  GATES_BANNER_HOSTNAME="redbaron"
  DAY_LEDGER_DECISIONS_FILE="$DECISIONS"
  DAY_LEDGER_BRANCH_PROT_FILE="$BRANCH_PROT"
  DAY_LEDGER_GH_BIN="$GH_STUB"
  DAY_LEDGER_JOURNAL_DIR="$JOURNAL_DIR"
  DAY_LEDGER_JOURNALCTL_BIN="$JOURNALCTL_STUB"
  DAY_LEDGER_BURST_LANE_BIN="$BURST_STUB"
  DAY_LEDGER_SERVICE_ENV_BIN="$SVCENV_STUB"
  DAY_LEDGER_MANIFEST_FILE="$WORK/nonexistent-manifest.json"
  # PRD-build-flow-ledger req 4: point at a fixture path (not production
  # state/flow-ledger.jsonl) so AC2's determinism check can never flake on
  # a sibling PRD appending a real event between the two runs below.
  DAY_LEDGER_FLOW_LEDGER_FILE="$WORK/nonexistent-flow-ledger.jsonl"
  BUILD_JOURNAL_ROOT="$WORK/brain-journal"
  BUILD_STATE_DIR="$WORK/state"
)

run_dl() { env "${common_env[@]}" bash "$DL" "$@"; }

# ======================================================================
# AC1 — schema/types + fixture counts
# ======================================================================
AC1_OUT="$WORK/ac1.json"
if run_dl --date "$FIXTURE_DATE" --no-push --out "$AC1_OUT" >"$WORK/ac1.log" 2>&1; then
  ok "AC1: day-ledger.sh exits 0 on the fixture"
else
  bad "AC1: day-ledger.sh exited nonzero on the fixture ($(tail -1 "$WORK/ac1.log"))"
fi

check_schema() {
  local f="$1"
  "$JQ" -e '
    (.schema | type=="string") and (.date|type=="string") and (.tz|type=="string") and
    (.host|type=="string") and (.ticks.started|type=="number") and (.ticks.dispatched_prds|type=="array") and
    (.gates.green|type=="number") and (.gates.red|type=="number") and (.gates.red_slugs|type=="array") and
    (.shipped|type=="array") and (.landings|type=="array") and
    (.decisions.opened|type=="array") and (.decisions.closed|type=="array") and
    (.burst.box_exists|type=="boolean") and (.burst.routing_enabled|type=="boolean") and
    (.flow.prds_measured|type=="number") and
    (.flow.lead_time_p50_h|type=="number" or .flow.lead_time_p50_h==null) and
    (.flow.lead_time_p90_h|type=="number" or .flow.lead_time_p90_h==null) and
    (.flow.gate_wall_p50_s|type=="number" or .flow.gate_wall_p50_s==null) and
    (.flow.wait_p50_s|type=="number" or .flow.wait_p50_s==null) and
    (.notes|type=="array") and (.identifiers|type=="array") and
    (.produced_by|type=="string") and (.produced_at|type=="string") and
    (.sources_sha256|type=="object")
  ' "$f" >/dev/null 2>&1
}
if [ -f "$AC1_OUT" ] && check_schema "$AC1_OUT"; then
  ok "AC1: every key present with the right type"
else
  bad "AC1: schema check failed"
fi
[ -f "$AC1_OUT" ] && assert "AC1: schema" "$("$JQ" -r .schema "$AC1_OUT")" "build.day_ledger.v2"
[ -f "$AC1_OUT" ] && assert "AC1: flow.prds_measured (no fixture ledger)" "$("$JQ" -r .flow.prds_measured "$AC1_OUT")" "0"
[ -f "$AC1_OUT" ] && assert "AC1: ticks.started" "$("$JQ" -r .ticks.started "$AC1_OUT")" "2"
[ -f "$AC1_OUT" ] && assert "AC1: gates.red_slugs" "$("$JQ" -c -S .gates.red_slugs "$AC1_OUT")" '["fixture-slug-c"]'
[ -f "$AC1_OUT" ] && assert "AC1: shipped" "$("$JQ" -c -S '.shipped|sort' "$AC1_OUT")" '["fixture-slug-a","fixture-slug-b"]'
[ -f "$AC1_OUT" ] && assert "AC1: landings" "$("$JQ" -c -S '.landings' "$AC1_OUT")" '[{"pr":42,"repo":"fixture-repo","slug":"fixture-slug-d"}]'
[ -f "$AC1_OUT" ] && assert "AC1: decisions.opened count" "$("$JQ" '.decisions.opened|length' "$AC1_OUT")" "2"
[ -f "$AC1_OUT" ] && assert "AC1: decisions.closed count" "$("$JQ" '.decisions.closed|length' "$AC1_OUT")" "2"

# ======================================================================
# AC2 — determinism (two runs, byte-identical minus produced_at)
# ======================================================================
AC2_A="$WORK/ac2a.json"; AC2_B="$WORK/ac2b.json"
run_dl --date "$FIXTURE_DATE" --no-push --out "$AC2_A" >/dev/null 2>&1
run_dl --date "$FIXTURE_DATE" --no-push --out "$AC2_B" >/dev/null 2>&1
if diff -q <("$JQ" -S 'del(.produced_at)' "$AC2_A" 2>/dev/null) <("$JQ" -S 'del(.produced_at)' "$AC2_B" 2>/dev/null) >/dev/null 2>&1; then
  ok "AC2: two runs byte-identical except produced_at"
else
  bad "AC2: two runs differ beyond produced_at"
fi

# ======================================================================
# AC3 — missing sources degrade (decisions absent + gates banner failing)
# ======================================================================
BROKEN_GATES="$WORK/broken-gates-banner.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$BROKEN_GATES"
chmod +x "$BROKEN_GATES"
AC3_OUT="$WORK/ac3.json"
env "${common_env[@]}" DAY_LEDGER_DECISIONS_FILE="$WORK/nonexistent-decisions.jsonl" \
  DAY_LEDGER_GATES_BANNER_BIN="$BROKEN_GATES" \
  bash "$DL" --date "$FIXTURE_DATE" --no-push --out "$AC3_OUT" >"$WORK/ac3.log" 2>&1
rc=$?
assert "AC3: exit code" "$rc" "0"
if [ -f "$AC3_OUT" ]; then
  assert "AC3: decisions.opened empty" "$("$JQ" -c .decisions.opened "$AC3_OUT")" "[]"
  assert "AC3: decisions.closed empty" "$("$JQ" -c .decisions.closed "$AC3_OUT")" "[]"
  assert "AC3: gates empty form (green)" "$("$JQ" .gates.green "$AC3_OUT")" "0"
  assert "AC3: gates empty form (red_slugs)" "$("$JQ" -c .gates.red_slugs "$AC3_OUT")" "[]"
  if "$JQ" -e '.notes | index("source-missing: decisions")' "$AC3_OUT" >/dev/null 2>&1; then
    ok "AC3: notes has source-missing: decisions"
  else
    bad "AC3: notes missing source-missing: decisions"
  fi
  if "$JQ" -e '.notes | index("source-missing: gates")' "$AC3_OUT" >/dev/null 2>&1; then
    ok "AC3: notes has source-missing: gates"
  else
    bad "AC3: notes missing source-missing: gates"
  fi
  ok "AC3: file written despite missing sources"
else
  bad "AC3: no file written"
fi

# ======================================================================
# AC4 — identifier closure (positive on AC1's file) + secrets check
# ======================================================================
closure_check() {  # $1 = file; prints violations (one per line) to stdout
  local f="$1" content ids
  content="$("$JQ" -c 'del(.identifiers, .sources_sha256, .produced_at)' "$f" 2>/dev/null)"
  ids="$("$JQ" -r '.identifiers[]?' "$f" 2>/dev/null)"
  {
    printf '%s' "$content" | grep -oE 'redbaron|carbon|hub|casper|wm-apps|mcphost-1'
    printf '%s' "$content" | grep -oE '[0-9a-f]{7,40}'
    printf '%s' "$content" | grep -oE '#[0-9]+'
  } | sort -u | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    grep -qxF "$tok" <<<"$ids" || printf '%s\n' "$tok"
  done
}
secrets_check() {  # $1 = file; exit 0 if clean, 1 if a secret-shaped string is present
  ! grep -qE 'HCLOUD_TOKEN=|sk-[A-Za-z0-9]{10,}|[0-9a-f]{40}.*token' "$1" 2>/dev/null
}
if [ -f "$AC1_OUT" ]; then
  violations="$(closure_check "$AC1_OUT")"
  if [ -z "$violations" ]; then
    ok "AC4: identifier closure holds on AC1's fixture output"
  else
    bad "AC4: identifier closure violated on AC1's fixture output: $violations"
  fi
  if secrets_check "$AC1_OUT"; then
    ok "AC4: no secret-shaped string in AC1's fixture output"
  else
    bad "AC4: secret-shaped string found in AC1's fixture output"
  fi
fi

# ---- AC4/AC11 negative: inject a foreign identifier + a secret, confirm
# the checkers correctly name the violation (a detected FAIL here is the
# expected, PASSING outcome of this meta-assertion). ----------------------
TAMPERED="$WORK/ac4-tampered.json"
"$JQ" '.notes += ["saw-host deadbeef1 near #999 unlisted-token"]' "$AC1_OUT" > "$TAMPERED" 2>/dev/null
tampered_violations="$(closure_check "$TAMPERED")"
if [ -n "$tampered_violations" ]; then
  ok "AC4/AC11-neg: identifier-closure violation correctly detected (FAIL named: $tampered_violations)"
else
  bad "AC4/AC11-neg: closure checker failed to detect an injected foreign identifier"
fi
SECRET_INJECTED="$WORK/ac4-secret.json"
"$JQ" '.notes += ["leaked HCLOUD_TOKEN=abc123XYZ during fixture"]' "$AC1_OUT" > "$SECRET_INJECTED" 2>/dev/null
if ! secrets_check "$SECRET_INJECTED"; then
  ok "AC4/AC11-neg: secrets checker correctly detected an injected HCLOUD_TOKEN= string (FAIL named)"
else
  bad "AC4/AC11-neg: secrets checker failed to detect an injected token"
fi

# ======================================================================
# AC7 (negative, run before AC5 so a later git failure can't shadow it) —
# unwritable output dir -> exit 2, no partial file
# ======================================================================
RO="$WORK/readonly-parent"; mkdir -p "$RO"; chmod 500 "$RO"
AC7_OUT="$RO/sub/out.json"
run_dl --date "$FIXTURE_DATE" --no-push --out "$AC7_OUT" >"$WORK/ac7.log" 2>&1
rc=$?
assert "AC7: exit code" "$rc" "2"
if [ ! -e "$AC7_OUT" ]; then
  ok "AC7: no partial file written"
else
  bad "AC7: a partial file was written"
fi
chmod 700 "$RO"

# ======================================================================
# AC6 — date boundary from now, tz field
# ======================================================================
AC6_OUT="$WORK/ac6.json"
env "${common_env[@]}" DAY_LEDGER_NOW="${FIXTURE_DATE}T03:55:00Z" \
  bash "$DL" --no-push --out "$AC6_OUT" >"$WORK/ac6.log" 2>&1
if [ -f "$AC6_OUT" ]; then
  assert "AC6: date derives to the prior local day" "$("$JQ" -r .date "$AC6_OUT")" "$FIXTURE_PREV_DATE"
  assert "AC6: tz is America/New_York" "$("$JQ" -r .tz "$AC6_OUT")" "America/New_York"
else
  bad "AC6: no file written"
fi

# ======================================================================
# AC9 (P1) — --format text, <=10 lines, has red count/slugs/shipped/landings
# ======================================================================
AC9_TXT="$(run_dl --date "$FIXTURE_DATE" --no-push --format text 2>"$WORK/ac9.err")"
lines="$(printf '%s\n' "$AC9_TXT" | wc -l)"
if [ "$lines" -le 10 ]; then ok "AC9: text format <=10 lines ($lines)"; else bad "AC9: text format $lines lines (>10)"; fi
for want in "red=1" "fixture-slug-c" "shipped(2)" "fixture-repo#42"; do
  if grep -qF "$want" <<<"$AC9_TXT"; then
    ok "AC9: text format contains '$want'"
  else
    bad "AC9: text format missing '$want'"
  fi
done

# ======================================================================
# AC10 (P1) — operator-landed note (merged PR, no landing-pending line)
# ======================================================================
if [ -f "$AC1_OUT" ] && "$JQ" -e '.notes | index("operator-landed fixture-repo via pr #42")' "$AC1_OUT" >/dev/null 2>&1; then
  ok "AC10: operator-landed note present for the un-flagged merge"
else
  bad "AC10: operator-landed note missing"
fi

# ======================================================================
# AC5 — push paths: normal push / remote-ahead-by-one / push-refused
# ======================================================================
push_env=(
  "${common_env[@]}"
  PRD_DIR="$PRD_DIR"
)
env "${push_env[@]}" bash "$DL" --date "$FIXTURE_DATE" >"$WORK/ac5a.log" 2>&1
rc=$?
new_commit_msg="$(git -C "$ORIGIN" log -1 --pretty=%s 2>/dev/null)"
if [ "$rc" = "0" ] && [ "$new_commit_msg" = "day-ledger: $FIXTURE_DATE" ]; then
  ok "AC5a: normal push lands exactly one 'day-ledger: <date>' commit"
else
  bad "AC5a: expected commit 'day-ledger: $FIXTURE_DATE' at origin HEAD, got '$new_commit_msg' rc=$rc"
fi
changed_files="$(git -C "$ORIGIN" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null)"
assert "AC5a: commit touches only the day's ledger file" "$changed_files" "notes/day-ledger/$FIXTURE_DATE.json"

# AC5b: remote ahead by one unrelated commit -> rebase + push cleanly
SIBLING="$WORK/sibling-clone"
git clone -q "$ORIGIN" "$SIBLING"
git -C "$SIBLING" -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q --allow-empty -m "sibling: unrelated commit"
git -C "$SIBLING" push -q origin "$DEFAULT_BRANCH"
FIXTURE_DATE2="2030-06-16"
env "${push_env[@]}" bash "$DL" --date "$FIXTURE_DATE2" >"$WORK/ac5b.log" 2>&1
rc=$?
log2="$(git -C "$ORIGIN" log --oneline -3 2>/dev/null)"
if [ "$rc" = "0" ] && grep -q "day-ledger: $FIXTURE_DATE2" <<<"$log2" && grep -q "sibling: unrelated commit" <<<"$log2"; then
  ok "AC5b: rebased onto the sibling's commit and pushed cleanly"
else
  bad "AC5b: rebase+push after remote-ahead-by-one failed (rc=$rc log=$log2)"
fi

# AC5c: remote refuses push -> file exists locally, journal has
# 'day-ledger push-failed', exit 0
GIT_REFUSE="$WORK/git-refuse.sh"
cat > "$GIT_REFUSE" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "push" ] || { [ "$1" = "-C" ] && [ "$3" = "push" ]; }; then
  echo "fatal: refused (fixture)" >&2
  exit 1
fi
exec git "$@"
EOF
chmod +x "$GIT_REFUSE"
FIXTURE_DATE3="2030-06-17"
env "${push_env[@]}" DAY_LEDGER_GIT_BIN="$GIT_REFUSE" BUILD_JOURNAL_ROOT="$WORK/brain-journal" \
  bash "$DL" --date "$FIXTURE_DATE3" >"$WORK/ac5c.log" 2>&1
rc=$?
assert "AC5c: exit code on push refusal" "$rc" "0"
if [ -f "$PRD_DIR/notes/day-ledger/$FIXTURE_DATE3.json" ]; then
  ok "AC5c: file exists locally after a refused push"
else
  bad "AC5c: local file missing after a refused push"
fi
if grep -rq "day-ledger push-failed" "$WORK/brain-journal" 2>/dev/null; then
  ok "AC5c: journal has 'day-ledger push-failed'"
else
  bad "AC5c: journal missing 'day-ledger push-failed'"
fi

# ======================================================================
# Live phase (AC11): run once against the REAL sources for today, on the
# real host, against the real PRDs repo. No fixture overrides.
#
# Opt-in since 2026-09-18: DAY_LEDGER_SELFTEST_LIVE=1 runs this phase; it
# commits+pushes to the real PRDs repo, and a bare run on carbon on
# 2026-09-17 overwrote RedBaron's real day record with a stub (a0faa8f,
# restored in 6fe0eb3). The live phase also refuses to run off the build
# host unless DAY_LEDGER_SELFTEST_LIVE_ANY_HOST=1. The old
# DAY_LEDGER_SELFTEST_SKIP_LIVE=1 still skips. A skipped run is NOT a
# real AC11 pass.
# ======================================================================
if [ "${DAY_LEDGER_SELFTEST_SKIP_LIVE:-0}" = "1" ] || [ "${DAY_LEDGER_SELFTEST_LIVE:-0}" != "1" ]; then
  echo "---- live phase SKIPPED (set DAY_LEDGER_SELFTEST_LIVE=1 on the build host to run it) ----"
  echo "day-ledger-selftest: PASS=$PASS FAIL=$FAIL (live phase skipped — NOT a real AC11 pass)"
  if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
fi
if [ "$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')" != "redbaron" ] && [ "${DAY_LEDGER_SELFTEST_LIVE_ANY_HOST:-0}" != "1" ]; then
  echo "day-ledger-selftest: REFUSED live phase on $(hostname): it would push this host's stub over the build host's real record (set DAY_LEDGER_SELFTEST_LIVE_ANY_HOST=1 to override)" >&2
  exit 1
fi
echo "---- live phase (real sources, today) ----"
LIVE_OUT="$HOME/Documents/PRDs/notes/day-ledger/$(TZ=America/New_York date +%F).json"
if bash "$DL" >"$WORK/live.log" 2>&1; then
  ok "AC11-live: day-ledger.sh exited 0 against real sources"
else
  bad "AC11-live: day-ledger.sh exited nonzero against real sources ($(tail -3 "$WORK/live.log"))"
fi
if [ -f "$LIVE_OUT" ]; then
  ok "AC11-live: today's file exists under notes/day-ledger/"
else
  bad "AC11-live: today's file is missing at $LIVE_OUT"
fi
if [ -f "$LIVE_OUT" ]; then
  live_violations="$(closure_check "$LIVE_OUT")"
  if [ -z "$live_violations" ]; then
    ok "AC11-live: identifier closure holds on today's real file"
  else
    bad "AC11-live: identifier closure violated on today's real file: $live_violations"
  fi
  if secrets_check "$LIVE_OUT"; then
    ok "AC11-live: no secret-shaped string in today's real file"
  else
    bad "AC11-live: secret-shaped string found in today's real file"
  fi
  live_size="$(wc -c < "$LIVE_OUT")"
  if [ "$live_size" -le 8192 ]; then
    ok "AC11-live: today's file is <=8KB ($live_size bytes)"
  else
    bad "AC11-live: today's file is $live_size bytes (>8KB)"
  fi
fi

echo "----"
echo "day-ledger-selftest: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL $FAIL"
  printf '  - %s\n' "${fails[@]}"
  exit 1
fi
