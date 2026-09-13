#!/usr/bin/env bash
# secret-store.sh — durable, permission-scoped storage for a runtime secret
# a branch dispatch mints (e.g. a tenant API key) that a LATER dispatch (a
# fresh process, per /build's own per-tick branch-agent model) needs to
# reuse. PRD-build-tenant-secret-continuity: a real 2026-09-13 dispatch
# minted mcphost.dev tenant t_ea9749c3's key, held it only in its own
# process memory, and wrote "key already held" into the PRD's text — the
# next dispatch (a fresh process) had nowhere to read it back from, and
# read-only DB inspection confirmed the server stores nothing but a
# non-reversible key_hash. Gone for good, by construction, the instant
# that process exited.
#
# Convention (see SKILL.md's "Runtime secrets" section, which this
# implements): ~/.claude/skills/build/state/secrets/<slug>/<name>.json,
# secrets dir mode 700, file mode 600, never git-tracked (state/ and
# state/secrets/ are both in .gitignore), never echoed into PRD prose or
# journal lines — only the path (or the fact a secret exists) belongs
# there, never the value.
#
# Usage:
#   secret-store.sh write <slug> <name> [value]   # value from stdin if omitted or '-'
#   secret-store.sh read  <slug> <name>           # prints the value to stdout
#   secret-store.sh path  <slug> <name>           # prints the file path (no read/existence check)
#
# Exit: 0 ok | 2 usage error | 4 not found (read) | 5 io/encode error
set -uo pipefail

SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
SECRETS_ROOT="$STATE_DIR/secrets"

SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
NAME_RE='^[A-Za-z0-9_.-]+$'

usage() {
  echo "usage: secret-store.sh write <slug> <name> [value]" >&2
  echo "       secret-store.sh read  <slug> <name>" >&2
  echo "       secret-store.sh path  <slug> <name>" >&2
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd="${1:-}"
slug="${2:-}"
name="${3:-}"

if [ -z "$cmd" ] || [ -z "$slug" ] || [ -z "$name" ]; then
  usage
  exit 2
fi
if [[ ! "$slug" =~ $SLUG_RE ]]; then
  echo "secret-store: slug '$slug' must match $SLUG_RE" >&2
  exit 2
fi
if [[ ! "$name" =~ $NAME_RE ]]; then
  echo "secret-store: name '$name' must match $NAME_RE" >&2
  exit 2
fi

dir="$SECRETS_ROOT/$slug"
file="$dir/$name.json"

case "$cmd" in
  write)
    value="${4-}"
    if [ -z "${4+x}" ] || [ "$value" = "-" ]; then
      value="$(cat)"
    fi
    if [ -z "$value" ]; then
      echo "secret-store: refusing to write an empty secret value" >&2
      exit 2
    fi
    mkdir -p "$dir" || { echo "secret-store: could not create $dir" >&2; exit 5; }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="$(mktemp "$dir/.${name}.XXXXXX")" || { echo "secret-store: mktemp failed in $dir" >&2; exit 5; }
    ts="$(utc_now)"
    if ! VALUE="$value" TS="$ts" python3 -c '
import json, os, sys
json.dump(
    {"value": os.environ["VALUE"], "written_at": os.environ["TS"]},
    sys.stdout,
)
' > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      echo "secret-store: failed to encode secret" >&2
      exit 5
    fi
    chmod 600 "$tmp" || true
    mv -f "$tmp" "$file" || { rm -f "$tmp"; echo "secret-store: mv into place failed" >&2; exit 5; }
    echo "wrote: $file" >&2
    ;;
  read)
    if [ ! -f "$file" ]; then
      echo "secret-store: not found: $file" >&2
      exit 4
    fi
    python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
sys.stdout.write(d["value"])
' "$file" || { echo "secret-store: failed to decode $file" >&2; exit 5; }
    ;;
  path)
    echo "$file"
    ;;
  *)
    usage
    exit 2
    ;;
esac
