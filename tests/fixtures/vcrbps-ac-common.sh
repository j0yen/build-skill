# vcrbps-ac-common.sh — shared helper for the tests/vcrbps_ac<N>_*.sh
# per-AC wrapper files (PRD-build-verified-completed-realbox-perserver,
# test_prefix `vcrbps`). scripts/vcrbps-selftest.sh already exercises this
# PRD's ACs as a set of named `ok  <label>` assertions against the real
# verified-completed.sh code, run against disposable fixture repos/PRDs —
# mirroring tests/fixtures/archverify-ac-common.sh's convention exactly (a
# second, independent per-AC test body would drift from the real one and
# prove nothing an edit to the actual script couldn't silently invalidate).
# Each wrapper runs the real suite and requires BOTH that it exits 0 AND
# that the specific labeled assertions for its AC are present in the
# output.
run_suite_and_expect_labels() {  # $@ = "ok  <label>" line or stable substring, one per required assertion
  local here suite out rc fail=0 want
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  suite="$here/../scripts/vcrbps-selftest.sh"
  [ -x "$suite" ] || suite="bash $here/../scripts/vcrbps-selftest.sh"
  out="$(bash "$here/../scripts/vcrbps-selftest.sh" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: vcrbps-selftest.sh exited $rc" >&2
    echo "$out" | tail -60 >&2
    return 1
  fi
  for want in "$@"; do
    if grep -qF "$want" <<<"$out"; then
      echo "ok  $want"
    else
      echo "FAIL: expected label missing from vcrbps-selftest.sh: $want" >&2
      fail=1
    fi
  done
  return $fail
}
