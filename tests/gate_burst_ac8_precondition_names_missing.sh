#!/usr/bin/env bash
# gate_burst_ac8_precondition_names_missing.sh — PRD-build-gate-cloudburst AC8 (P1).
#
# Given the precondition check, when it runs, then it reports
# present/authenticated or refuses bursting with a message naming what is
# missing. Exercised three ways: hcloud absent (the REAL state on this
# machine right now — no mocking needed), hcloud present but unauthenticated,
# and hcloud present + authenticated + configured.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac8: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac8.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GATE_BURST_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"
export FAKE_HCLOUD_STATE="$T/hcloud.state"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# 1) Real state: no hcloud on PATH at all (this is genuinely true on
#    RedBaron today — no mock involved).
env -i PATH=/usr/bin:/bin HOME="$HOME" GATE_BURST_ENV_FILE="$GATE_BURST_ENV_FILE" \
  "$GB" precondition >/tmp/gb-ac8-absent.out 2>&1
rc=$?
expect "hcloud absent: precondition refuses (exit 1)"   "[ $rc -eq 1 ]"
expect "hcloud absent: message names the missing piece" "grep -qi 'hcloud CLI not on PATH' /tmp/gb-ac8-absent.out"

# 2) Mocked: hcloud present but not authenticated.
set +e
out=$(PATH="$FAKE:$PATH" FAKE_HCLOUD_AUTH_FAIL=1 "$GB" precondition 2>&1); rc=$?
set -e
expect "unauthenticated: precondition refuses (exit 1)"   "[ $rc -eq 1 ]"
expect "unauthenticated: message names the missing piece" "grep -qi 'not authenticated' <<<\"\$out\""

# 3) Mocked: hcloud present, authenticated, configured.
out=$(PATH="$FAKE:$PATH" "$GB" precondition); rc=$?
expect "fully configured: precondition passes (exit 0)" "[ $rc -eq 0 ]"
expect "fully configured: reports ok"                   "grep -q '^ok:' <<<\"\$out\""

exit $fail
