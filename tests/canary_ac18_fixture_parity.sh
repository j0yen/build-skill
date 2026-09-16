#!/usr/bin/env bash
# tests/canary_ac18_fixture_parity.sh — PRD-build-burst-gate-canary-invariant
# AC18 (fixture half — the live-half of AC18, comparing against an actual
# Hetzner box's `status --json`, is a real-box AC run by hand, not here).
#
# Given tests/fixtures/burst-status.json (a recorded real `burst-lane.sh
# status --json`, R16), When this parity test runs the REAL burst-lane.sh
# against a synthetic-but-genuine active session (own mktemp state dir,
# BURST_LANE_HCLOUD_BIN pointed off-PATH so server_alive fails open per its
# own documented fail-open contract -- never a hand-typed JSON literal),
# Then the live output's key set (recursive: every object's own keys, one
# representative element's keys for each array of objects) must match the
# fixture's key set (ignoring "_comment"), else it fails naming the missing
# or extra keys.
#
# Recipe used to (re)generate tests/fixtures/burst-status.json when this
# test starts failing on a real shape change: run the same session setup
# this script does below, capture `burst-lane.sh status --json`, redact
# server_id/ip/image_id/head_sha/repo/free-disk/age values to placeholders,
# keep every key and value TYPE as emitted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
BL="$SKILL_DIR/scripts/burst-lane.sh"
FIXTURE="$SKILL_DIR/tests/fixtures/burst-status.json"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac18.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export BURST_LANE_STATE_DIR="$T/burst-state"
export BURST_LANE_JOURNAL="$T/burst-journal.log"
export BUILD_STATE_DIR="$T/probestate"
export PROBE_JOURNAL_DIR="$T/probe-journal"
export BURST_LANE_HCLOUD_BIN="$T/nonexistent-hcloud"

# PRD-build-burst-selftest-isolation: under run-selftests.sh (BUILD_TEST=1),
# burst-lane.sh's own isolation-guard.sh fails closed (exit 9) on ANY of
# hcloud/ssh/rsync that still resolves to a real system/user-local binary —
# a fake session's fake IP must never actually get ssh'd into. hcloud is
# already redirected above (server_alive fails open when its binary is
# missing); ssh/rsync need their own off-PATH fakes too, or the guard
# refuses before cmd_status ever runs.
cat > "$T/fake-ssh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cp "$T/fake-ssh" "$T/fake-rsync"
chmod +x "$T/fake-ssh" "$T/fake-rsync"
export BURST_LANE_SSH_BIN="$T/fake-ssh"
export BURST_LANE_RSYNC_BIN="$T/fake-rsync"
# Pin parity to empty deterministically -- BURST_PARITY_REPOS defaults to
# "mcphost" via `${BURST_PARITY_REPOS:-mcphost}`, which substitutes the
# default on EMPTY too, not just unset, so "" alone doesn't work here. A
# repo name that (deliberately) never resolves to a real box-parity.json
# under $ATTR_REPOS_DIR keeps the array empty regardless of whether
# $HOME/wintermute/mcphost happens to exist on the host running this test.
# The fixture records `parity: []`; this test must produce the same
# standalone or under run-selftests.sh isolation alike.
export BURST_PARITY_REPOS="canary-ac18-no-such-repo"

mkdir -p "$BURST_LANE_STATE_DIR/boxes/999999999"
ln -sfn "boxes/999999999" "$BURST_LANE_STATE_DIR/current"
cat > "$BURST_LANE_STATE_DIR/boxes/999999999/session.json" <<'EOF'
{
  "server_id":"999999999",
  "server_type":"ccx43",
  "ip":"203.0.113.10",
  "ttl_hours":"6",
  "sandbox_ok":"true",
  "gate_ready":"true",
  "gate_tools_missing":"none",
  "runs_served":"0",
  "create_epoch":"1789580000"
}
EOF

live_json="$("$BL" status --json 2>"$T/stderr.log")"
live_rc=$?
expect "AC18: real burst-lane.sh status --json exits 0" "[ $live_rc -eq 0 ]"
printf '%s' "$live_json" > "$T/live.json"

echo "== AC18: fixture key set matches the real command's key set =="
diff_out="$(python3 - "$FIXTURE" "$T/live.json" <<'PYEOF'
import json, sys

def keyshape(obj):
    """Recursive key-set shape: dict -> {k: keyshape(v)}, list of dicts ->
    keyshape of one representative element (first), list of scalars/empty
    -> "[]", scalar -> None. Values themselves never compared, only shape."""
    if isinstance(obj, dict):
        return {k: keyshape(v) for k, v in obj.items() if k != "_comment"}
    if isinstance(obj, list):
        for el in obj:
            if isinstance(el, (dict, list)):
                return [keyshape(el)]
        return []
    return None

def flat(prefix, shape, out):
    if isinstance(shape, dict):
        for k, v in shape.items():
            flat(f"{prefix}.{k}" if prefix else k, v, out)
        out.add(prefix or "$")
    elif isinstance(shape, list):
        if shape:
            flat(prefix + "[]", shape[0], out)
        out.add(prefix)
    else:
        out.add(prefix)

fixture = json.load(open(sys.argv[1]))
live = json.loads(open(sys.argv[2]).read())

f_paths, l_paths = set(), set()
flat("", keyshape(fixture), f_paths)
flat("", keyshape(live), l_paths)

missing = sorted(f_paths - l_paths)   # in fixture, not in live -> live dropped a key
extra = sorted(l_paths - f_paths)     # in live, not in fixture -> live grew a key

if missing or extra:
    if missing:
        print("missing (fixture has, live command does not): " + ", ".join(missing))
    if extra:
        print("extra (live command has, fixture does not): " + ", ".join(extra))
    sys.exit(1)
sys.exit(0)
PYEOF
)"
diff_rc=$?
if [ "$diff_rc" -eq 0 ]; then
  echo "ok  AC18: key sets match"
else
  echo "FAIL AC18: key sets diverged -- $diff_out" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "canary_ac18_fixture_parity: ALL PASS"
else
  echo "canary_ac18_fixture_parity: assertion(s) FAILED" >&2
fi
exit "$fail"
