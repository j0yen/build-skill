#!/usr/bin/env bash
# cargoroute_ac5_head_abbreviated_sha.sh —
# PRD-build-cargo-route-precedence AC5 (spec test e). Given extend-gate.sh
# --head now resolves its argument via `git rev-parse --verify
# <sha>^{commit}` and compares FULL SHAs, when called with the correct
# abbreviated HEAD SHA it is accepted (never refused as a mismatch); when
# called with a valid-but-wrong commit's short SHA it refuses (exit 5)
# naming BOTH full SHAs; when called with an unresolvable short ref it
# also refuses (exit 5), saying so explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/cargoroute-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cargoroute AC5: a valid-but-wrong short SHA refuses (exit 5)" \
  "ok  cargoroute AC5: refusal names actual HEAD's full SHA" \
  "ok  cargoroute AC5: refusal names the given short ref's own full SHA (not the abbreviated form)" \
  "ok  cargoroute AC5: an unresolvable short ref refuses (exit 5)" \
  "ok  cargoroute AC5: unresolvable-ref message says it does not resolve" \
  "ok  cargoroute AC5: the correct short SHA is accepted (never refused as a head mismatch, exit != 5)"
