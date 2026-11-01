#!/usr/bin/env bash
# dreamamend_ac1_no_ssh_wm_build.sh — dream-amend.sh reads open runs from the
# fleet-dash status.json and never invokes wm-build or ssh (ctl 5462).
#   static : no wm-build / ssh outside comment lines (the mandated refusal text
#            "no wm-build fallback" is the one allowed mention)
#   dynamic: fake wm-build + ssh first on PATH must never be called, match and
#            no-match cases give the expected exit codes
#   selftest: dream-amend.sh --selftest exits 0
# Prints `dreamamend_ac1 PASS` / exit 0, or FAIL lines / exit 1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../scripts/dream-amend.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dreamamend-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

hits="$(grep -nE '(^|[^-[:alnum:]_])wm-build([[:space:]]|$)|\bssh\b' "$S" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'no wm-build fallback')"
[ -z "$hits" ] || fail "wm-build/ssh referenced in code: $hits"

mkdir -p "$T/bin" "$T/prds/build-queue"
for n in wm-build ssh; do
  printf '#!/usr/bin/env bash\ntouch "%s/CALLED-%s"\nexit 99\n' "$T" "$n" > "$T/bin/$n"; chmod +x "$T/bin/$n"
done
printf '#!/usr/bin/env bash\necho allow\n' > "$T/gate"; chmod +x "$T/gate"
pfx="PRD"
printf '# PRD\n\n- Status: queued\n' > "$T/prds/build-queue/$pfx-the-slug.md"
now="$(date +%s)"
printf '{"ts": %s, "hosts": {"redbaron": {"open_runs": [{"id": 7, "slug": "the-slug", "stage": "inner"}]}, "ryzen7": {"open_runs": []}}}\n' "$now" > "$T/match.json"
printf '{"ts": %s, "hosts": {"redbaron": {"open_runs": []}, "ryzen7": {"open_runs": []}}}\n' "$now" > "$T/nomatch.json"
printf '{"ts": 1, "hosts": {"redbaron": {"open_runs": []}, "ryzen7": {"open_runs": []}}}\n' > "$T/stale.json"
printf 'not json' > "$T/bad.json"

run() { # <status-file> -> sets out, rc
  out="$(PATH="$T/bin:$PATH" PRD_DIR="$T/prds" DREAM_AMEND_GATE="$T/gate" FLEET_STATUS="$1" bash "$S" the-slug Falsifier 2>&1)"; rc=$?
}
run "$T/match.json";   { [ "$rc" -eq 2 ] && grep -q 'REFUSED: run 7 is open on redbaron' <<<"$out"; } || fail "match: rc=$rc $out"
run "$T/nomatch.json"; { [ "$rc" -eq 0 ] && grep -q '^allow' <<<"$out"; } || fail "no-match: rc=$rc $out"
run "$T/stale.json";   { [ "$rc" -eq 2 ] && grep -q 'fleet status unreadable or stale' <<<"$out"; } || fail "stale: rc=$rc $out"
run "$T/bad.json";     { [ "$rc" -eq 2 ] && grep -q 'fleet status unreadable or stale' <<<"$out"; } || fail "malformed: rc=$rc $out"
ls "$T"/CALLED-* >/dev/null 2>&1 && fail "fake wm-build/ssh was called: $(ls "$T"/CALLED-*)"

bash "$S" --selftest >"$T/selftest.log" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "--selftest rc=$rc: $(tail -3 "$T/selftest.log")"

if [ "$fails" -eq 0 ]; then echo "dreamamend_ac1 PASS"; exit 0; fi
exit 1
