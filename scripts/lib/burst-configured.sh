#!/usr/bin/env bash
# burst-configured.sh — single shared predicate for "is the burst lane
# genuinely the active policy AND usable right now". Sourced (never
# executed) by any selftest whose acceptance criteria only make sense when
# a real burst box is the intended routing target.
#
# 2026-09-11 policy: cargo/build runs LOCALLY on RedBaron. The Hetzner
# casper burst box was DELETED. The burst lane/shim code is kept in the
# tree, dormant, for a possible future re-enable — it must never be
# resurrected implicitly by a selftest treating a fake/simulated session
# as proof the real lane is live.
#
# burst_configured() returns 0 (true) ONLY when BOTH:
#   (a) an operator has explicitly opted back in for this invocation via
#       BUILD_BURST_ENABLED=1 in the environment (the escape hatch a
#       future re-enable, or a one-off forced test run, uses) — OR —
#   (b) the real burst-lane env file (default ~/.config/wm-burst/.env,
#       overridable via BURST_LANE_ENV_FILE to match burst-lane.sh's own
#       override) exists, is readable, AND declares a non-dormant box:
#       both BUILDER_IP and BUILDER_ID are non-empty after sourcing it in
#       a subshell (never in this shell — the file also carries a live
#       HCLOUD_TOKEN that a selftest must never inherit just by checking
#       whether burst is configured).
#
# Under the current RedBaron-local policy this returns FALSE: (a) is unset
# by default, and (b)'s real file has BUILDER_IP='' / BUILDER_ID=''
# (commented "server deleted 2026-06-05" in the file itself) — present,
# readable, but dormant.
#
# Deliberately NOT checked here (out of scope for a fast, non-hanging
# predicate sourced at the top of a selftest): live reachability (ssh/ping
# of BUILDER_IP), a burst-lane.sh session.json, or any other runtime
# state — those are exercised, under their own fakes, by the ACs a
# selftest runs AFTER this predicate says burst is configured. This
# predicate only answers "is burst the declared policy", not "is a
# session currently up".
burst_configured() {
  if [ "${BUILD_BURST_ENABLED:-0}" = "1" ]; then
    return 0
  fi

  local env_file="${BURST_LANE_ENV_FILE:-$HOME/.config/wm-burst/.env}"
  [ -r "$env_file" ] || return 1

  local ip id
  { read -r ip; read -r id; } < <(
    bash -c '
      source "$1" >/dev/null 2>&1
      printf "%s\n%s\n" "$BUILDER_IP" "$BUILDER_ID"
    ' _ "$env_file" 2>/dev/null
  )

  [ -n "$ip" ] && [ -n "$id" ]
}
