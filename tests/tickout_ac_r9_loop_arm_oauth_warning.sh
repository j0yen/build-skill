#!/usr/bin/env bash
# tickout_ac_r9_loop_arm_oauth_warning.sh —
# PRD-buildloop-tick-outcome-liveness R9.
#
# loop-arm.sh, on the build host only, warns (stderr) when
# CLAUDE_CODE_OAUTH_TOKEN is absent from `systemctl --user
# show-environment`, never prints the value, and never warns on a
# non-build host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARM="$HERE/../scripts/loop-arm.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"
export LOOP_UNITS_FILE="$TMP/loop-units.txt"
: > "$LOOP_UNITS_FILE"   # no declared units for any host -- isolates this test to R9's own check

fail=0

# --- token present: no warning, and the fake output is never echoed ------
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--user" ] && [ "$2" = "show-environment" ]; then
  echo "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-supersecretvalue"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/systemctl"

out_present="$(LOOP_LIVENESS_HOST="redbaron" LOOP_ARM_BUILD_HOST="redbaron" "$ARM" 2>&1)"
if printf '%s\n' "$out_present" | grep -q 'WARNING'; then
  echo "FAIL: warned even though the token is present: $out_present"
  fail=1
else
  echo "ok  R9: token present -> no warning"
fi
if printf '%s\n' "$out_present" | grep -q 'supersecretvalue'; then
  echo "FAIL: token VALUE leaked into output: $out_present"
  fail=1
else
  echo "ok  R9: token value never printed"
fi

# --- token absent on the build host: warns, exit code unaffected ---------
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--user" ] && [ "$2" = "show-environment" ]; then
  echo "HOME=/home/jsy"
  echo "OTHER=1"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/systemctl"

out_absent="$(LOOP_LIVENESS_HOST="redbaron" LOOP_ARM_BUILD_HOST="redbaron" "$ARM" 2>&1)"
rc_absent=$?
if printf '%s\n' "$out_absent" | grep -q 'WARNING.*CLAUDE_CODE_OAUTH_TOKEN'; then
  echo "ok  R9: token absent on build host -> WARNING printed"
else
  echo "FAIL: expected a WARNING line: $out_absent"
  fail=1
fi
[ "$rc_absent" -eq 0 ] && echo "ok  R9: warning does not change exit code (nothing declared -> 0)" || { echo "FAIL: rc=$rc_absent"; fail=1; }

# --- token absent, but NOT the build host: no warning ---------------------
out_other_host="$(LOOP_LIVENESS_HOST="carbon" LOOP_ARM_BUILD_HOST="redbaron" "$ARM" 2>&1)"
if printf '%s\n' "$out_other_host" | grep -q 'WARNING'; then
  echo "FAIL: warned on a non-build host: $out_other_host"
  fail=1
else
  echo "ok  R9: non-build host -> no warning regardless of token state"
fi

exit "$fail"
