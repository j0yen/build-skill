# durheal-ac-common.sh — shared helper for the tests/durheal_ac<N>_*.sh
# per-AC wrapper files (PRD-build-classification-durable-heal).
#
# This PRD's requirements are covered across three already-shipped
# fixture selftests (scripts/mark-needs-classification-selftest.sh,
# scripts/requeue-prd-selftest.sh) plus the manifest-invariants AC test
# this PRD updated (tests/manifest-inv_ac2_needs_classification_lint_pass_
# heals.sh) — one per mechanism: the claim-reproduction gate, the durable
# requeue, and the heal that wires the two together. Duplicating a second,
# hand-written test body per AC here would drift from the real ones and
# prove nothing an edit to the actual scripts could not silently
# invalidate — same reasoning as every sibling common helper (see
# gatewall-ac-common.sh). Each wrapper runs the real suite/test it's
# paired with and requires BOTH that it exits 0 AND that the specific
# labeled assertions for its AC are present in the output.
#
# `want` entries may be a full literal output line OR a stable substring
# of one (grep -F is a substring match).
run_and_expect_labels() {  # $1 = script path (absolute or relative to cwd), $@[2:] = wanted lines/substrings
  local script="$1" out rc fail=0 want
  shift
  [ -x "$script" ] || { echo "FAIL: $script not executable" >&2; return 2; }
  out="$(bash "$script" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $(basename "$script") exited $rc" >&2
    echo "$out" | tail -30 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from $(basename "$script"): $want" >&2
      fail=1
    fi
  done
  return $fail
}
