#!/usr/bin/env bash
# tests/mainpin_pinned_landing_flag_validation.sh — PRD-build-main-verdict-
# pinned-to-landing R3: extend-gate.sh's new `--pinned-landing` flag must
# refuse to run at all unless it is given `--scope main`, `--slug <s>`,
# and `--head <M>` together — a pinned run with any of those missing has
# no well-defined slug/head to widen the journal line with, and R7's own
# spirit ("never gate HEAD as a silent fallback") extends to this flag
# too: better a loud usage refusal than a pinned-looking journal line for
# a run that was not actually pinned to anything.
#
# Deliberately does NOT run a real gate (see main-verdict-pin-gate.sh's
# own tests/mainpin_pin_gate_wiring.sh for the wiring test, and this
# PRD's own manifest note on why a full producer-sequence fixture test
# was pulled from this step: RedBaron was already at load average 28+
# from concurrent tick activity, and each attempt left orphaned
# hermetic-build/mutation-kill/cargo-clean processes running against
# deleted fixture dirs — a real regression risk for a shared box, not
# just this file). Every case here hits `die` before extend-gate.sh ever
# resolves $repo_arg into a real directory, so a nonexistent path is a
# valid, fast, zero-side-effect argument.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

FAKE_REPO="/nonexistent/mainpin-pinned-landing-flag-validation-fixture"

run() {
  # $1 = label suffix for temp file only; rest are extend-gate.sh args.
  local out
  out="$(mktemp "${TMPDIR:-/tmp}/mainpin-flag-val.XXXXXX")"
  "$EXTEND_GATE" "$FAKE_REPO" "${@:2}" >"$out" 2>&1
  echo "$?:$out"
}

echo "=== --pinned-landing alone (no --scope/--slug/--head) ==="
res="$(run a --pinned-landing)"
rc="${res%%:*}"; out="${res#*:}"
expect "bare --pinned-landing is refused (nonzero exit)" "[ $rc -ne 0 ]"
expect "bare --pinned-landing names what's missing" "grep -qi 'pinned-landing requires' \"$out\""
rm -f "$out"

echo "=== --pinned-landing --head M (no --scope main, no --slug) ==="
res="$(run b --pinned-landing --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "--pinned-landing --head alone is refused" "[ $rc -ne 0 ]"
rm -f "$out"

echo "=== --pinned-landing --scope main --head M (no --slug) ==="
res="$(run c --pinned-landing --scope main --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "--pinned-landing --scope main --head without --slug is refused" "[ $rc -ne 0 ]"
rm -f "$out"

echo "=== --pinned-landing --scope branch --slug S --head M (wrong scope) ==="
res="$(run d --pinned-landing --scope branch --slug S --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "--pinned-landing with --scope branch (not main) is refused" "[ $rc -ne 0 ]"
rm -f "$out"

echo "=== --pinned-landing --scope main --slug S --head M (all three, only repo missing) ==="
res="$(run e --pinned-landing --scope main --slug S --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "all three present: validation passes, fails later on the repo (not a usage error)" \
  "! grep -qi 'pinned-landing requires' \"$out\""
rm -f "$out"

echo "=== regression: --pinned-landing is not required for a plain --scope main run ==="
res="$(run f --dry-run)"
rc="${res%%:*}"; out="${res#*:}"
expect "an ordinary run (no --pinned-landing) never mentions pinned-landing validation" \
  "! grep -qi 'pinned-landing requires' \"$out\""
rm -f "$out"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_pinned_landing_flag_validation: ALL PASS"
  exit 0
else
  echo "mainpin_pinned_landing_flag_validation: assertion(s) FAILED"
  exit 1
fi
