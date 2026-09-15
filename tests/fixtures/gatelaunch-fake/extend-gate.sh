#!/usr/bin/env bash
# fake extend-gate.sh for tests/gatelaunch_ac*.sh (PRD-build-gate-launch-survives-tick).
# Mirrors just the surface gate-launch.sh/gate-then-land.sh depend on:
# <build_into> --head <sha> --scope main|branch --slug <slug>
# [--print-verdict-path] [--project-root <rel> ...ignored...].
# Controlled entirely by env vars so one fixture covers every scenario:
#   FAKE_EXTEND_GATE_SLEEP           seconds to sleep before exiting (default 0)
#   FAKE_EXTEND_GATE_RC              exit code (default 0)
#   FAKE_EXTEND_GATE_WRITE_RECEIPT   1 (default) writes a receipt + last-verdict.json; 0 writes neither
#   FAKE_EXTEND_GATE_VERDICT         verdict written into last-verdict.json (default pass)
#   FAKE_EXTEND_GATE_LOG             appends one "slug=.. head=.. scope=.." line per invocation
set -uo pipefail

repo="${1:-}"; shift || true
head_sha="" scope="" slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head_sha="$2"; shift 2 ;;
    --scope) scope="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --print-verdict-path)
      echo "$repo/target/autobuilder/last-verdict.json"
      exit 0
      ;;
    *) shift ;;
  esac
done

[ -n "${FAKE_EXTEND_GATE_LOG:-}" ] && printf 'slug=%s head=%s scope=%s\n' "$slug" "$head_sha" "$scope" >> "$FAKE_EXTEND_GATE_LOG"

sleep "${FAKE_EXTEND_GATE_SLEEP:-0}"

if [ "${FAKE_EXTEND_GATE_WRITE_RECEIPT:-1}" = "1" ]; then
  mkdir -p "$repo/target/autobuilder/receipts"
  echo '{}' > "$repo/target/autobuilder/receipts/r1.json"
  printf '{"verdict":"%s"}' "${FAKE_EXTEND_GATE_VERDICT:-pass}" > "$repo/target/autobuilder/last-verdict.json"
fi

exit "${FAKE_EXTEND_GATE_RC:-0}"
