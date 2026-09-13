#!/usr/bin/env bash
# secret-store-selftest.sh — proves secret-store.sh's convention survives a
# real dispatch boundary (PRD-build-tenant-secret-continuity, AC2): a
# secret written by one spawned process is read back by a SEPARATELY
# spawned process with a different PID, not just a same-process function
# call that would give a false sense of durability. Runs entirely under a
# scratch BUILD_STATE_DIR; never touches the real state/ tree.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SS="$HERE/secret-store.sh"
ROOT=$(mktemp -d /tmp/secret-store-selftest.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

export BUILD_STATE_DIR="$ROOT/state"

SLUG="dispatch-boundary-test"
SECRET_NAME="tenant_key"
SECRET_VALUE="t_ea9749c3-fake-tenant-key-do-not-use"

echo "== process A writes the secret, then exits =="
bash -c '"$1" write "$2" "$3" "$4"; echo "$BASHPID" > "$5"' \
  _ "$SS" "$SLUG" "$SECRET_NAME" "$SECRET_VALUE" "$ROOT/writer.pid" 2>"$ROOT/writer.log"
WRITER_PID="$(cat "$ROOT/writer.pid")"
echo "writer pid was $WRITER_PID"

SECRET_FILE="$BUILD_STATE_DIR/secrets/$SLUG/$SECRET_NAME.json"
[ -f "$SECRET_FILE" ] || { echo "FAIL: secret file not created: $SECRET_FILE"; cat "$ROOT/writer.log"; exit 1; }
MODE="$(stat -c '%a' "$SECRET_FILE")"
[ "$MODE" = "600" ] || { echo "FAIL: secret file mode is $MODE, want 600"; exit 1; }
DIR_MODE="$(stat -c '%a' "$(dirname "$SECRET_FILE")")"
[ "$DIR_MODE" = "700" ] || { echo "FAIL: secrets dir mode is $DIR_MODE, want 700"; exit 1; }
echo ok

echo "== process B (freshly spawned, different pid) reads it back =="
READ_OUT="$(bash -c '"$1" read "$2" "$3"; echo "$BASHPID" > "$4"' \
  _ "$SS" "$SLUG" "$SECRET_NAME" "$ROOT/reader.pid")"
READER_PID="$(cat "$ROOT/reader.pid")"
echo "reader pid was $READER_PID"

[ "$READ_OUT" = "$SECRET_VALUE" ] || { echo "FAIL: read back '$READ_OUT', want '$SECRET_VALUE'"; exit 1; }
if [ "$WRITER_PID" = "$READER_PID" ]; then
  echo "FAIL: writer and reader pid identical ($WRITER_PID) -- not a real cross-process test"
  exit 1
fi
echo "writer pid $WRITER_PID != reader pid $READER_PID -- confirmed cross-process, value round-tripped"
echo ok

echo "== .gitignore excludes state/secrets/ so a secret can never be committed =="
grep -q '^state/secrets/$' "$HERE/../.gitignore" || { echo "FAIL: .gitignore missing explicit state/secrets/ entry"; exit 1; }
echo ok

echo "== reading a missing secret fails loudly (exit 4), not silently =="
set +e
"$SS" read "$SLUG" no-such-secret >"$ROOT/missing.out" 2>"$ROOT/missing.err"
rc=$?
set -e
[ "$rc" = "4" ] || { echo "FAIL: expected exit 4, got $rc"; cat "$ROOT/missing.err"; exit 1; }
grep -qi "not found" "$ROOT/missing.err" || { echo "FAIL: missing-secret error message unclear:"; cat "$ROOT/missing.err"; exit 1; }
echo ok

echo "== path subcommand names the file without reading/creating it =="
OTHER_PATH="$("$SS" path "$SLUG" never-written)"
[ "$OTHER_PATH" = "$BUILD_STATE_DIR/secrets/$SLUG/never-written.json" ] || { echo "FAIL: unexpected path: $OTHER_PATH"; exit 1; }
[ ! -e "$OTHER_PATH" ] || { echo "FAIL: path subcommand should not create the file"; exit 1; }
echo ok

echo "ALL PASS"
