#!/usr/bin/env bash
# manifest-set.sh — durable, contention-safe Phase-7 manifest writes.
#
# Replaces the hand-rolled "mkdir manifest.lock.d (spin ~5s) + RMW + rmdir"
# logic each branch used to inline. Two failure modes that pattern had:
#   (1) give-up-on-contention: 5s < a slow RMW under N contending branches,
#       so a losing branch returned green but its manifest delta vanished;
#   (2) no durability: the patch lived only in the branch's memory, so an
#       OOM-kill between "build green" and "lock acquired" orphaned the work
#       on disk with no pointer.
#
# Design (PRD-build-durable-manifest-write):
#   - write-ahead intent: state/intent/<slug>.json (patch + UTC ts) is
#     written ATOMICALLY *before* the lock is attempted, so a write that
#     never lands is still recoverable by --replay-orphans.
#   - block on state/manifest.lock.d via mkdir, retry every 0.2s up to a
#     HARD 60s ceiling (vs the old 5s give-up). On ceiling, exit non-zero
#     LEAVING the intent file so the parent's replay still recovers it.
#   - RMW touches ONLY prds.<slug> (tempfile + atomic mv).
#   - on success, delete the intent file then rmdir the lock.
#
# Usage:
#   manifest-set.sh <slug> <patch.json>   # patch = shallow object merged
#                                          # into prds.<slug>
#   manifest-set.sh --replay-orphans       # parent end-of-tick recovery
#
# Exit: 0 ok | 2 bad args/usage | 3 lock-ceiling-exceeded (intent kept)
#       | 4 patch/io error | 5 refused (slug resolves to >1 file in the
#       corpus -- PRD-build-prd-slug-uniqueness; only patches that touch
#       `status` are gated, see cmd_set)
set -uo pipefail

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
INTENT_DIR="$STATE_DIR/intent"
LOCK_DIR="$STATE_DIR/manifest.lock.d"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
JOURNAL="${JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
SLUG_COLLISIONS_PY="${SLUG_COLLISIONS_PY:-$SKILL_DIR/scripts/slug-collisions.py}"
# PRD-build-flow-ledger requirement 1/5: the append-only stage-event ledger
# every lifecycle script writes to. ticks_invested is DERIVED from it (see
# rewrite_ticks_invested_delta below), never trusted from a model-written
# Phase 7 delta.
LEDGER_FILE="${FLOW_LEDGER_FILE:-$STATE_DIR/flow-ledger.jsonl}"

LOCK_RETRY_INTERVAL="${MANIFEST_LOCK_RETRY:-0.2}"
LOCK_CEILING_SECS="${MANIFEST_LOCK_CEILING:-60}"

log() { printf '%s\n' "$*" >&2; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Acquire the mkdir lock, retrying every $LOCK_RETRY_INTERVAL up to a hard
# $LOCK_CEILING_SECS ceiling. Returns 0 on acquire, 3 on ceiling.
acquire_lock() {
  local waited=0
  # integer tenths-of-a-second budget so we don't depend on float math
  local ceiling_tenths=$(( LOCK_CEILING_SECS * 10 ))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ "$waited" -ge "$ceiling_tenths" ]; then
      return 3
    fi
    sleep "$LOCK_RETRY_INTERVAL"
    waited=$(( waited + 2 ))
  done
  return 0
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Atomically write the intent file (patch + ts). Validates patch is a JSON
# object first. Args: <slug> <patch.json path>
write_intent() {
  local slug="$1" patch_path="$2"
  mkdir -p "$INTENT_DIR" || return 4
  local ts; ts="$(utc_now)"
  local tmp; tmp="$(mktemp "$INTENT_DIR/.${slug}.intent.XXXXXX")" || return 4
  if ! python3 - "$patch_path" "$slug" "$ts" >"$tmp" 2>/dev/null <<'PY'
import json, sys
patch_path, slug, ts = sys.argv[1], sys.argv[2], sys.argv[3]
with open(patch_path) as f:
    patch = json.load(f)
if not isinstance(patch, dict):
    raise SystemExit("patch must be a JSON object")
json.dump({"slug": slug, "patch": patch, "ts": ts}, sys.stdout,
          sort_keys=True, separators=(",", ":"))
PY
  then
    rm -f "$tmp"
    return 4
  fi
  mv -f "$tmp" "$INTENT_DIR/$slug.json" || { rm -f "$tmp"; return 4; }
  return 0
}

# Locked read-modify-write of ONLY prds.<slug>, merging the given patch.
# Caller must hold the lock. Args: <slug> <patch-json-string-or-file> mode
# mode = "file": $2 is a path; mode = "inline": $2 is a JSON string.
apply_patch_locked() {
  local slug="$1" patch_src="$2" mode="$3"
  local tmp; tmp="$(mktemp "$STATE_DIR/.manifest.XXXXXX")" || return 4
  if ! MANIFEST="$MANIFEST" python3 - "$slug" "$patch_src" "$mode" >"$tmp" 2>/dev/null <<'PY'
import json, os, sys
slug, patch_src, mode = sys.argv[1], sys.argv[2], sys.argv[3]
manifest_path = os.environ["MANIFEST"]
if mode == "file":
    with open(patch_src) as f:
        patch = json.load(f)
else:
    patch = json.loads(patch_src)
if not isinstance(patch, dict):
    raise SystemExit("patch must be a JSON object")
try:
    with open(manifest_path) as f:
        m = json.load(f)
except FileNotFoundError:
    m = {}
prds = m.get("prds", [])
if isinstance(prds, list):
    entry = None
    idx = None
    for i, p in enumerate(prds):
        if isinstance(p, dict) and p.get("slug") == slug:
            entry = p; idx = i; break
    if entry is None:
        entry = {"slug": slug}
        prds.append(entry)
        idx = len(prds) - 1
    entry.update(patch)
    prds[idx] = entry
    m["prds"] = prds
else:
    if not isinstance(prds, dict):
        prds = {}
    entry = prds.get(slug)
    if not isinstance(entry, dict):
        entry = {"slug": slug}
    entry.update(patch)
    prds[slug] = entry
    m["prds"] = prds
json.dump(m, sys.stdout, indent=2, sort_keys=False)
sys.stdout.write("\n")
PY
  then
    rm -f "$tmp"
    return 4
  fi
  mv -f "$tmp" "$MANIFEST" || { rm -f "$tmp"; return 4; }
  return 0
}

# Is the patch in <intent.json> already fully reflected in prds.<slug>?
# Exit 0 = reflected (every key present and equal), 1 = not reflected.
intent_reflected() {
  local intent_path="$1"
  MANIFEST="$MANIFEST" python3 - "$intent_path" <<'PY'
import json, os, sys
intent_path = sys.argv[1]
manifest_path = os.environ["MANIFEST"]
with open(intent_path) as f:
    intent = json.load(f)
slug = intent["slug"]
patch = intent["patch"]
try:
    with open(manifest_path) as f:
        m = json.load(f)
except FileNotFoundError:
    m = {}
prds = m.get("prds", {})
if isinstance(prds, list):
    entry = next((p for p in prds if isinstance(p, dict) and p.get("slug") == slug), {})
else:
    entry = prds.get(slug, {})
for k, v in patch.items():
    if entry.get(k) != v:
        raise SystemExit(1)
raise SystemExit(0)
PY
}

# PRD-build-prd-slug-uniqueness, P0 "manifest guard": the manifest is
# keyed on slug, so a status write while the corpus holds >1 file for that
# slug would silently pick a side in an ambiguity only a human can resolve
# (the build-post-ship-reality-check incident: the manifest kept the
# shipped PRD's `archived` status while a distinct queued PRD sharing the
# slug read it too). Only patches that touch `status` are gated -- other
# fields (iter_log, blockers, ...) on an already in-progress slug are
# unaffected. Best-effort: any error in the scanner itself (script or
# python3 missing) never blocks a write -- this guard protects against a
# KNOWN collision, it must not become a new single point of failure for
# every manifest write.
patch_touches_status() {
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and "status" in d else 1)' "$1" 2>/dev/null
}

slug_collision_paths() {
  local slug="$1"
  [ -x "$SLUG_COLLISIONS_PY" ] || return 1
  local out
  out="$(PRD_DIR="$PRD_DIR" "$SLUG_COLLISIONS_PY" --prd-dir "$PRD_DIR" --slug "$slug" 2>/dev/null)" || return 1
  [ -n "$out" ] && [ "$out" != "[]" ] || return 1
  printf '%s' "$out"
  return 0
}

journal_collision_refusal() {
  local slug="$1" collisions_json="$2"
  local paths
  paths="$(printf '%s' "$collisions_json" | python3 -c 'import json,sys
c = json.load(sys.stdin)
print("|".join(c[0]["paths"]) if c else "")' 2>/dev/null)"
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true
  printf '%s  manifest-set  slug-collision-refuse (slug=%s paths="%s")  (host=%s)\n' \
    "$(utc_now)" "$slug" "$paths" "$(hostname)" >> "$JOURNAL" 2>/dev/null || true
}

# PRD-build-flow-ledger requirement 5: the ledger's own `claimed` event
# count for <slug> — the derived value ticks_invested is always set to.
# Never fails: a missing/unreadable/corrupt ledger reads as 0 claims, the
# same "degrade, never throw" convention day-ledger.sh's sources use.
ticks_invested_count() {
  local slug="$1"
  python3 -c 'import json, sys
path, slug = sys.argv[1], sys.argv[2]
n = 0
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("slug") == slug and e.get("stage") == "claimed":
                n += 1
except FileNotFoundError:
    pass
print(n)' "$LEDGER_FILE" "$slug"
}

# AC4: a patch carrying `ticks_invested_delta` is accepted-and-ignored (Open
# question default) rather than refused — the key is dropped and
# `ticks_invested` is set/overwritten to the ledger's derived count, with
# one journal line recording that the delta was ignored. Prints the patch
# path cmd_set should use from here on: unchanged (the original path) when
# no delta key was present, or a fresh scratch tmp file (caller's to clean
# up) when a rewrite happened.
rewrite_ticks_invested_delta() {
  local slug="$1" patch_path="$2"
  if ! python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if isinstance(d, dict) and "ticks_invested_delta" in d else 1)' "$patch_path" 2>/dev/null; then
    printf '%s\n' "$patch_path"
    return 0
  fi
  local n; n="$(ticks_invested_count "$slug")"
  [ -n "$n" ] || n=0
  local tmp; tmp="$(mktemp "$STATE_DIR/.manifest-patch.XXXXXX" 2>/dev/null)" || { printf '%s\n' "$patch_path"; return 0; }
  if ! python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
d.pop("ticks_invested_delta", None)
d["ticks_invested"] = int(sys.argv[2])
with open(sys.argv[3], "w") as f:
    json.dump(d, f)' "$patch_path" "$n" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf '%s\n' "$patch_path"
    return 0
  fi
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true
  printf '%s  manifest-set  ticks-invested-delta-ignored (slug=%s ticks_invested=%s)  (host=%s)\n' \
    "$(utc_now)" "$slug" "$n" "$(hostname)" >> "$JOURNAL" 2>/dev/null || true
  printf '%s\n' "$tmp"
}

cmd_set() {
  local slug="$1" patch_path="$2"
  if [ -z "$slug" ] || [ -z "$patch_path" ]; then
    log "manifest-set: usage: manifest-set.sh <slug> <patch.json>"; return 2
  fi
  if [ ! -f "$patch_path" ]; then
    log "manifest-set: patch file not found: $patch_path"; return 2
  fi

  if patch_touches_status "$patch_path"; then
    local collisions
    if collisions="$(slug_collision_paths "$slug")"; then
      journal_collision_refusal "$slug" "$collisions"
      log "manifest-set: refused -- slug '$slug' resolves to more than one file in the corpus (see: $SLUG_COLLISIONS_PY --prd-dir '$PRD_DIR' --slug '$slug')"
      return 5
    fi
  fi

  # PRD-build-flow-ledger AC4: rewrite ticks_invested_delta (if present)
  # into a ledger-derived ticks_invested BEFORE the intent is written, so
  # the durable intent already carries the derived value and a later
  # --replay-orphans is idempotent (it re-applies the same derived number,
  # never re-derives). effective_patch differs from patch_path only when a
  # rewrite happened, in which case it is a scratch tmp file this call
  # owns and must clean up on every exit path below.
  local effective_patch; effective_patch="$(rewrite_ticks_invested_delta "$slug" "$patch_path")"
  local cleanup_effective=0
  [ "$effective_patch" = "$patch_path" ] || cleanup_effective=1

  # 1. Write-ahead intent BEFORE the lock.
  if ! write_intent "$slug" "$effective_patch"; then
    log "manifest-set: failed to write intent for $slug"
    [ "$cleanup_effective" -eq 0 ] || rm -f "$effective_patch"
    return 4
  fi

  # 2. Acquire the lock with a hard 60s ceiling.
  if ! acquire_lock; then
    log "manifest-set: lock ceiling (${LOCK_CEILING_SECS}s) exceeded for $slug; intent kept for replay"
    [ "$cleanup_effective" -eq 0 ] || rm -f "$effective_patch"
    return 3
  fi

  # 3. RMW only prds.<slug>.
  if ! apply_patch_locked "$slug" "$effective_patch" "file"; then
    release_lock
    log "manifest-set: RMW failed for $slug; intent kept for replay"
    [ "$cleanup_effective" -eq 0 ] || rm -f "$effective_patch"
    return 4
  fi

  # 4. Success: drop the intent, release the lock.
  rm -f "$INTENT_DIR/$slug.json"
  release_lock
  [ "$cleanup_effective" -eq 0 ] || rm -f "$effective_patch"
  return 0
}

cmd_replay() {
  mkdir -p "$INTENT_DIR" 2>/dev/null || true
  # No-op (exit 0, no manifest mtime change) when there are no intents.
  shopt -s nullglob
  local intents=( "$INTENT_DIR"/*.json )
  shopt -u nullglob
  if [ "${#intents[@]}" -eq 0 ]; then
    return 0
  fi

  local rc=0
  for intent_path in "${intents[@]}"; do
    local slug; slug="$(basename "$intent_path" .json)"
    if intent_reflected "$intent_path"; then
      # Already reflected — clean up WITHOUT a redundant write.
      rm -f "$intent_path"
      continue
    fi
    # Not reflected — apply under the same locked RMW.
    if ! acquire_lock; then
      log "manifest-replay: lock ceiling exceeded for $slug; intent kept"
      rc=3
      continue
    fi
    local patch_json
    patch_json="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["patch"]))' "$intent_path" 2>/dev/null)"
    if [ -z "$patch_json" ]; then
      release_lock
      log "manifest-replay: unreadable intent $intent_path; skipping"
      rc=4
      continue
    fi
    if apply_patch_locked "$slug" "$patch_json" "inline"; then
      local ts; ts="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("ts",""))' "$intent_path" 2>/dev/null)"
      rm -f "$intent_path"
      release_lock
      log "manifest-replay: applied orphaned intent for $slug (ts=$ts)"
    else
      release_lock
      log "manifest-replay: RMW failed for $slug; intent kept"
      rc=4
    fi
  done
  return "$rc"
}

main() {
  if [ "$#" -lt 1 ]; then
    log "manifest-set: usage: manifest-set.sh <slug> <patch.json> | --replay-orphans"
    return 2
  fi
  case "$1" in
    --replay-orphans) cmd_replay ;;
    -h|--help)
      log "usage: manifest-set.sh <slug> <patch.json> | --replay-orphans"; return 0 ;;
    --*) log "manifest-set: unknown flag: $1"; return 2 ;;
    *) cmd_set "${1:-}" "${2:-}" ;;
  esac
}

main "$@"
