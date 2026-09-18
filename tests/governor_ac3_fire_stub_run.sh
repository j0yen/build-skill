#!/usr/bin/env bash
# governor_ac3_fire_stub_run.sh —
# PRD-dream-depth-governor AC3: given all gates green in fixtures, when
# `dream-governor.sh run` executes with a stub dream command, then the
# stub runs under systemd-run, the lockfile exists during and is gone
# after, and the journal line carries all five gate values. Hermetic
# fixture, mirrors dream-governor-selftest.sh's AC3 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac3.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state/dream-governor" "$t/ledger" "$t/journal-dir"
git -C "$t/prds" init -q
git -C "$t/prds" config user.email test@example.com
git -C "$t/prds" config user.name "Test"
: > "$t/prds/.gitkeep"
git -C "$t/prds" add .gitkeep
git -C "$t/prds" commit -q -m init

printf 'DEPTH_MIN=8\nHEADROOM_MAX=500000\n' > "$t/state/dream-governor/config"
for i in 1 2; do
  printf '# PRD: fixture-q%s\n\n- Status: queued\n' "$i" > "$t/prds/build-queue/PRD-fixture-q$i.md"
done
cat > "$t/prds/seeds/2026-09-15-green-seed.md" <<EOF
- Source: manual
- Observed: 2026-09-15
- Status: pending
- Fingerprint: deadbeefdeadbeef

An observation.
EOF
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n' > "$t/ledger/ledger.tsv"
printf '%s\t{}\t1000\tok\t1\t1\t0\t%s\n' "$(date -u +%F)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$t/ledger/ledger.tsv"

stub="$t/stub-sleep.sh"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
sleep 3
exit 0
EOF
chmod +x "$stub"

DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$t/state/dream-governor/run.lock" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  DREAM_GOVERNOR_DREAM_CMD="$stub" \
  DREAM_GOVERNOR_TIMEOUT_S=30 \
  "$DG" run > "$t/run.out" 2>"$t/run.err" &
bgpid=$!

lock_during="absent"
for _ in $(seq 1 40); do
  if [ -e "$t/state/dream-governor/run.lock" ]; then lock_during="present"; break; fi
  sleep 0.1
done
wait "$bgpid"

fail=0
out="$(cat "$t/run.out")"
if [ "$out" != "fire" ]; then
  echo "FAIL AC3: expected fire, got: $out (stderr: $(cat "$t/run.err"))"
  fail=1
fi
if [ "$lock_during" != "present" ]; then
  echo "FAIL AC3: lockfile never observed present during the run"
  fail=1
fi
if [ -e "$t/state/dream-governor/run.lock" ]; then
  echo "FAIL AC3: lockfile still present post-run"
  fail=1
fi
jline="$(tail -1 "$t/journal-dir/dream-governor.log" 2>/dev/null)"
if ! printf '%s' "$jline" | grep -qE "depth=[0-9]+ seeds=[0-9]+ headroom=(no-data|[0-9]+) lock=(free|held) config=(present|absent)"; then
  echo "FAIL AC3: journal line missing a gate value -- $jline"
  fail=1
fi
if ! printf '%s' "$jline" | grep -q "  run  fire  "; then
  echo "FAIL AC3: journal line does not record fire under run -- $jline"
  fail=1
fi
[ "$fail" -eq 0 ] && echo "ok  AC3: fire under systemd-run, lockfile present during/absent after, journal carries all five gate values"
exit "$fail"
