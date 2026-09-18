#!/usr/bin/env bash
# manifest-inv_ac8_red_archived_alarmed.sh — PRD-build-gate-red-retraction
# AC8 (manifest-invariants.sh half): gate-red.json still names a slug the
# manifest already calls archived (a retraction gate-red-summary.sh missed
# because it ran before the archive landed) — report-only alarm class
# `red-archived`, modeled on manifest-inv_ac3_unknown_status_alarmed_
# not_modified.sh. Control case: same fixture, slugR still `queued` -> no
# such alarm fires.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MI="$HERE/../scripts/manifest-invariants.sh"
[ -x "$MI" ] || { echo "ac8: $MI not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

run_case() { # <status> <expect_alarm: yes|no>
  local status="$1" expect_alarm="$2"
  local T
  T="$(mktemp -d "${TMPDIR:-/tmp}/manifest-inv-ac8.XXXXXX")"
  mkdir -p "$T/state/intent" "$T/build-queue" "$T/built-prds" "$T/parked"

  python3 -c "
import json
json.dump({'prds': {'slugR': {'slug': 'slugR', 'status': '$status'}}},
          open('$T/state/manifest.json', 'w'))
"
  echo '{"ts":"2026-01-01T00:00:00Z","red_slugs":["slugR"]}' > "$T/state/gate-red.json"
  before_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"

  out="$(BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" \
         LOCK="$T/state/tick.lock" JOURNAL="$T/journal.md" \
         PATH=/usr/bin:/bin "$MI" --prd-dir "$T" --report)"

  after_hash="$(sha256sum "$T/state/manifest.json" | awk '{print $1}')"
  expect "[$status] manifest byte-identical after --report" "[ '$before_hash' = '$after_hash' ]"

  if [ "$expect_alarm" = yes ]; then
    expect "[$status] --report prints ALARM slugR [red-archived]" \
      "grep -q 'ALARM slugR \[red-archived\]' <<<\"\$out\""
  else
    expect "[$status] --report has no red-archived alarm" \
      "! grep -q '\[red-archived\]' <<<\"\$out\""
  fi

  rm -rf "$T"
}

run_case archived yes
run_case queued no

exit $fail
