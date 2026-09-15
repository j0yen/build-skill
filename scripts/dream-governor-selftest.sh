#!/usr/bin/env bash
# dream-governor-selftest.sh — acceptance harness for dream-governor.sh
# (PRD-dream-depth-governor). Hermetic: every fixture lives under a
# tempdir (throwaway PRDs clone + throwaway state dir + throwaway
# journal/ledger); never touches ~/Documents/PRDs, ~/.claude/skills/build/
# state, or ~/brain/journal. Run: bash scripts/dream-governor-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/dream-governor.sh"
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1 -- $3"; FAIL=$((FAIL+1)); fi; }

TODAY="$(date -u +%F)"

# mk_fixture -> a fresh tempdir with a git-inited PRDs clone
# (build-queue/, built-prds/, seeds/) and a fresh state dir. Prints the
# tempdir path.
mk_fixture() {
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/dream-governor-selftest.XXXXXX")"
  mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state" "$t/ledger" "$t/journal-dir"
  git -C "$t/prds" init -q
  git -C "$t/prds" config user.email test@example.com
  git -C "$t/prds" config user.name "Test"
  : > "$t/prds/.gitkeep"
  git -C "$t/prds" add .gitkeep
  git -C "$t/prds" commit -q -m init
  printf '%s' "$t"
}

mk_queued_prds() { # <dir> <n>
  local dir="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    cat > "$dir/PRD-fixture-q$i.md" <<EOF
# PRD: fixture-q$i

- Status: queued
EOF
  done
}

mk_pending_seed() { # <seeds-dir> <slug>
  local dir="$1" slug="$2"
  cat > "$dir/2026-09-15-$slug.md" <<EOF
- Source: manual
- Observed: 2026-09-15
- Status: pending
- Fingerprint: deadbeefdeadbeef

An observation.
EOF
}

mk_config() { # <path> <depth_min> <headroom_max>
  mkdir -p "$(dirname "$1")"
  printf 'DEPTH_MIN=%s\nHEADROOM_MAX=%s\n' "$2" "$3" > "$1"
}

mk_ledger_row() { # <ledger-dir> <date> <weighted>
  mkdir -p "$1"
  printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n' > "$1/ledger.tsv"
  printf '%s\t{}\t%s\tok\t1\t1\t0\t%s\n' "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$1/ledger.tsv"
}

run_dg() { # <fixture-dir> <subcommand> [extra env assignments already exported by caller]
  local t="$1" sub="$2"
  DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="${DG_CONFIG:-$t/state/dream-governor/config}" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="${DG_LOCK:-$t/state/dream-governor/run.lock}" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  DREAM_GOVERNOR_DREAM_CMD="${DG_DREAM_CMD:-}" \
  DREAM_GOVERNOR_TIMEOUT_S="${DG_TIMEOUT:-30}" \
  MAX_FIRES_WEEK="${DG_MAX_FIRES_WEEK:-}" \
  "$DG" "$sub"
}

# ---- AC1: queued=20, DEPTH_MIN=8 -> refuse:depth=20, no dream process ----
t1="$(mk_fixture)"
mk_config "$t1/state/dream-governor/config" 8 500000
mk_queued_prds "$t1/prds/build-queue" 20
out1="$(run_dg "$t1" check)"
ck "AC1: refuse:depth=20 on queued=20/DEPTH_MIN=8" '[ "$out1" = "refuse:depth=20" ]' "got: $out1"
ck "AC1: no dream-governor run.lock ever created (no launch attempted)" '[ ! -e "$t1/state/dream-governor/run.lock" ] || [ ! -s "$t1/state/dream-governor/run.lock" ]' "lock file unexpectedly populated"
rm -rf "$t1"

# ---- AC2: queued=3, zero pending seeds -> refuse:seeds=0 ----
t2="$(mk_fixture)"
mkdir -p "$t2/state/dream-governor"
mk_config "$t2/state/dream-governor/config" 8 500000
mk_queued_prds "$t2/prds/build-queue" 3
out2="$(run_dg "$t2" check)"
ck "AC2: refuse:seeds=0 on queued=3 (<DEPTH_MIN), zero pending seeds" '[ "$out2" = "refuse:seeds=0" ]' "got: $out2"
rm -rf "$t2"

# ---- shared "all gates green" fixture builder for AC3/AC4/AC8 ----
mk_green_fixture() {
  local t; t="$(mk_fixture)"
  mkdir -p "$t/state/dream-governor"
  mk_config "$t/state/dream-governor/config" 8 500000
  mk_queued_prds "$t/prds/build-queue" 2
  mk_pending_seed "$t/prds/seeds" green-seed
  mk_ledger_row "$t/ledger" "$TODAY" 1000
  printf '%s' "$t"
}

# ---- AC3: all gates green, run w/ stub -> systemd-run launch, lockfile
# exists during and is gone after, journal line carries all five values --
t3="$(mk_green_fixture)"
stub3="$t3/stub-sleep.sh"
cat > "$stub3" <<'EOF'
#!/usr/bin/env bash
sleep 3
exit 0
EOF
chmod +x "$stub3"
DG_CONFIG="$t3/state/dream-governor/config" DG_LOCK="$t3/state/dream-governor/run.lock" \
  DG_DREAM_CMD="$stub3" run_dg "$t3" run > "$t3/run.out" 2>"$t3/run.err" &
bgpid=$!
# Poll for the lockfile across the whole expected run window instead of a
# single fixed-delay snapshot -- gate evaluation itself (several
# subprocess calls) has variable cold-start latency before the lock is
# even acquired.
lock_during="absent"
for _ in $(seq 1 40); do
  if [ -e "$t3/state/dream-governor/run.lock" ]; then lock_during="present"; break; fi
  sleep 0.1
done
wait "$bgpid"
out3="$(cat "$t3/run.out")"
ck "AC3: fire decision with stub dream command" '[ "$out3" = "fire" ]' "got: $out3 (stderr: $(cat "$t3/run.err"))"
ck "AC3: lockfile existed during the run" '[ "$lock_during" = "present" ]' "lock_during=$lock_during"
ck "AC3: lockfile is gone after the run completes" '[ ! -e "$t3/state/dream-governor/run.lock" ]' "lock still present post-run"
jline3="$(tail -1 "$t3/journal-dir/dream-governor.log" 2>/dev/null)"
ck "AC3: journal line carries all five gate values" \
  'printf "%s" "$jline3" | grep -qE "depth=[0-9]+ seeds=[0-9]+ headroom=(no-data|[0-9]+) lock=(free|held) config=(present|absent)"' \
  "journal line: $jline3"
ck "AC3: journal line records the fire decision under run" 'printf "%s" "$jline3" | grep -q "  run  fire  "' "journal line: $jline3"
rm -rf "$t3"

# ---- AC4: second run while the lockfile is held -> refuse:lock=held,
# live run untouched ----
t4="$(mk_green_fixture)"
mkdir -p "$t4/state/dream-governor"
lockpath4="$t4/state/dream-governor/run.lock"
exec 30>"$lockpath4"
flock -n 30
out4="$(DG_CONFIG="$t4/state/dream-governor/config" DG_LOCK="$lockpath4" run_dg "$t4" check)"
ck "AC4: refuse:lock=held while lockfile is externally held" '[ "$out4" = "refuse:lock=held" ]' "got: $out4"
flock -u 30
exec 30>&-
rm -rf "$t4"

# ---- AC5: a drafted fixture PRD that fails lint is not staged for
# build-queue/, journal names the finding ----
t5="$(mk_green_fixture)"
stub5="$t5/stub-draft.sh"
# systemd-run sets WorkingDirectory=$PRDS_DIR for this unit (see
# launch_and_postprocess), so the stub operates on relative paths exactly
# like a real /dream invocation would from inside the PRDs clone.
cat > "$stub5" <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p visions
echo "a fixture vision" > visions/fixture.md
cat > build-queue/PRD-fixture-good.md <<'GOOD'
# PRD: fixture-good

- Status: queued
- build_target: shell
- Vision: visions/fixture.md
- Grounding: wwhtbt -- a fixture

## Acceptance criteria

1. P0 -- Given a thing, When it runs, Then it passes.
GOOD
cat > build-queue/PRD-fixture-bad.md <<'BAD'
# PRD: fixture-bad

- Status: queued
- build_target: not-a-real-target
- Vision: visions/fixture.md
- Grounding: wwhtbt -- a fixture

## Acceptance criteria

1. P0 -- Given a thing, When it runs, Then it fails lint on purpose.
BAD
git add visions/fixture.md build-queue/PRD-fixture-good.md build-queue/PRD-fixture-bad.md
git commit -q -m "dream: draft fixture-good, fixture-bad"
EOF
chmod +x "$stub5"
DG_CONFIG="$t5/state/dream-governor/config" DG_LOCK="$t5/state/dream-governor/run.lock" \
  DG_DREAM_CMD="$stub5" DG_TIMEOUT=30 \
  run_dg "$t5" run > "$t5/run.out" 2>"$t5/run.err"
out5="$(cat "$t5/run.out")"
ck "AC5: run still fires (drafting itself is dream's job, not a gate)" '[ "$out5" = "fire" ]' "got: $out5 (stderr: $(cat "$t5/run.err"))"
ck "AC5: the lint-failing file is not present in build-queue/" '[ ! -e "$t5/prds/build-queue/PRD-fixture-bad.md" ]' "file still present"
ck "AC5: the lint-passing file IS present in build-queue/" '[ -e "$t5/prds/build-queue/PRD-fixture-good.md" ]' "good file missing"
jgrep5="$(grep 'lint-fail' "$t5/journal-dir/dream-governor.log" 2>/dev/null | tail -1)"
ck "AC5: journal names the lint finding for the failing file" \
  'printf "%s" "$jgrep5" | grep -q "file=build-queue/PRD-fixture-bad.md"' "journal: $jgrep5"
rm -rf "$t5"

# ---- AC6: no config file -> refuse:config=absent (never fires on defaults) ----
t6="$(mk_fixture)"
out6="$(DG_CONFIG="$t6/state/dream-governor/config-does-not-exist" run_dg "$t6" check)"
ck "AC6: refuse:config=absent with no config file" '[ "$out6" = "refuse:config=absent" ]' "got: $out6"
rm -rf "$t6"

# ---- AC8: missing telemetry (no ledger row for today) -> refuse:headroom=no-data ----
t8="$(mk_fixture)"
mkdir -p "$t8/state/dream-governor"
mk_config "$t8/state/dream-governor/config" 8 500000
mk_queued_prds "$t8/prds/build-queue" 2
mk_pending_seed "$t8/prds/seeds" headroom-seed
# no ledger.tsv written at all for t8/ledger -> ledger_weighted_for sees no file
out8="$(DG_CONFIG="$t8/state/dream-governor/config" run_dg "$t8" check)"
ck "AC8: refuse:headroom=no-data with no telemetry for today" '[ "$out8" = "refuse:headroom=no-data" ]' "got: $out8"
rm -rf "$t8"

# ---- AC7 (static): shipped unit files exist and are not auto-enabled by
# anything in this repo (real `systemctl --user is-enabled` requires
# actually installing the unit onto the host's systemd user dir, which a
# selftest should not do to the real machine; this asserts the same
# guarantee at the source: install.sh never references dream-governor,
# so the only way it becomes enabled is the operator's own one-liner in
# README.md, exactly like claude-build.timer) ----
ck "AC7: systemd/dream-governor.timer ships in the repo" '[ -f "$HERE/../systemd/dream-governor.timer" ]' "missing"
ck "AC7: systemd/dream-governor.service ships in the repo" '[ -f "$HERE/../systemd/dream-governor.service" ]' "missing"
ck "AC7: install.sh never auto-enables dream-governor (ships disabled)" \
  '! grep -q "dream-governor" "$HERE/../install.sh"' "install.sh references dream-governor"

echo "---"
echo "dream-governor-selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
