#!/usr/bin/env bash
# seltick-common.sh — shared scratch-fixture harness for the
# tests/seltick_ac*.sh files (PRD-build-select-tick-deterministic).
#
# Every fixture PRD written here is built to actually PASS the real
# prd-lint.sh contract gate that scripts/scan-prds.sh runs internally
# (Status/build_target/Vision:/an `## Acceptance criteria` section with
# one leveled Given/When/Then line) — select-tick.sh's first step is a
# real scan-prds.sh call, so a fixture that can't pass real lint would
# make these tests tautological. Same convention as
# scripts/select-tick-selftest.sh, which these files mirror one AC at a
# time (see that script's own header for the full picture).
#
# Sourced by each tests/seltick_ac*.sh file. Callers must call
# seltick_setup first, seltick_teardown (or rely on the EXIT trap
# seltick_setup installs) last.
set -uo pipefail

SELTICK_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ST="$SELTICK_HERE/../scripts/select-tick.sh"
SELTICK_JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

seltick_setup() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/seltick-ac.XXXXXX")
  trap 'rm -rf "$ROOT"' EXIT
  mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/visions" "$ROOT/state"
  echo "# fixture vision" > "$ROOT/visions/fixture.md"
  echo '{"prds":{}}' > "$ROOT/state/manifest.json"
  JOURNAL="$ROOT/journal.md"
  : > "$JOURNAL"

  FAKE_BURST_READY=false
  FAKE_BURST_WIDTH=8
  FAKE_BURST="$ROOT/fake-burst-lane.sh"
  cat > "$FAKE_BURST" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
  printf '{"gate_ready":%s,"width":%s}\n' "${FAKE_BURST_READY:-false}" "${FAKE_BURST_WIDTH:-0}"
  exit 0
fi
echo '{}'
EOF
  chmod +x "$FAKE_BURST"
}

seltick_run() {
  BUILD_STATE_DIR="$ROOT/state" BUILD_MANIFEST="$ROOT/state/manifest.json" \
    SELECT_TICK_JOURNAL="$JOURNAL" \
    BURST_LANE_SH="$FAKE_BURST" \
    FAKE_BURST_READY="$FAKE_BURST_READY" FAKE_BURST_WIDTH="$FAKE_BURST_WIDTH" \
    "$ST" --prd-dir "$ROOT" "$@"
}

seltick_write_prd() {
  # seltick_write_prd <slug> [build_target] [build_into] [depends_on_filename]
  local slug="$1" bt="${2:-shell}" bi="${3:-}" dep="${4:-}"
  {
    echo "# PRD: $slug"
    echo
    echo "- Status: queued"
    echo "- build_target: $bt"
    [ -n "$bi" ] && echo "- build_into: $bi"
    [ -n "$dep" ] && echo "- Depends-on: $dep"
    echo "- Vision: visions/fixture.md"
    echo
    echo "## Acceptance criteria"
    echo
    echo "1. P0 — Given a fixture, When select-tick runs, Then it is admitted or skipped deterministically."
  } > "$ROOT/build-queue/PRD-$slug.md"
}

seltick_write_continuation_prd() {
  # seltick_write_continuation_prd <slug> <lane> <build_into>
  local slug="$1" lane="$2" bi="$3"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "# PRD: $slug"
    echo
    echo "- Status: building"
    echo "- Lane: $lane $now"
    echo "- build_target: shell"
    echo "- build_into: $bi"
    echo "- Vision: visions/fixture.md"
    echo
    echo "## Acceptance criteria"
    echo
    echo "1. P0 — Given a fixture, When select-tick runs, Then it is admitted or skipped deterministically."
  } > "$ROOT/build-queue/PRD-$slug.md"
}
