#!/usr/bin/env bash
# seltick_ac5_process_visibility_not_an_input.sh —
# PRD-build-select-tick-deterministic AC5: given a running fake process
# whose command line is `claude -p /build` and a second fake
# `claude-build-tick.sh`, when the script runs against AC1's fixture, then
# the output is byte-identical to AC1's own output.
#
# select-tick-selftest.sh documents AC5 as "not exercised with a fake
# process" because select-tick.sh's own source has no pgrep/ps/systemd
# code path to fool -- that is a real, verifiable claim, so this file
# checks it two ways: statically (grep the source for any of the calls
# requirement 3 forbids) and behaviorally (run the AC1 fixture with fake
# `claude -p /build` / `claude-build-tick.sh` processes alive and confirm
# select-tick.sh's output does not move).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"

# --- static leg: requirement 3 forbids consulting process state at all.
# Strip comment-only lines first -- select-tick.sh's own header PROSE
# names pgrep/systemd precisely to disclaim using them (see its line ~43),
# which must not itself trip this check.
code_only="$(grep -Ev '^[[:space:]]*#' "$ST")"
if printf '%s' "$code_only" | grep -Eq '(^|[^[:alnum:]_])(pgrep|systemctl|loginctl)([^[:alnum:]_-]|$)'; then
  echo "FAIL AC5: select-tick.sh calls pgrep/systemctl/loginctl in code -- process visibility is an input" >&2
  printf '%s' "$code_only" | grep -En '(^|[^[:alnum:]_])(pgrep|systemctl|loginctl)([^[:alnum:]_-]|$)' >&2
  exit 1
fi
if printf '%s' "$code_only" | grep -Eq '(^|[^[:alnum:]_])ps[[:space:]]+(aux|-ef|-e)'; then
  echo "FAIL AC5: select-tick.sh calls 'ps aux'/'ps -ef' in code -- process visibility is an input" >&2
  exit 1
fi

# --- behavioral leg: fake concurrent coordinator processes must not move
# the output. AC1's own fixture (8 rust-extend PRDs, one build_into, a
# burst session reporting sub-cap=8). ---------------------------------------
seltick_setup
for i in 1 2 3 4 5 6 7 8; do
  seltick_write_prd "rext$i" rust-extend /tmp/seltick-ac5-shared-repo
done
FAKE_BURST_READY=true
FAKE_BURST_WIDTH=8

baseline=$(BUILD_DISTINCT_TARGETS=0 BUILD_MAX_BRANCHES=30 BUILD_SAME_TARGET_CAP_BURST=8 seltick_run --format json)

# Fake `claude -p /build` and a second `claude-build-tick.sh`-named process,
# both alive for the duration of the second call.
bash -c 'exec -a "claude -p /build" sleep 5' &
fake1=$!
bash -c 'exec -a "claude-build-tick.sh" sleep 5' &
fake2=$!
# seltick_setup already armed an EXIT trap that removes $ROOT; replace it
# with one that also reaps these two fakes, rather than clobbering it.
trap 'kill "$fake1" "$fake2" 2>/dev/null; wait "$fake1" "$fake2" 2>/dev/null; rm -rf "$ROOT"' EXIT

with_fakes=$(BUILD_DISTINCT_TARGETS=0 BUILD_MAX_BRANCHES=30 BUILD_SAME_TARGET_CAP_BURST=8 seltick_run --format json)

kill "$fake1" "$fake2" 2>/dev/null
wait "$fake1" "$fake2" 2>/dev/null

if [ "$baseline" != "$with_fakes" ]; then
  echo "FAIL AC5: output changed with fake claude -p /build / claude-build-tick.sh processes alive" >&2
  diff <(printf '%s' "$baseline") <(printf '%s' "$with_fakes") >&2
  exit 1
fi

echo "ok  AC5: no pgrep/ps/systemd calls in select-tick.sh, and output is byte-identical with fake coordinator processes running"
