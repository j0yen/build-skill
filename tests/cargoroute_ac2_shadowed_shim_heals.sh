#!/usr/bin/env bash
# cargoroute_ac2_shadowed_shim_heals.sh —
# PRD-build-cargo-route-precedence AC2 (spec test b). Given a $PATH with
# NEITHER shim dir on it at all but burst configured and the shim files
# genuinely present on disk, when route-check runs, then it self-heals
# (state=healed), exits 0, journals "route healed" once to the shared
# burst-lane journal, and a second call against the same per-gate route
# log never double-journals it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/cargoroute-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cargoroute AC2: PATH-without-either-shim self-heals (state=healed)" \
  "ok  cargoroute AC2: healed exits 0 (never fatal)" \
  "ok  cargoroute AC2: healed journals to the shared burst-lane journal" \
  "ok  cargoroute AC2: a second call against the SAME per-gate route log never double-journals"
