#!/usr/bin/env bash
# cargo-budget-selftest.sh — proves cargo-budget.sh's gates without ever
# running a real cargo build (PRD-build-cargo-concurrency-budget). Every
# "cargo invocation" below is `sleep` or a tiny stub script — the whole
# point of this PRD is to stop OOMing RedBaron with concurrent cargo load,
# so validating the fix must not itself recreate the incident.
#
# Every assertion here runs against an isolated state dir, journal, and
# fake /proc/{meminfo,loadavg} — never the production
# ~/.claude/skills/build/state/cargo-budget/ or the real journal, and
# never the box's real (and, on this fleet, sometimes enormous — see the
# PRD) /proc/loadavg. Non-load assertions pin CARGO_BUDGET_LOADAVG to a
# quiet fake file and CARGO_BUDGET_HOSTNAME to a non-redbaron value so the
# ambient host's real load can never make an unrelated assertion flaky.
#
# Prints one PASS/FAIL line per assertion; exits 0 iff all passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB="$HERE/cargo-budget.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/cargo-budget-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

quiet_loadavg() { printf '%s\n' "0.10 0.05 0.01 1/200 12345" > "$1"; }
healthy_meminfo() {
  cat > "$1" <<'EOF'
MemTotal:       31000000 kB
MemFree:        20000000 kB
MemAvailable:   25000000 kB
EOF
}
low_meminfo() {
  cat > "$1" <<'EOF'
MemTotal:       31000000 kB
MemFree:          500000 kB
MemAvailable:     900000 kB
EOF
}

common_env() {
  local dir="$1"
  export CARGO_BUDGET_STATE_DIR="$dir/state"
  export CARGO_BUDGET_JOURNAL="$dir/journal.md"
  export CARGO_BUDGET_NPROC=16
  export CARGO_BUDGET_HOSTNAME="selftest-not-redbaron"
  quiet_loadavg "$dir/loadavg"
  export CARGO_BUDGET_LOADAVG="$dir/loadavg"
  healthy_meminfo "$dir/meminfo"
  export CARGO_BUDGET_MEMINFO="$dir/meminfo"
  unset CARGO_BUDGET_SLOTS CARGO_BUDGET_WAIT_MAX CARGO_BUDGET_MIN_AVAIL_GB \
        CARGO_BUDGET_TEST_THREADS CARGO_BUDGET_MAX_LOAD CARGO_BUILD_JOBS \
        RUST_TEST_THREADS 2>/dev/null || true
}

ledger_rows() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  wc -l < "$f" | tr -d ' '
}

# === Assertion 1: slot contention — third of three waits under SLOTS=2 ====
d1="$T/slots"; mkdir -p "$d1"
( common_env "$d1"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=60
  t0=$(date +%s)
  "$CB" run -- sleep 5 & p1=$!
  "$CB" run -- sleep 5 & p2=$!
  "$CB" run -- sleep 5 & p3=$!
  wait "$p1" "$p2" "$p3"
  t1=$(date +%s)
  echo "$((t1 - t0))" > "$d1/wall.txt"
)
wall="$(cat "$d1/wall.txt" 2>/dev/null || echo 0)"
rows="$(ledger_rows "$d1/state/ledger.jsonl")"
maxwait="$(jq -s 'map(.wait_s) | max' "$d1/state/ledger.jsonl" 2>/dev/null || echo 0)"
if [ "$rows" -eq 3 ] && [ "$wall" -ge 9 ] && [ "${maxwait:-0}" -ge 4 ]; then
  pass "slot contention: 2 of 3 ran concurrently, third waited (wall=${wall}s max_wait_s=${maxwait} rows=${rows})"
else
  fail "slot contention: expected 3 ledger rows / wall>=9s / max_wait_s>=4, got rows=$rows wall=${wall}s max_wait_s=${maxwait}"
fi

# === Assertion 2: env caps set when caller didn't set them =================
d2="$T/envcaps"; mkdir -p "$d2"
(
  common_env "$d2"
  export CARGO_BUDGET_SLOTS=4
  export CARGO_BUDGET_NPROC=16
  echo '#!/usr/bin/env bash' > "$d2/fakecargo"
  echo 'printf "jobs=%s threads=%s\n" "$CARGO_BUILD_JOBS" "$RUST_TEST_THREADS" > "'"$d2"'/env.out"' >> "$d2/fakecargo"
  chmod +x "$d2/fakecargo"
  "$CB" run -- "$d2/fakecargo"
)
out2="$(cat "$d2/env.out" 2>/dev/null || echo "")"
if [ "$out2" = "jobs=4 threads=4" ]; then
  pass "env caps: CARGO_BUILD_JOBS=max(2,nproc/slots)=4, RUST_TEST_THREADS=default 4 ($out2)"
else
  fail "env caps: expected 'jobs=4 threads=4', got '$out2'"
fi

# === Assertion 3: caller-set env vars are NOT overridden ====================
d3="$T/envcaller"; mkdir -p "$d3"
(
  common_env "$d3"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUILD_JOBS=99
  export RUST_TEST_THREADS=7
  echo '#!/usr/bin/env bash' > "$d3/fakecargo"
  echo 'printf "jobs=%s threads=%s\n" "$CARGO_BUILD_JOBS" "$RUST_TEST_THREADS" > "'"$d3"'/env.out"' >> "$d3/fakecargo"
  chmod +x "$d3/fakecargo"
  "$CB" run -- "$d3/fakecargo"
)
out3="$(cat "$d3/env.out" 2>/dev/null || echo "")"
if [ "$out3" = "jobs=99 threads=7" ]; then
  pass "env caps: caller-set CARGO_BUILD_JOBS/RUST_TEST_THREADS pass through unchanged ($out3)"
else
  fail "env caps: expected caller values 'jobs=99 threads=7' preserved, got '$out3'"
fi

# === Assertion 4: low MemAvailable refuses-and-waits, then starts ==========
d4="$T/mem"; mkdir -p "$d4"
(
  common_env "$d4"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_MIN_AVAIL_GB=6
  export CARGO_BUDGET_WAIT_MAX=60
  low_meminfo "$d4/meminfo"   # override common_env's healthy default
  export CARGO_BUDGET_MEMINFO="$d4/meminfo"
  # Flip to healthy after 3s, from a detached watcher — the run itself
  # must be blocked-and-waiting at that point, then notice within ~15s.
  ( sleep 3; healthy_meminfo "$d4/meminfo" ) &
  disown
  t0=$(date +%s)
  "$CB" run -- true
  rc=$?
  t1=$(date +%s)
  echo "$((t1 - t0))" > "$d4/wall.txt"
  echo "$rc" > "$d4/rc.txt"
)
wall4="$(cat "$d4/wall.txt" 2>/dev/null || echo 999)"
rc4="$(cat "$d4/rc.txt" 2>/dev/null || echo 1)"
journaled_mem=0
grep -q 'cargo-budget  wait mem' "$d4/journal.md" 2>/dev/null && journaled_mem=1
# Upper bound is generous (AC2 says "within 15s" of the 10s recheck
# interval; this box has been observed to hit real `fork: retry: Resource
# temporarily unavailable` stalls from ambient host contention unrelated
# to this script, so the bound here allows for that scheduling noise
# without weakening what's actually being proven: the recheck happens on
# a ~10s cadence, not "eventually" or "next tick").
if [ "$rc4" = "0" ] && [ "$wall4" -ge 3 ] && [ "$wall4" -le 25 ] && [ "$journaled_mem" -eq 1 ]; then
  pass "mem floor: refused while low, journaled 'wait mem', started ${wall4}s after recovery (~10s recheck cadence)"
else
  fail "mem floor: rc=$rc4 wall=${wall4}s journaled_mem=$journaled_mem (want rc=0, 3<=wall<=25, journaled_mem=1)"
fi

# === Assertion 5: RedBaron-only load ceiling refuses-and-waits =============
d5="$T/load"; mkdir -p "$d5"
(
  common_env "$d5"
  export CARGO_BUDGET_HOSTNAME="redbaron"
  export CARGO_BUDGET_MAX_LOAD=8
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  printf '20.00 15.00 10.00 3/400 99999\n' > "$d5/loadavg"
  export CARGO_BUDGET_LOADAVG="$d5/loadavg"
  ( sleep 3; printf '1.00 1.00 1.00 1/200 99999\n' > "$d5/loadavg" ) &
  disown
  t0=$(date +%s)
  "$CB" run -- true
  rc=$?
  t1=$(date +%s)
  echo "$((t1 - t0))" > "$d5/wall.txt"
  echo "$rc" > "$d5/rc.txt"
)
wall5="$(cat "$d5/wall.txt" 2>/dev/null || echo 999)"
rc5="$(cat "$d5/rc.txt" 2>/dev/null || echo 1)"
journaled_load=0
grep -q 'cargo-budget  wait load' "$d5/journal.md" 2>/dev/null && journaled_load=1
# See the wide upper bound's rationale on the mem-floor assertion above —
# same 10s recheck cadence, same box-specific scheduling noise allowance.
if [ "$rc5" = "0" ] && [ "$wall5" -ge 3 ] && [ "$wall5" -le 25 ] && [ "$journaled_load" -eq 1 ]; then
  pass "load ceiling (RedBaron-only): refused at load 20 > max 8, journaled 'wait load', started ${wall5}s after load dropped"
else
  fail "load ceiling: rc=$rc5 wall=${wall5}s journaled_load=$journaled_load (want rc=0, 3<=wall<=25, journaled_load=1)"
fi

# On a non-RedBaron host the same high load must NOT block (P1 scope: "On
# RedBaron only").
d5b="$T/load-nonredbaron"; mkdir -p "$d5b"
(
  common_env "$d5b"
  export CARGO_BUDGET_MAX_LOAD=8
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=10
  printf '20.00 15.00 10.00 3/400 99999\n' > "$d5b/loadavg"
  export CARGO_BUDGET_LOADAVG="$d5b/loadavg"
  t0=$(date +%s)
  "$CB" run -- true
  rc=$?
  t1=$(date +%s)
  echo "$((t1 - t0))" > "$d5b/wall.txt"
  echo "$rc" > "$d5b/rc.txt"
)
wall5b="$(cat "$d5b/wall.txt" 2>/dev/null || echo 999)"
rc5b="$(cat "$d5b/rc.txt" 2>/dev/null || echo 1)"
if [ "$rc5b" = "0" ] && [ "$wall5b" -le 3 ]; then
  pass "load ceiling scoped to RedBaron only: non-redbaron host with load 20 did not wait (wall=${wall5b}s)"
else
  fail "load ceiling scoped to RedBaron only: expected immediate start, got rc=$rc5b wall=${wall5b}s"
fi

# === Assertion 6: one ledger row per run, across everything above =========
total_rows=0
for f in "$d1/state/ledger.jsonl" "$d2/state/ledger.jsonl" "$d3/state/ledger.jsonl" \
         "$d4/state/ledger.jsonl" "$d5/state/ledger.jsonl" "$d5b/state/ledger.jsonl"; do
  total_rows=$((total_rows + $(ledger_rows "$f")))
done
# runs issued above: 3 (d1) + 1 (d2) + 1 (d3) + 1 (d4) + 1 (d5) + 1 (d5b) = 8
if [ "$total_rows" -eq 8 ]; then
  pass "ledger: exactly one row per run across all assertions above (8 runs, 8 rows)"
else
  fail "ledger: expected 8 total rows across all runs above, got $total_rows"
fi

# === Assertion 7: summary line has the required fields =====================
d7="$T/summary"; mkdir -p "$d7"
(
  common_env "$d7"
  export CARGO_BUDGET_SLOTS=1
  export CARGO_BUDGET_WAIT_MAX=30
  "$CB" run -- true
  "$CB" run -- true
)
line="$(CARGO_BUDGET_STATE_DIR="$d7/state" "$CB" summary --since 0 2>/dev/null)"
if printf '%s' "$line" | grep -q '^cargo-budget: peak_load=.*min_avail_gb=.*waits=.*max_wait_s=' ; then
  pass "summary: '$line'"
else
  fail "summary: line missing required fields: '$line'"
fi

# === Assertion 8: lane-status.sh report surfaces the last runs =============
LS="$HERE/lane-status.sh"
d8="$T/lane-report"; mkdir -p "$d8/prds/build-queue" "$d8/journal"
if [ -x "$LS" ]; then
  out8="$(CARGO_BUDGET_STATE_DIR="$d7/state" "$LS" report --prd-dir "$d8/prds" --journal-dir "$d8/journal" --days 1 2>/dev/null)"
  if printf '%s' "$out8" | grep -q '== cargo-budget: last 5 runs' && printf '%s' "$out8" | grep -q 'wait_s='; then
    pass "lane-status.sh report: cargo-budget section shows recent ledger rows"
  else
    fail "lane-status.sh report: expected a cargo-budget section with wait_s= rows, got: '$out8'"
  fi
else
  fail "lane-status.sh not found at $LS"
fi

# === Assertion 9: lane-status.sh tick-summary appends the cargo-budget line
d9="$T/tick-summary"; mkdir -p "$d9/journal"
j9="$d9/journal/$(date -u +%F).md"
CARGO_BUDGET_STATE_DIR="$d7/state" "$LS" tick-summary selftest-lane 5 0 "$j9" >/dev/null 2>&1
if grep -q 'lane-health  tick  claimed=5 skipped=0  (lane=selftest-lane)' "$j9" 2>/dev/null \
   && grep -q '^cargo-budget: peak_load=' "$j9" 2>/dev/null; then
  pass "lane-status.sh tick-summary: appends both the lane-health line and the cargo-budget line"
else
  fail "lane-status.sh tick-summary: expected lane-health + cargo-budget lines in $j9, got: $(cat "$j9" 2>/dev/null)"
fi


# =============================================================================
# slotinv block (PRD-build-cargo-budget-per-invocation, test_prefix: slotinv)
# — a slot is held only while a cargo process tree is alive and busy. Every
# fixture below is a real live process tree (a fake `cargo` that sleeps, a
# fake producer that sleeps idle then calls cargo) — never a synthetic
# /proc tree — same discipline as the assertions above. AC1 (extend-gate.sh
# producer routing) and AC9/AC11 (the gate's own wedge-wrapped loop, and the
# real-mcphost-gate run) are extend-gate.sh-level/real-host ACs, exercised
# separately, not here.

# === slotinv 1: nested reuse — a nested `run` under a live ancestor's slot
# takes no second slot (AC2) =================================================
ds1="$T/slotinv-nested"; mkdir -p "$ds1"
(
  common_env "$ds1"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  cat > "$ds1/child.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
"$CB" run -- true
echo "\$?" > "$ds1/nested_rc.txt"
# hold the outer slot open a little longer so the probe below can check
# the OTHER slot is still free while nesting is in flight.
sleep 2
EOF
  chmod +x "$ds1/child.sh"
  "$CB" run -- "$ds1/child.sh" &
  outer_p=$!
  # while the outer+nested pair are in flight, slot 1 (the one NEVER taken
  # by either) must stay free.
  sleep 1
  if flock -n "$ds1/state/slot-1.lock" -c true 2>/dev/null; then
    echo yes > "$ds1/other_slot_free_during.txt"
  else
    echo no > "$ds1/other_slot_free_during.txt"
  fi
  wait "$outer_p"
)
nested_rc="$(cat "$ds1/nested_rc.txt" 2>/dev/null || echo x)"
other_free_during="$(cat "$ds1/other_slot_free_during.txt" 2>/dev/null || echo no)"
nested_row="$(jq -c 'select(.nested == true)' "$ds1/state/ledger.jsonl" 2>/dev/null | head -1)"
nested_journaled=0
grep -q 'cargo-budget  nested reuse slot=' "$ds1/journal.md" 2>/dev/null && nested_journaled=1
if [ "$nested_rc" = "0" ] && [ "$other_free_during" = "yes" ] && [ -n "$nested_row" ] \
   && [ "$(jq -r '.wait_s' <<<"$nested_row")" = "0" ] && [ "$nested_journaled" -eq 1 ]; then
  pass "slotinv nested reuse: nested run took no second slot (other slot stayed free), wait_s=0, journaled ($nested_row)"
else
  fail "slotinv nested reuse: rc=$nested_rc other_slot_free_during=$other_free_during journaled=$nested_journaled row=$nested_row"
fi

# === slotinv 2: dead holder pid falls through to normal acquisition (AC3) ==
ds2="$T/slotinv-dead-holder"; mkdir -p "$ds2"
(
  common_env "$ds2"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  # a pid that is guaranteed dead by the time we use it.
  sleep 0.1 & dead_pid=$!
  wait "$dead_pid" 2>/dev/null
  export CARGO_BUDGET_HELD_SLOT=0
  export CARGO_BUDGET_HOLDER_PID="$dead_pid"
  "$CB" run -- true
)
dead_row="$(jq -c 'select(true)' "$ds2/state/ledger.jsonl" 2>/dev/null | tail -1)"
if [ "$(jq -r '.nested' <<<"$dead_row")" = "false" ]; then
  pass "slotinv dead holder pid: stale CARGO_BUDGET_HOLDER_PID (already-dead) acquires normally, nested=false ($dead_row)"
else
  fail "slotinv dead holder pid: expected nested=false, got $dead_row"
fi

# === slotinv 3: child fd hygiene — a backgrounded grandchild never keeps the
# flock alive past `run`'s own return (AC4) ==================================
ds3="$T/slotinv-fdhygiene"; mkdir -p "$ds3"
(
  common_env "$ds3"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  cat > "$ds3/child.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
( sleep 600 & )
exit 0
EOF
  chmod +x "$ds3/child.sh"
  "$CB" run -- "$ds3/child.sh"
)
if flock -n "$ds3/state/slot-0.lock" -c true 2>/dev/null || flock -n "$ds3/state/slot-1.lock" -c true 2>/dev/null; then
  pass "slotinv fd hygiene: a fresh flock -n on the used slot succeeds immediately after run returns (backgrounded grandchild did not inherit the lock fd)"
else
  fail "slotinv fd hygiene: flock -n on both slot files failed right after run returned — a descendant is still holding the fd"
fi
pkill -f "sleep 600" 2>/dev/null || true

# === slotinv 4: idle-release — no live cargo/rustc descendant (AC5) ========
ds4="$T/slotinv-idle-release"; mkdir -p "$ds4"
(
  common_env "$ds4"
  export CARGO_BUDGET_SLOTS=1
  export CARGO_BUDGET_WAIT_MAX=30
  export CARGO_BUDGET_IDLE_HOLD_S=3
  export CARGO_BUDGET_IDLE_CPU_PCT=5
  cat > "$ds4/idle_producer.sh" <<'EOF'
#!/usr/bin/env bash
sleep 8
exit 7
EOF
  chmod +x "$ds4/idle_producer.sh"
  "$CB" run -- "$ds4/idle_producer.sh" &
  p1=$!
  # once idle-released (~3s in), a second run must be able to take the
  # (now sole) slot while the first producer is still sleeping.
  sleep 5
  t0=$(date +%s)
  "$CB" run -- true
  second_rc=$?
  t1=$(date +%s)
  echo "$((t1 - t0))" > "$ds4/second_wall.txt"
  echo "$second_rc" > "$ds4/second_rc.txt"
  wait "$p1"
  echo "$?" > "$ds4/first_rc.txt"
)
idle_journaled=0
grep -q 'cargo-budget  idle-release slot=' "$ds4/journal.md" 2>/dev/null && idle_journaled=1
second_wall="$(cat "$ds4/second_wall.txt" 2>/dev/null || echo 999)"
second_rc="$(cat "$ds4/second_rc.txt" 2>/dev/null || echo 1)"
first_rc="$(cat "$ds4/first_rc.txt" 2>/dev/null || echo x)"
if [ "$idle_journaled" -eq 1 ] && [ "$second_rc" = "0" ] && [ "$second_wall" -le 3 ] && [ "$first_rc" = "7" ]; then
  pass "slotinv idle-release: journaled after idle threshold, freed slot acquired by another run within ${second_wall}s, producer's own exit code (7) preserved"
else
  fail "slotinv idle-release: idle_journaled=$idle_journaled second_rc=$second_rc second_wall=${second_wall}s first_rc=$first_rc"
fi

# === slotinv 5: idle-release does NOT fire while a live cargo/rustc
# descendant exists (AC6) =====================================================
ds5="$T/slotinv-idle-with-cargo"; mkdir -p "$ds5/bin"
(
  common_env "$ds5"
  export CARGO_BUDGET_SLOTS=1
  export CARGO_BUDGET_WAIT_MAX=30
  export CARGO_BUDGET_IDLE_HOLD_S=3
  export CARGO_BUDGET_IDLE_CPU_PCT=5
  # tree_has_cargo_or_rustc matches on /proc/<pid>/comm, which the kernel
  # sets from the EXECUTED FILE's own basename — a `#!/usr/bin/env bash`
  # script named "cargo" would actually run as comm=bash (the interpreter
  # the shebang re-execs to), not comm=cargo. `sleep` on this box is a
  # uutils coreutils multi-call binary that self-dispatches by its own
  # argv[0]/basename (so a copy named "cargo" refuses to run: "unknown
  # program 'cargo'") — use `perl`, a real standalone ELF interpreter that
  # doesn't self-dispatch by name, copied to a file literally named
  # `cargo` so execve-ing it directly (no shebang indirection) gives it
  # real comm=cargo, the same way a real `cargo` binary would show up.
  cp "$(command -v perl)" "$ds5/bin/cargo"
  chmod +x "$ds5/bin/cargo"
  cat > "$ds5/idle_producer_with_cargo.sh" <<EOF
#!/usr/bin/env bash
"$ds5/bin/cargo" -e 'sleep 8' &
wait
EOF
  chmod +x "$ds5/idle_producer_with_cargo.sh"
  "$CB" run -- "$ds5/idle_producer_with_cargo.sh" &
  p1=$!
  sleep 6
  # the sole slot must still be held (idle-release must NOT have fired).
  if flock -n "$ds5/state/slot-0.lock" -c true 2>/dev/null; then
    echo free > "$ds5/slot_state.txt"
  else
    echo held > "$ds5/slot_state.txt"
  fi
  wait "$p1"
)
slot_state="$(cat "$ds5/slot_state.txt" 2>/dev/null || echo free)"
idle_journaled5=0
grep -q 'cargo-budget  idle-release slot=' "$ds5/journal.md" 2>/dev/null && idle_journaled5=1
if [ "$slot_state" = "held" ] && [ "$idle_journaled5" -eq 0 ]; then
  pass "slotinv idle-release skipped: slot stayed held (no idle-release line) while a live 'cargo' descendant existed"
else
  fail "slotinv idle-release skipped: expected slot held / no idle-release line, got slot_state=$slot_state idle_journaled=$idle_journaled5"
fi

# === slotinv 6: timeout diagnostics — holders=[...] names both real pids
# (AC7) ========================================================================
ds6="$T/slotinv-timeout-holders"; mkdir -p "$ds6"
(
  common_env "$ds6"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=8
  "$CB" run -- sleep 20 & h1=$!
  "$CB" run -- sleep 20 & h2=$!
  sleep 1
  "$CB" run -- true
  echo "$?" > "$ds6/third_rc.txt"
  wait "$h1" "$h2" 2>/dev/null
)
third_rc="$(cat "$ds6/third_rc.txt" 2>/dev/null || echo 0)"
timeout_line="$(grep 'cargo-budget  wait slot timeout' "$ds6/journal.md" 2>/dev/null | tail -1)"
holders_ok=0
if printf '%s' "$timeout_line" | grep -Eq 'holders=\[slot0:[0-9]+:[0-9]+s:[^,]*, slot1:[0-9]+:[0-9]+s:'; then
  holders_ok=1
fi
if [ "$third_rc" = "3" ] && [ "$holders_ok" -eq 1 ]; then
  pass "slotinv timeout diagnostics: exit 3 preserved, journal names both real holder pids ($timeout_line)"
else
  fail "slotinv timeout diagnostics: third_rc=$third_rc holders_ok=$holders_ok line='$timeout_line'"
fi

# === slotinv 7: ledger gains parent_step/nested/tree_cpu_s/idle_released,
# and summary gains holds=/idle_slot_s=/nested=/timeouts= (AC8) =============
ds7="$T/slotinv-ledger-fields"; mkdir -p "$ds7"
(
  common_env "$ds7"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  export CARGO_BUDGET_PARENT_STEP="autobuilder-loop"
  "$CB" run -- true
)
row7="$(tail -1 "$ds7/state/ledger.jsonl" 2>/dev/null)"
fields_ok=0
if [ "$(jq -r '.parent_step' <<<"$row7")" = "autobuilder-loop" ] \
   && jq -e 'has("nested") and has("tree_cpu_s") and has("idle_released")' <<<"$row7" >/dev/null 2>&1; then
  fields_ok=1
fi
summary7="$(CARGO_BUDGET_STATE_DIR="$ds7/state" "$CB" summary --since 0 2>/dev/null)"
summary_ok=0
printf '%s' "$summary7" | grep -Eq 'holds=[0-9]+ idle_slot_s=[0-9.]+ nested=[0-9]+ timeouts=[0-9]+' && summary_ok=1
if [ "$fields_ok" -eq 1 ] && [ "$summary_ok" -eq 1 ]; then
  pass "slotinv ledger fields: row carries parent_step/nested/tree_cpu_s/idle_released; summary carries holds=/idle_slot_s=/nested=/timeouts= ('$summary7')"
else
  fail "slotinv ledger fields: fields_ok=$fields_ok summary_ok=$summary_ok row='$row7' summary='$summary7'"
fi

# === slotinv 8: `status` prints both slots' holder/held_s/tree_cpu_s (AC10) =
ds8="$T/slotinv-status"; mkdir -p "$ds8"
(
  common_env "$ds8"
  export CARGO_BUDGET_SLOTS=2
  export CARGO_BUDGET_WAIT_MAX=30
  "$CB" run -- sleep 6 &
  "$CB" run -- sleep 6 &
  sleep 1
  "$CB" status > "$ds8/status.txt"
  wait
)
status8="$(cat "$ds8/status.txt" 2>/dev/null)"
if printf '%s' "$status8" | grep -Eq 'slot0=pid:[0-9]+,held_s:[0-9]+,tree_cpu_s:[0-9]+' \
   && printf '%s' "$status8" | grep -Eq 'slot1=pid:[0-9]+,held_s:[0-9]+,tree_cpu_s:[0-9]+'; then
  pass "slotinv status: both slots report pid/held_s/tree_cpu_s ('$status8')"
else
  fail "slotinv status: expected both slots' pid/held_s/tree_cpu_s, got '$status8'"
fi

echo "-----"
if [ "$fails" -eq 0 ]; then
  echo "cargo-budget-selftest: ALL PASS"
  exit 0
else
  echo "cargo-budget-selftest: $fails assertion(s) FAILED"
  exit 1
fi
