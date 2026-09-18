#!/usr/bin/env bash
# host-contract-selftest.sh — PRD-build-host-contract AC1, AC2, AC4, AC5,
# and the journal-dedup half of AC6.
#
# Every case isolates BUILD_STATE_DIR/BUILD_JOURNAL_ROOT under a
# disposable tempdir, and overrides host-contract.sh's binary hooks
# (HOST_CONTRACT_DF/SYSTEMCTL/SYSTEMD_RUN/FUSER) with small fixture
# scripts rather than touching the real host — same shape as gate-red-
# tick-selftest.sh's fake `gh`.
#
# Run: bash scripts/host-contract-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HC="$HERE/host-contract.sh"
[ -x "$HC" ] || { echo "selftest: $HC not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/host-contract-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}
today_file() { printf '%s/%s.md\n' "$1" "$(date -u +%F)"; }

# A fake systemctl: `show-environment` prints from a fixture file passed
# via $FAKE_MGR_ENV; `is-active NAME` reads state/<name>.active (present
# = active); `set-environment K=V` appends to $FAKE_MGR_ENV; `enable
# --now NAME` writes state/<name>.active.
make_fake_systemctl() {
  local dir="$1" mgr_env="$2"
  mkdir -p "$dir"
  cat > "$dir/systemctl" <<FAKESC
#!/usr/bin/env bash
MGR_ENV="$mgr_env"
if [ "\$1" = "--user" ] && [ "\$2" = "show-environment" ]; then
  cat "\$MGR_ENV" 2>/dev/null
  exit 0
fi
if [ "\$1" = "--user" ] && [ "\$2" = "is-active" ]; then
  [ -f "\$(dirname "\$MGR_ENV")/\$3.active" ] && { echo active; exit 0; }
  echo inactive; exit 3
fi
if [ "\$1" = "--user" ] && [ "\$2" = "set-environment" ]; then
  name="\${3%%=*}"
  grep -v "^\${name}=" "\$MGR_ENV" 2>/dev/null > "\$MGR_ENV.tmp" || true
  mv -f "\$MGR_ENV.tmp" "\$MGR_ENV"
  echo "\$3" >> "\$MGR_ENV"
  exit 0
fi
if [ "\$1" = "--user" ] && [ "\$2" = "enable" ] && [ "\$3" = "--now" ]; then
  touch "\$(dirname "\$MGR_ENV")/\$4.active"
  exit 0
fi
exit 0
FAKESC
  chmod +x "$dir/systemctl"
}

# A fake df: reads pcent/avail from env-provided fixture values, keyed by
# the queried path via $FAKE_DF_MAP (path\tpcent\tavail_kb per line).
make_fake_df() {
  local dir="$1" map="$2"
  mkdir -p "$dir"
  cat > "$dir/df" <<FAKEDF
#!/usr/bin/env bash
MAP="$map"
mode=""
path=""
for a in "\$@"; do
  case "\$a" in
    --output=pcent) mode=pcent ;;
    --output=avail) mode=avail ;;
    -k) : ;;
    *) path="\$a" ;;
  esac
done
line="\$(awk -F'\t' -v p="\$path" '\$1==p{print}' "\$MAP" | tail -n1)"
pcent="\$(printf '%s' "\$line" | cut -f2)"
avail="\$(printf '%s' "\$line" | cut -f3)"
echo "\${mode}"
if [ "\$mode" = pcent ]; then echo "\${pcent:-0}%"; else echo "\${avail:-999999999}"; fi
FAKEDF
  chmod +x "$dir/df"
}

# ============================================================================
# AC1 — manager env lacking TMPDIR -> manager-env:TMPDIR=drift(unset), exit 2.
# ============================================================================
D="$T/ac1"; mkdir -p "$D/journal" "$D/state" "$D/bin"
mgr_env="$D/state/mgr-env.txt"
: > "$mgr_env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok\nCLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0\n' > "$mgr_env"
make_fake_systemctl "$D/bin" "$mgr_env"
dfmap="$D/state/df-map.tsv"
printf '/tmp\t10\t999999999\n/\t10\t999999999\n/mnt/data\t10\t999999999\n' > "$dfmap"
make_fake_df "$D/bin" "$dfmap"
out="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" \
  HOST_CONTRACT_SYSTEMCTL="$D/bin/systemctl" HOST_CONTRACT_DF="$D/bin/df" \
  HOST_CONTRACT_SYSTEMD_RUN=/bin/true HOST_CONTRACT_FUSER=/bin/true \
  "$HC" check --fast)"
rc=$?
expect "AC1 exit 2" "[ $rc -eq 2 ]"
expect "AC1 line matches manager-env:TMPDIR=drift(unset)" "grep -q '^manager-env:TMPDIR=drift(unset)' <<<'$out'"

# ============================================================================
# AC2 — /tmp at 71% -> drift(71%) severity critical, exit 2; at 69% -> ok.
# ============================================================================
D="$T/ac2"; mkdir -p "$D/journal" "$D/state" "$D/bin"
mgr_env="$D/state/mgr-env.txt"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok\nCLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0\nTMPDIR=/mnt/data/tmp\n' > "$mgr_env"
make_fake_systemctl "$D/bin" "$mgr_env"
mkdir -p "$D/tmpdir"
dfmap="$D/state/df-map.tsv"
printf '/tmp\t71\t999999999\n/\t10\t999999999\n/mnt/data\t10\t999999999\n%s\t10\t999999999\n' "$D/tmpdir" > "$dfmap"
make_fake_df "$D/bin" "$dfmap"
out="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" \
  HOST_CONTRACT_SYSTEMCTL="$D/bin/systemctl" HOST_CONTRACT_DF="$D/bin/df" \
  HOST_CONTRACT_TMPDIR_EXPECTED="$D/tmpdir" \
  HOST_CONTRACT_SYSTEMD_RUN=/bin/true HOST_CONTRACT_FUSER=/bin/true \
  "$HC" check --fast)"
rc=$?
expect "AC2(71%) exit 2" "[ $rc -eq 2 ]"
expect "AC2(71%) line matches tmp-usage:/tmp=drift(71%) severity=critical" \
  "grep -q '^tmp-usage:/tmp=drift(71%) severity=critical' <<<'$out'"

printf '/tmp\t69\t999999999\n/\t10\t999999999\n/mnt/data\t10\t999999999\n%s\t10\t999999999\n' "$D/tmpdir" > "$dfmap"
out="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" \
  HOST_CONTRACT_SYSTEMCTL="$D/bin/systemctl" HOST_CONTRACT_DF="$D/bin/df" \
  HOST_CONTRACT_TMPDIR_EXPECTED="$D/tmpdir" \
  HOST_CONTRACT_SYSTEMD_RUN=/bin/true HOST_CONTRACT_FUSER=/bin/true \
  "$HC" check --fast)"
expect "AC2(69%) line is tmp-usage:/tmp=ok" "grep -q '^tmp-usage:/tmp=ok' <<<'$out'"

# ============================================================================
# AC6 (journal half) — same drifted key on a second tick is not re-journaled;
# a recovered key journals `recovered`.
# ============================================================================
jf="$(today_file "$D/journal")"
expect "AC6 exactly one drift line for tmp-usage:/tmp" \
  "[ \"\$(grep -c '  host-contract  tmp-usage:/tmp  drift  ' '$jf' 2>/dev/null)\" = 1 ]"
expect "AC6 one recovered line for tmp-usage:/tmp" \
  "[ \"\$(grep -c '  host-contract  tmp-usage:/tmp  recovered  ' '$jf' 2>/dev/null)\" = 1 ]"
# Run again unchanged (still 69%) -> no new lines of either kind.
BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" \
  HOST_CONTRACT_SYSTEMCTL="$D/bin/systemctl" HOST_CONTRACT_DF="$D/bin/df" \
  HOST_CONTRACT_TMPDIR_EXPECTED="$D/tmpdir" \
  HOST_CONTRACT_SYSTEMD_RUN=/bin/true HOST_CONTRACT_FUSER=/bin/true \
  "$HC" check --fast >/dev/null
expect "AC6 still exactly one recovered line after an unchanged tick" \
  "[ \"\$(grep -c '  host-contract  tmp-usage:/tmp  recovered  ' '$jf' 2>/dev/null)\" = 1 ]"

# ============================================================================
# AC4 — self-heal key: apply flips timer:tmp-scratch-reap.timer active, next
# check is ok. Operator key: apply prints the command, changes nothing.
# ============================================================================
D="$T/ac4"; mkdir -p "$D/journal" "$D/state" "$D/bin"
mgr_env="$D/state/mgr-env.txt"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok\nCLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0\nTMPDIR=/mnt/data/tmp\n' > "$mgr_env"
make_fake_systemctl "$D/bin" "$mgr_env"
dfmap="$D/state/df-map.tsv"
printf '/tmp\t10\t999999999\n/\t10\t999999999\n/mnt/data\t10\t999999999\n/mnt/data/tmp\t10\t999999999\n' > "$dfmap"
make_fake_df "$D/bin" "$dfmap"
mkdir -p "$D/state/mnt-data-tmp"
env_common=(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state"
  HOST_CONTRACT_SYSTEMCTL="$D/bin/systemctl" HOST_CONTRACT_DF="$D/bin/df"
  HOST_CONTRACT_TMPDIR_EXPECTED="$D/state/mnt-data-tmp"
  HOST_CONTRACT_SYSTEMD_RUN=/bin/true HOST_CONTRACT_FUSER=/bin/true)
out="$(env "${env_common[@]}" "$HC" check --fast)"
expect "AC4 pre-apply timer is drift" "grep -q '^timer:tmp-scratch-reap.timer=drift' <<<'$out'"
env "${env_common[@]}" "$HC" apply timer:tmp-scratch-reap.timer >/dev/null
apply_rc=$?
expect "AC4 apply self-heal exit 0" "[ $apply_rc -eq 0 ]"
out2="$(env "${env_common[@]}" "$HC" check --fast)"
expect "AC4 post-apply timer is ok" "grep -q '^timer:tmp-scratch-reap.timer=ok' <<<'$out2'"

apply_out="$(env "${env_common[@]}" "$HC" apply "disk:/")"
apply_rc2=$?
expect "AC4 apply operator key exit 3" "[ $apply_rc2 -eq 3 ]"
expect "AC4 apply operator key prints a command" "grep -qi 'free space on /' <<<'$apply_out'"
expect "AC4 apply operator key did not touch mgr-env" "! grep -q 'disk' '$mgr_env'"

# ============================================================================
# AC5 — unit-env-inheritance: ok only if the probed unit sees all three
# vars; a fixture manager env missing one reports drift(missing:<var>).
# ============================================================================
D="$T/ac5"; mkdir -p "$D/journal" "$D/state" "$D/bin"
cat > "$D/bin/systemd-run" <<'FAKESR'
#!/usr/bin/env bash
# Emulates the probe unit: echoes back only the env vars this fake
# "manager env" (FAKE_UNIT_ENV) actually carries.
IFS=',' read -r -a present <<< "${FAKE_UNIT_ENV:-}"
have() { local n; for n in "${present[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }
have TOK && echo "TOK=tok"
have CEIL && echo "CEIL=0"
have TMP && echo "TMP=/mnt/data/tmp"
exit 0
FAKESR
chmod +x "$D/bin/systemd-run"
out="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" \
  HOST_CONTRACT_SYSTEMD_RUN="$D/bin/systemd-run" FAKE_UNIT_ENV="TOK,CEIL,TMP" \
  HOST_CONTRACT_SYSTEMCTL=/bin/true HOST_CONTRACT_DF=/bin/true HOST_CONTRACT_FUSER=/bin/true \
  "$HC" check --fast)"
expect "AC5 all-present -> ok" "grep -q '^unit-env-inheritance=ok' <<<'$out'"

out2="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" \
  HOST_CONTRACT_SYSTEMD_RUN="$D/bin/systemd-run" FAKE_UNIT_ENV="TOK,CEIL" \
  HOST_CONTRACT_SYSTEMCTL=/bin/true HOST_CONTRACT_DF=/bin/true HOST_CONTRACT_FUSER=/bin/true \
  "$HC" check --fast)"
expect "AC5 missing TMPDIR -> drift(missing:TMPDIR)" \
  "grep -q '^unit-env-inheritance=drift(missing:TMPDIR)' <<<'$out2'"

echo "host-contract-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
