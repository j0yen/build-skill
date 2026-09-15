#!/usr/bin/env bash
# reenable_ac12_status_json_fields.sh — PRD-build-burst-dispatch-reenable AC12.
#
# Given any of the states above, When `status --json` runs, Then it
# reports image_id, image_source, bake_age_h, proof_age_h,
# proof_routed, enabled and `enable` reads only this output.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC1 / AC12: the create-image call carries no -o/--output flag" \
  "ok  reenable AC12a: status --json reports image_source=env with no snapshot.json" \
  "ok  reenable AC12a: bake_age_h is null (never baked)" \
  "ok  reenable AC12a: proof_age_h/proof_routed are null (never proved)" \
  "ok  reenable AC12a: enabled is false (no drop-in)" \
  "ok  reenable AC12a: status --json uses compact separators (cmd_route_check's *'active':true* substring match must still fire)" \
  "ok  reenable AC12b: image_source=baked" \
  "ok  reenable AC12b: bake_age_h is a non-negative number" \
  "ok  reenable AC12c: proof_routed is true" \
  "ok  reenable AC12c: proof_age_h is a non-negative number" \
  "ok  reenable AC12d: enabled is true when the drop-in file exists" \
  "ok  reenable AC12e: text-mode 'no active session' is unchanged, byte-exact, single-line"
