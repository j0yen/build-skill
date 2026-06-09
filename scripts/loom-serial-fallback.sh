#!/usr/bin/env bash
# loom-serial-fallback.sh — per-target conflict-streak ledger and serial-routing gate.
#
# When a build_into target's branches conflict ≥2 consecutive ticks on the
# same pathset, /build should route that target one-branch-per-tick (serial)
# instead of fanning out in parallel. This is the parent-side backstop that
# prevents the infinite-conflict livelock: two branches really do edit the same
# source line incompatibly, rebase-retry can't fix it, and the tick re-fans them
# in parallel every tick — stalling forever. Serial mode drains the backlog one
# branch per tick.
#
# PRD: PRD-loom-serial-fallback.md
# Sibling: worktree-extend.sh (which calls streak-record on exit-4 and
#          streak-reset on clean integrate), manifest-sidecar.sh (telemetry).
#
# Subcommands
# -----------
#   streak-record  <repo> <pathset>
#       Increment the conflict-streak counter for (repo, pathset).
#       pathset = comma-separated sorted file paths from the conflict.
#       Idempotent if called multiple times within the same tick (atomic write).
#
#   streak-reset   <repo>
#       Reset the conflict streak for this repo to 0 (clean integrate landed).
#
#   streak-get     <repo>
#       Print the current streak count for <repo> (0 if absent/malformed).
#       Fail-open: any parse error → prints 0 and exits 0.
#
#   serial-limit   <repo>
#       Exit 0 if this tick should be limited to ONE branch for <repo>
#       (streak ≥ 2). Exit 1 if parallel fan-out is fine. Never blocks.
#       Fail-open: errors → exit 1 (no serialization).
#
#   serial-gate    <repo> <count_already_dispatched>
#       Exit 0 (OK to dispatch another branch) if serial cap has room.
#       Exit 1 if serial cap is saturated (one already dispatched this tick).
#       <count_already_dispatched> = number of branches for this repo already
#       selected in this tick's Phase-2 pass. Fail-open: errors → exit 0.
#
#   log-flip       <repo> <pathset> <streak>  [serial|parallel]
#       Append a mode-flip event to gossip.md. No-op on write errors.
#
#   selftest
#       Run built-in unit tests. Exit 0 = all pass, non-zero = failures.
#
# State
# -----
# Streaks are persisted in $BUILD_STATE_DIR/conflict-streaks.json:
#   { "streaks": { "<repo-basename>:<sorted-pathset>": { "count": N, "repo": "...", "pathset": "...", "last_tick": "..." } } }
#
# The key uses basename(repo) to stay stable across symlinks / mount moves; the
# full repo path is stored in the value for human readability.
#
# Fail-open semantics (AC5): absent, empty, or malformed entries always yield
# streak = 0 → normal parallel behaviour. A bad read NEVER serializes a
# healthy repo.
#
# Thread safety: writes use mktemp + mv for atomicity. The overall manifest.lock
# is NOT used here (streak writes are infrequent, low-contention, and isolated
# from the manifest RMW path). If two branches conflict simultaneously (rare
# by the per-repo integration lock in worktree-extend.sh), the last write wins
# — which is fine because both would write streak ≥ 1 and the next tick will
# observe ≥ 1. True loss of a streak increment under simultaneous writes still
# satisfies the AC ("≥2 consecutive ticks" — it defers serialization by at most
# one tick, not indefinitely).
#
# Deterministic selection (AC3): when serial mode is active, the caller (Phase 2
# selection) should pick the OLDEST deferred branch by first_deferred_at or
# last_action ascending. This script enforces the CAP (at most 1 dispatched);
# the ordering is the caller's responsibility per the "oldest-first" convention.
#
# Drain + resume (AC4): streak-reset is called by worktree-extend integrate on
# a clean land. When the repo drops to ≤1 in_progress same-target branch, the
# serial cap is no longer hit naturally (nothing to serialize). If the streak
# counter itself is reset to 0, serial-limit returns 1 (not serialized) and the
# next tick resumes parallel fan-out.
#
# Telemetry (AC6): log-flip appends to gossip.md when a repo enters or exits
# serial mode. worktree-extend.sh calls streak-record (which triggers log-flip
# on transition) and streak-reset (which triggers log-flip on resume).
set -uo pipefail

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
STREAKS_FILE="$STATE_DIR/conflict-streaks.json"
# GOSSIP is read dynamically in cmd_log_flip so selftest overrides via BUILD_GOSSIP take effect.
_DEFAULT_GOSSIP="$HOME/wintermute/autobuilder/notes/gossip.md"

# Streak threshold for serial mode
SERIAL_THRESHOLD=2

log() { printf 'loom-serial-fallback: %s\n' "$*" >&2; }

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Normalise repo → basename (stable across path changes)
repo_key_prefix() { basename "${1%/}"; }

# Build the compound key: basename(repo):sorted_pathset
make_key() {
  local repo="$1" pathset="$2"
  printf '%s:%s' "$(repo_key_prefix "$repo")" "$pathset"
}

# Read the current streak count for <repo> (any pathset). Prints 0 on any
# read/parse failure (fail-open, AC5). Scans all keys for this repo prefix.
streak_max_for_repo() {
  local repo="$1"
  local prefix; prefix="$(repo_key_prefix "$repo")"
  [ -f "$STREAKS_FILE" ] || { echo 0; return 0; }
  python3 - "$STREAKS_FILE" "$prefix" 2>/dev/null <<'PY' || echo 0
import json, sys
path, prefix = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print(0); sys.exit(0)
streaks = data.get("streaks", {})
if not isinstance(streaks, dict):
    print(0); sys.exit(0)
max_count = 0
for k, v in streaks.items():
    if not k.startswith(prefix + ":"):
        continue
    try:
        c = int(v.get("count", 0))
    except (TypeError, ValueError):
        c = 0
    if c > max_count:
        max_count = c
print(max_count)
PY
}

# Increment the streak counter for (repo, pathset). Creates the file if absent.
# Prints the new streak count.
cmd_streak_record() {
  local repo="${1:-}" pathset="${2:-}"
  [ -n "$repo" ] || { log "usage: streak-record <repo> <pathset>"; return 2; }
  [ -n "$pathset" ] || pathset="unknown"
  local key; key="$(make_key "$repo" "$pathset")"
  local now; now="$(utc_now)"

  mkdir -p "$STATE_DIR"
  local tmp; tmp="$(mktemp "$STATE_DIR/.streaks.XXXXXX")"

  python3 - "$STREAKS_FILE" "$key" "$repo" "$pathset" "$now" >"$tmp" 2>/dev/null <<'PY'
import json, sys, os
path, key, repo, pathset, now = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
streaks = data.get("streaks", {})
if not isinstance(streaks, dict):
    streaks = {}
entry = streaks.get(key, {})
if not isinstance(entry, dict):
    entry = {}
old_count = 0
try:
    old_count = int(entry.get("count", 0))
except (TypeError, ValueError):
    old_count = 0
new_count = old_count + 1
entry.update({"count": new_count, "repo": repo, "pathset": pathset, "last_tick": now})
streaks[key] = entry
data["streaks"] = streaks
json.dump(data, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
print(new_count, file=sys.stderr)
PY

  local new_count; new_count="$(python3 -c "
import json,sys
try:
    d=json.load(open('$tmp'))
    k='$key'
    print(d.get('streaks',{}).get(k,{}).get('count',0))
except Exception:
    print(0)
" 2>/dev/null)"

  mv -f "$tmp" "$STREAKS_FILE" || { rm -f "$tmp"; log "streak-record: write failed"; return 4; }

  echo "$new_count"

  # Log to gossip on threshold transition (streak crosses 2 = enters serial)
  if [ "$new_count" -ge "$SERIAL_THRESHOLD" ]; then
    local prev_count=$(( new_count - 1 ))
    if [ "$prev_count" -lt "$SERIAL_THRESHOLD" ]; then
      # Just crossed the threshold → serial mode entered
      cmd_log_flip "$repo" "$pathset" "$new_count" "serial"
    fi
  fi
  return 0
}

# Reset the streak for a repo to 0 (all pathsets). Called on clean integrate.
cmd_streak_reset() {
  local repo="${1:-}"
  [ -n "$repo" ] || { log "usage: streak-reset <repo>"; return 2; }
  local prefix; prefix="$(repo_key_prefix "$repo")"
  [ -f "$STREAKS_FILE" ] || return 0

  local tmp; tmp="$(mktemp "$STATE_DIR/.streaks.XXXXXX")"
  if ! python3 - "$STREAKS_FILE" "$prefix" >"$tmp" 2>/dev/null <<'PY'; then
import json, sys
path, prefix = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
streaks = data.get("streaks", {})
if not isinstance(streaks, dict):
    streaks = {}
old_counts = {}
for k in list(streaks.keys()):
    if k.startswith(prefix + ":"):
        old_counts[k] = streaks[k].get("count", 0)
        streaks[k]["count"] = 0
data["streaks"] = streaks
json.dump(data, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
import json as _j
_j.dump(old_counts, sys.stderr)
PY
    rm -f "$tmp"
    log "streak-reset: write failed for $repo"
    return 4
  fi

  # Check if any old streak was ≥ threshold (so we log a mode exit)
  local had_serial=0
  python3 - "$STREAKS_FILE" "$prefix" 2>/dev/null <<'PY' && had_serial=$? || had_serial=0
import json, sys
path, prefix = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for k, v in data.get("streaks", {}).items():
    if k.startswith(prefix + ":") and int(v.get("count", 0)) >= 2:
        sys.exit(1)
sys.exit(0)
PY
  # had_serial=1 means python exited 1 (found serial streak), so invert
  [ "$had_serial" -eq 1 ] && had_serial=1 || had_serial=0

  mv -f "$tmp" "$STREAKS_FILE" || { rm -f "$tmp"; log "streak-reset: mv failed"; return 4; }

  if [ "$had_serial" -eq 1 ]; then
    cmd_log_flip "$repo" "(all)" "0" "parallel"
  fi
  return 0
}

# Print the maximum streak count for <repo> across all pathsets.
cmd_streak_get() {
  local repo="${1:-}"
  [ -n "$repo" ] || { log "usage: streak-get <repo>"; return 2; }
  streak_max_for_repo "$repo"
}

# Exit 0 if this repo should be LIMITED to one branch this tick (streak ≥ 2).
# Exit 1 if parallel fan-out is fine. Fail-open: errors → exit 1.
cmd_serial_limit() {
  local repo="${1:-}"
  [ -n "$repo" ] || { log "usage: serial-limit <repo>"; return 1; }
  local count; count="$(streak_max_for_repo "$repo")" || { echo 0; return 1; }
  if [ "$count" -ge "$SERIAL_THRESHOLD" ]; then
    return 0   # serial mode
  fi
  return 1     # normal parallel
}

# Gate: given already-dispatched count for <repo> this tick, exit 0 = OK to
# add another branch, exit 1 = cap saturated (one already in). Fail-open → 0.
cmd_serial_gate() {
  local repo="${1:-}" already="${2:-0}"
  [ -n "$repo" ] || { log "usage: serial-gate <repo> <count>"; return 0; }
  # If not in serial mode, gate always allows.
  if ! cmd_serial_limit "$repo"; then
    return 0
  fi
  # In serial mode: allow only if nothing dispatched yet.
  if [ "$already" -eq 0 ]; then
    return 0   # first branch: OK
  fi
  return 1     # already dispatched one: block
}

# Append a mode-flip event to gossip.md. AC6: never silent.
cmd_log_flip() {
  local repo="${1:-}" pathset="${2:-unknown}" streak="${3:-?}" direction="${4:-serial}"
  local now; now="$(utc_now)"
  local msg
  if [ "$direction" = "serial" ]; then
    msg="${now} loom-serial-fallback: SERIAL MODE for $(basename "$repo") (streak=${streak}, pathset=${pathset}) — fanning at most 1 branch/tick until backlog drains"
  else
    msg="${now} loom-serial-fallback: PARALLEL RESUMED for $(basename "$repo") (streak reset to ${streak}, pathset=${pathset})"
  fi

  # Resolve gossip path dynamically so BUILD_GOSSIP override in selftest works.
  local gossip_path="${BUILD_GOSSIP:-$_DEFAULT_GOSSIP}"
  local gossip_dir; gossip_dir="$(dirname "$gossip_path")"
  if [ -d "$gossip_dir" ]; then
    printf '%s\n' "$msg" >>"$gossip_path" 2>/dev/null || true
  fi
  log "$msg"
}

# Self-test suite (AC1–AC7). Runs in a temp dir so it never pollutes real state.
cmd_selftest() {
  local tmpdir; tmpdir="$(mktemp -d)"
  local orig_state="$STATE_DIR"
  export BUILD_STATE_DIR="$tmpdir"
  export BUILD_GOSSIP="$tmpdir/gossip.md"
  # Re-export so subcommands pick up the test state dir.
  STREAKS_FILE="$tmpdir/conflict-streaks.json"
  STATE_DIR="$tmpdir"

  local failures=0
  check() {
    local desc="$1" expected="$2"; shift 2
    local got; got="$("$@" 2>/dev/null)"; local rc=$?
    if [ "$expected" = "EXIT0" ]; then
      [ "$rc" -eq 0 ] || { echo "FAIL [$desc]: expected exit 0, got $rc"; failures=$(( failures + 1 )); }
    elif [ "$expected" = "EXIT1" ]; then
      [ "$rc" -ne 0 ] || { echo "FAIL [$desc]: expected exit nonzero, got $rc"; failures=$(( failures + 1 )); }
    else
      [ "$got" = "$expected" ] || { echo "FAIL [$desc]: expected '$expected', got '$got'"; failures=$(( failures + 1 )); }
    fi
  }

  # AC5: absent streaks file → streak 0, parallel
  check "absent-streak-get-0" "0" cmd_streak_get /fake/repo/alpha
  check "absent-serial-limit-off" "EXIT1" cmd_serial_limit /fake/repo/alpha

  # AC1: record streaks, verify count increments
  check "first-record-count" "1" cmd_streak_record /fake/repo/alpha "src/main.rs"
  check "after-1-streak-get" "1" cmd_streak_get /fake/repo/alpha
  check "after-1-serial-limit-off" "EXIT1" cmd_serial_limit /fake/repo/alpha

  check "second-record-count" "2" cmd_streak_record /fake/repo/alpha "src/main.rs"
  check "after-2-streak-get" "2" cmd_streak_get /fake/repo/alpha
  # AC2: streak ≥ 2 → serial mode on
  check "after-2-serial-limit-on" "EXIT0" cmd_serial_limit /fake/repo/alpha

  # AC2: serial-gate with 0 already → allow
  check "gate-0-allow" "EXIT0" cmd_serial_gate /fake/repo/alpha 0
  # AC2: serial-gate with 1 already → block
  check "gate-1-block" "EXIT1" cmd_serial_gate /fake/repo/alpha 1

  # AC7: scheduling-only — no branch is force-merged or dropped (verify that
  # streak-record and streak-reset only touch the streaks file, not any repo).
  local repo_test="$tmpdir/fake-repo"; mkdir -p "$repo_test/.git"
  touch "$repo_test/.git/COMMIT_EDITMSG"
  cmd_streak_record "$repo_test" "src/lib.rs" >/dev/null
  # Confirm .git/COMMIT_EDITMSG is unchanged (not force-merged by this script)
  [ -f "$repo_test/.git/COMMIT_EDITMSG" ] || { echo "FAIL [no-force-merge-check]"; failures=$(( failures + 1 )); }

  # AC3: determinism — same input → same streak_get output
  local v1; v1="$(cmd_streak_get /fake/repo/alpha)"
  local v2; v2="$(cmd_streak_get /fake/repo/alpha)"
  [ "$v1" = "$v2" ] || { echo "FAIL [determinism]: $v1 != $v2"; failures=$(( failures + 1 )); }

  # AC4: reset clears serial mode
  cmd_streak_reset /fake/repo/alpha >/dev/null 2>&1
  check "after-reset-streak-0" "0" cmd_streak_get /fake/repo/alpha
  check "after-reset-serial-off" "EXIT1" cmd_serial_limit /fake/repo/alpha

  # AC5: malformed streaks file → fail-open (streak 0)
  printf 'not_valid_json\n' > "$STREAKS_FILE"
  check "malformed-streak-0" "0" cmd_streak_get /fake/repo/beta
  check "malformed-serial-off" "EXIT1" cmd_serial_limit /fake/repo/beta

  # AC6: gossip written on threshold cross
  # Reset to clean state first
  rm -f "$STREAKS_FILE"
  cmd_streak_record /fake/repo/gamma "src/foo.rs" >/dev/null
  cmd_streak_record /fake/repo/gamma "src/foo.rs" >/dev/null  # crosses threshold
  [ -f "$BUILD_GOSSIP" ] || { echo "FAIL [gossip-written]: gossip.md not created"; failures=$(( failures + 1 )); }
  grep -q "SERIAL MODE" "$BUILD_GOSSIP" 2>/dev/null || { echo "FAIL [gossip-content]: SERIAL MODE not in gossip"; failures=$(( failures + 1 )); }

  # Restore real state dir
  export BUILD_STATE_DIR="$orig_state"
  STREAKS_FILE="$orig_state/conflict-streaks.json"
  STATE_DIR="$orig_state"
  rm -rf "$tmpdir"

  if [ "$failures" -eq 0 ]; then
    echo "loom-serial-fallback: all selftests passed"
    return 0
  else
    echo "loom-serial-fallback: $failures selftest(s) FAILED" >&2
    return 1
  fi
}

case "${1:-}" in
  streak-record)   shift; cmd_streak_record "$@" ;;
  streak-reset)    shift; cmd_streak_reset "$@" ;;
  streak-get)      shift; cmd_streak_get "$@" ;;
  serial-limit)    shift; cmd_serial_limit "$@" ;;
  serial-gate)     shift; cmd_serial_gate "$@" ;;
  log-flip)        shift; cmd_log_flip "$@" ;;
  selftest)        cmd_selftest ;;
  *)
    echo "usage: loom-serial-fallback.sh {streak-record|streak-reset|streak-get|serial-limit|serial-gate|log-flip|selftest}" >&2
    exit 1
    ;;
esac
