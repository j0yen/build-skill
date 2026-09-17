#!/usr/bin/env bash
# tests/mainpin_main_health_flag_validation.sh — PRD-build-main-verdict-
# pinned-to-landing R6: extend-gate.sh's new `--main-health` flag must
# refuse to run at all unless given `--scope main` and `--head <N>`
# together, must default an omitted `--slug` to the "main-health"
# sentinel, and must refuse to combine with `--pinned-landing` (the two
# describe mutually exclusive things to gate: a landed PRD's own merge
# sha vs. the checkout's bare current HEAD).
#
# Deliberately does NOT run a real gate — same reasoning
# mainpin_pinned_landing_flag_validation.sh already documents (a full
# producer-sequence fixture is a real regression risk on a shared,
# already-loaded build box). Every case here hits `die` before
# extend-gate.sh ever resolves $repo_arg into a real directory, so a
# nonexistent path is a valid, fast, zero-side-effect argument — except
# the one case (all required flags present) which is checked only for
# the ABSENCE of a usage-error message, same convention as
# mainpin_pinned_landing_flag_validation.sh's own "e"/"f" cases.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
EXTEND_GATE="$HERE/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

FAKE_REPO="/nonexistent/mainpin-main-health-flag-validation-fixture"

run() {
  # $1 = label suffix for temp file only; rest are extend-gate.sh args.
  local out
  out="$(mktemp "${TMPDIR:-/tmp}/mainpin-mh-flag-val.XXXXXX")"
  "$EXTEND_GATE" "$FAKE_REPO" "${@:2}" >"$out" 2>&1
  echo "$?:$out"
}

echo "=== --main-health alone (no --scope/--head) ==="
res="$(run a --main-health)"
rc="${res%%:*}"; out="${res#*:}"
expect "bare --main-health is refused (nonzero exit)" "[ $rc -ne 0 ]"
expect "bare --main-health names what's missing" "grep -qi 'main-health requires' \"$out\""
rm -f "$out"

echo "=== --main-health --scope branch --head N (wrong scope) ==="
res="$(run b --main-health --scope branch --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "--main-health with --scope branch (not main) is refused" "[ $rc -ne 0 ]"
rm -f "$out"

echo "=== --main-health --scope main (no --head) ==="
res="$(run c --main-health --scope main)"
rc="${res%%:*}"; out="${res#*:}"
expect "--main-health --scope main without --head is refused" "[ $rc -ne 0 ]"
rm -f "$out"

echo "=== --main-health --pinned-landing together (mutually exclusive) ==="
res="$(run d --main-health --pinned-landing --scope main --slug S --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "--main-health + --pinned-landing together is refused" "[ $rc -ne 0 ]"
expect "the refusal names the mutual-exclusion" "grep -qi 'mutually exclusive' \"$out\""
rm -f "$out"

echo "=== --main-health --scope main --head N (all required, only repo missing) ==="
res="$(run e --main-health --scope main --head deadbeef)"
rc="${res%%:*}"; out="${res#*:}"
expect "all required present: validation passes, fails later on the repo (not a usage error)" \
  "! grep -qi 'main-health requires' \"$out\""
rm -f "$out"

echo "=== regression: --main-health is not required for a plain --scope main run ==="
res="$(run f --dry-run)"
rc="${res%%:*}"; out="${res#*:}"
expect "an ordinary run (no --main-health) never mentions main-health validation" \
  "! grep -qi 'main-health requires' \"$out\""
rm -f "$out"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "mainpin_main_health_flag_validation: ALL PASS"
  exit 0
else
  echo "mainpin_main_health_flag_validation: assertion(s) FAILED"
  exit 1
fi
