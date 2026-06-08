#!/usr/bin/env bash
# tests/manifest-set.sh — race/recovery test for scripts/manifest-set.sh.
#
# Covers the 5 Acceptance criteria of PRD-build-durable-manifest-write:
#   AC1 single-slug isolation: merging one slug leaves all others byte-identical
#   AC2 2-process concurrent race on different slugs — both land (no lost update)
#   AC3 kill-after-intent-before-lock, then --replay-orphans recovers the patch
#   AC4 --replay-orphans is a no-op (exit 0, no manifest mtime change) when empty
#   AC5 an already-reflected intent is cleaned up WITHOUT a redundant write
#
# Runs fully isolated: BUILD_STATE_DIR/BUILD_MANIFEST point at a scratch
# tempdir, so the real state/manifest.json is never read or written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/manifest-set.sh"

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# Fresh isolated sandbox per run.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/manifest-set-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export BUILD_STATE_DIR="$SANDBOX/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
export MANIFEST_LOCK_CEILING="${MANIFEST_LOCK_CEILING:-30}"
mkdir -p "$BUILD_STATE_DIR/intent"

seed_manifest() {
  cat >"$BUILD_MANIFEST" <<'JSON'
{
  "generated": "2026-06-08T00:00:00Z",
  "prds": {
    "alpha": {"slug": "alpha", "status": "shipped", "output_repo_path": "/x/alpha"},
    "beta":  {"slug": "beta",  "status": "queued",  "output_repo_path": null},
    "gamma": {"slug": "gamma", "status": "queued",  "output_repo_path": null}
  }
}
JSON
}

# read a single prds.<slug>.<key> value
get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prds"].get(sys.argv[2],{}).get(sys.argv[3]))' "$BUILD_MANIFEST" "$1" "$2"; }
# byte-stable canonical projection of one slug's entry
entry_blob() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["prds"].get(sys.argv[2]),sort_keys=True))' "$BUILD_MANIFEST" "$1"; }

# ---- AC1: single-slug isolation, others byte-identical -------------------
seed_manifest
beta_before="$(entry_blob beta)"
gamma_before="$(entry_blob gamma)"
printf '%s' '{"status":"in_progress"}' >"$SANDBOX/p1.json"
if "$SCRIPT" alpha "$SANDBOX/p1.json"; then
  if [ "$(get alpha status)" = "in_progress" ] \
     && [ "$(get alpha output_repo_path)" = "/x/alpha" ] \
     && [ "$(entry_blob beta)" = "$beta_before" ] \
     && [ "$(entry_blob gamma)" = "$gamma_before" ]; then
    pass "AC1 single-slug merge; other slugs byte-identical"
  else
    bad "AC1 other slugs changed or alpha not merged"
  fi
else
  bad "AC1 manifest-set exited non-zero"
fi

# ---- AC2: 2-process concurrent race on different slugs, both land --------
seed_manifest
printf '%s' '{"status":"shipped","output_repo_path":"/r/beta"}'   >"$SANDBOX/pb.json"
printf '%s' '{"status":"shipped","output_repo_path":"/r/gamma"}'  >"$SANDBOX/pg.json"
"$SCRIPT" beta  "$SANDBOX/pb.json" &
pb=$!
"$SCRIPT" gamma "$SANDBOX/pg.json" &
pg=$!
wait "$pb"; rb=$?
wait "$pg"; rg=$?
if [ "$rb" -eq 0 ] && [ "$rg" -eq 0 ] \
   && [ "$(get beta status)" = "shipped" ]  && [ "$(get beta output_repo_path)" = "/r/beta" ] \
   && [ "$(get gamma status)" = "shipped" ] && [ "$(get gamma output_repo_path)" = "/r/gamma" ]; then
  pass "AC2 concurrent race on different slugs — both landed"
else
  bad "AC2 lost update (beta=$(get beta status)/$(get beta output_repo_path) gamma=$(get gamma status)/$(get gamma output_repo_path) rc=$rb,$rg)"
fi

# ---- AC3: kill-after-intent-before-lock, then --replay-orphans recovers --
# Simulate the crash precisely: write the intent by hand (the write-ahead
# step) and DO NOT touch the manifest, as if the process died before the
# lock. Then --replay-orphans must apply it.
seed_manifest
python3 - "$BUILD_STATE_DIR/intent/alpha.json" <<'PY'
import json,sys
json.dump({"slug":"alpha","patch":{"status":"in_progress","output_repo_path":"/recovered/alpha"},
           "ts":"2026-06-08T00:00:01Z"}, open(sys.argv[1],"w"), sort_keys=True, separators=(",",":"))
PY
if [ "$(get alpha status)" = "in_progress" ]; then
  bad "AC3 precondition: alpha already in_progress before replay"
fi
if "$SCRIPT" --replay-orphans 2>/dev/null \
   && [ "$(get alpha status)" = "in_progress" ] \
   && [ "$(get alpha output_repo_path)" = "/recovered/alpha" ] \
   && [ ! -f "$BUILD_STATE_DIR/intent/alpha.json" ]; then
  pass "AC3 replay recovers orphaned intent (and removes it)"
else
  bad "AC3 replay did not recover orphaned intent"
fi

# ---- AC4: --replay-orphans no-op on empty (exit 0, no mtime change) ------
seed_manifest
rm -f "$BUILD_STATE_DIR"/intent/*.json 2>/dev/null
mtime_before="$(stat -f %m "$BUILD_MANIFEST" 2>/dev/null || stat -c %Y "$BUILD_MANIFEST")"
sleep 1.1
"$SCRIPT" --replay-orphans; rc=$?
mtime_after="$(stat -f %m "$BUILD_MANIFEST" 2>/dev/null || stat -c %Y "$BUILD_MANIFEST")"
if [ "$rc" -eq 0 ] && [ "$mtime_before" = "$mtime_after" ]; then
  pass "AC4 replay no-op on empty intent dir (exit 0, manifest untouched)"
else
  bad "AC4 replay touched manifest or non-zero (rc=$rc mtime $mtime_before->$mtime_after)"
fi

# ---- AC5: already-reflected intent cleaned up WITHOUT a redundant write --
seed_manifest
# Make the manifest already show beta=shipped/_r/beta, and drop an intent
# carrying the SAME patch. Replay must remove the intent but NOT rewrite.
printf '%s' '{"status":"shipped","output_repo_path":"/r/beta"}' >"$SANDBOX/pb2.json"
"$SCRIPT" beta "$SANDBOX/pb2.json" >/dev/null
python3 - "$BUILD_STATE_DIR/intent/beta.json" <<'PY'
import json,sys
json.dump({"slug":"beta","patch":{"status":"shipped","output_repo_path":"/r/beta"},
           "ts":"2026-06-08T00:00:02Z"}, open(sys.argv[1],"w"), sort_keys=True, separators=(",",":"))
PY
mtime_before="$(stat -f %m "$BUILD_MANIFEST" 2>/dev/null || stat -c %Y "$BUILD_MANIFEST")"
sleep 1.1
"$SCRIPT" --replay-orphans; rc=$?
mtime_after="$(stat -f %m "$BUILD_MANIFEST" 2>/dev/null || stat -c %Y "$BUILD_MANIFEST")"
if [ "$rc" -eq 0 ] \
   && [ ! -f "$BUILD_STATE_DIR/intent/beta.json" ] \
   && [ "$mtime_before" = "$mtime_after" ]; then
  pass "AC5 already-reflected intent cleaned up without redundant write"
else
  bad "AC5 redundant write or intent not cleaned (rc=$rc exists=$( [ -f "$BUILD_STATE_DIR/intent/beta.json" ] && echo yes || echo no ) mtime $mtime_before->$mtime_after)"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL 5 ACCEPTANCE CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit "$fail"
