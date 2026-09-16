#!/usr/bin/env bash
# scripts/lib/cargo-route.sh — single source of truth for the PATH prefix
# a cargo-invoking producer must use, and for the postcondition (burst-
# lane.sh route-check) that attests it actually got there
# (PRD-build-cargo-route-precedence). Fixes the 2026-09-15 defect: extend-
# gate.sh's own PATH guard only armed a shim under the legacy `BURST_LANE=1`
# flag, so producers ran `cargo test` locally against RedBaron's own
# ~/.cargo/bin/cargo while a burst box was actually up (166 route=local vs
# 49 route=burst that day) — the guard and the box's actual availability
# had drifted apart. Sourced (never executed) by extend-gate.sh and by
# burst-lane.sh's route-check/cmd_route_check.
#
# Chain, outermost first: cargo-budget-bin (accounting/concurrency cap —
# ALWAYS first, so every real cargo call, routed to burst or not, is
# counted) -> burst-lane-bin (routes to the burst box when a session is up,
# or falls straight through to real cargo otherwise) -> real cargo.
# cargo-budget-bin/cargo's own real_cargo() implements this by resolving
# to the burst-lane-bin shim itself (not skipping past it) whenever
# burst_configured, guarded against a re-exec loop by BURST_SHIM_ACTIVE=1
# (set by burst-lane-bin/cargo right before it execs the real cargo it
# found, so cargo-budget-bin never re-routes an already-routed call).
#
# burst_configured() comes from burst-configured.sh (the shared "is burst
# the declared policy right now" predicate — BUILD_BURST_ENABLED=1, or a
# real env file naming a live box) — NEVER the legacy per-invocation
# `BURST_LANE=1` flag alone, which only ever meant "an operator armed this
# one shell", not "the box exists to route to".
HERE_CARGO_ROUTE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=burst-configured.sh
if [ -r "$HERE_CARGO_ROUTE/burst-configured.sh" ]; then
  source "$HERE_CARGO_ROUTE/burst-configured.sh"
else
  # Fails open-safe (never configured) if the lib is missing, same
  # convention burst-lane.sh itself already uses for this same source.
  burst_configured() { return 1; }
fi

# cargo_route_scripts_dir -> the scripts/ dir this lib lives under (one
# level up from scripts/lib/), so every caller gets an absolute path
# regardless of its own $0/cwd.
cargo_route_scripts_dir() {
  printf '%s\n' "$(cd "$HERE_CARGO_ROUTE/.." && pwd -P)"
}

# cargo_route_budget_dir / cargo_route_burst_dir -> the two shim
# directories, by name, so every caller (extend-gate.sh's guard,
# burst-lane.sh's route-check, cargo-budget-bin/cargo's own real_cargo())
# names them the same way instead of re-deriving the relative path.
cargo_route_budget_dir() { printf '%s/cargo-budget-bin\n' "$(cargo_route_scripts_dir)"; }
cargo_route_burst_dir()  { printf '%s/burst-lane-bin\n'   "$(cargo_route_scripts_dir)"; }

# cargo_route_path_prefix -> prints the PATH prefix (colon-joined, no
# leading/trailing colon) a cargo-invoking producer should have ahead of
# everything else on $PATH. cargo-budget-bin is ALWAYS first (accounting
# must see every call); burst-lane-bin is appended only when
# burst_configured, so a producer never even sees the burst shim on its
# own $PATH — let alone routes through it — under the RedBaron-local
# default (dormant) policy.
cargo_route_path_prefix() {
  local budget_dir burst_dir
  budget_dir="$(cargo_route_budget_dir)"
  burst_dir="$(cargo_route_burst_dir)"
  if burst_configured; then
    printf '%s:%s' "$budget_dir" "$burst_dir"
  else
    printf '%s' "$budget_dir"
  fi
}

# cargo_route_export_path -> arms THIS shell's own $PATH with the prefix
# above (idempotent: never re-prepends when the prefix is already exactly
# at the front). Used by a caller that wants the route armed for its own
# remaining lifetime (extend-gate.sh's guard) rather than scoped to one
# command (which instead does `PATH="$(cargo_route_path_prefix):$PATH" cmd`
# directly, same as run_unslotted_producer()).
cargo_route_export_path() {
  local prefix
  prefix="$(cargo_route_path_prefix)"
  case ":$PATH:" in
    ":$prefix:"*) : ;;  # already exactly at the front — never duplicate
    *) PATH="$prefix:$PATH" ;;
  esac
  export PATH
}

# ---- cargo_route_current (PRD-build-gate-route-parity-ledger) ------------
# The per-run "where did this call actually go" verdict — distinct from
# cargo_route_path_prefix() above, which only answers "is the shim
# reachable at all" (the declared policy). cargo_route_current() answers
# the narrower question a receipt/journal line needs: local, or
# burst:<server_id>. It re-derives the SAME three inputs
# burst-lane-bin/cargo's own routing `if` (see that file) actually
# branches on, rather than a second, independent guess:
#   1. burst_configured()      — is burst even the declared policy right
#                                 now (same predicate cargo_route_path_
#                                 prefix() already gates on).
#   2. BURST_LANE=1             — the shim's own arm/disarm flag; unset
#                                 (or a bare shell / a /build dispatch
#                                 that never armed it, BURST_LANE_DISPATCH
#                                 set or not) takes the exact fallthrough
#                                 branch the shim's `else` clause does
#                                 (cause=burst-lane-disabled, local).
#   3. session.json / `status --json` — a live, active session with a
#                                 resolvable server_id, the same call the
#                                 shim itself makes before it execs into
#                                 burst-lane.sh run.
# BURST_LANE_DISPATCH is not itself branched on inside the shim (verified
# against burst-lane-bin/cargo and cmd_run — neither reads it) — its role
# here is purely descriptive of the fixture this function's own selftest
# calls "burst-refused": a dispatched /build branch (BURST_LANE_DISPATCH=1)
# that never armed BURST_LANE=1 lands in exactly the same fallthrough as
# case 2 above, local, same as the shim would. Documented rather than
# coded as a separate branch so this function never diverges from the
# shim's actual `if` by inventing a gate the shim itself doesn't have.
#
# cargo_route_session_id -> stdout the active session's server_id, rc 1
# if there is no active session (mirrors the shim's own `status` check:
# "$status_out" != "no active session" && -n "$status_out"). Prefers a
# fixture override ($CARGO_ROUTE_STATUS_JSON — same convention as this
# repo's other env-seam overrides, e.g. BURST_LANE_NOW) so a selftest can
# supply a canned `status --json` payload without a real box, hcloud, or
# ssh in the loop; falls back to the real burst-lane.sh status --json.
cargo_route_session_id() {
  local json
  if [ -n "${CARGO_ROUTE_STATUS_JSON:-}" ]; then
    json="$CARGO_ROUTE_STATUS_JSON"
  else
    local wrapper="$(cargo_route_scripts_dir)/burst-lane.sh"
    [ -x "$wrapper" ] || return 1
    json="$("$wrapper" status --json 2>/dev/null)" || return 1
  fi
  case "$json" in *'"active":true'*) : ;; *) return 1 ;; esac
  local id
  if command -v jq >/dev/null 2>&1; then
    id="$(printf '%s' "$json" | jq -r '.server_id // empty' 2>/dev/null)"
  else
    id="$(printf '%s' "$json" | sed -n 's/.*"server_id":"\{0,1\}\([^,"}]*\)"\{0,1\}.*/\1/p')"
  fi
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# cargo_route_current -> stdout "local" or "burst:<server_id>", rc always 0
# (a route resolver never fails the caller — an unresolvable session is
# "local", not an error, same as the shim's own fallthrough).
cargo_route_current() {
  if ! burst_configured; then
    printf 'local'
    return 0
  fi
  if [ "${BURST_LANE:-0}" != "1" ]; then
    printf 'local'
    return 0
  fi
  local sid
  if sid="$(cargo_route_session_id)" && [ -n "$sid" ]; then
    printf 'burst:%s' "$sid"
  else
    printf 'local'
  fi
  return 0
}
