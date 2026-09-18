#!/usr/bin/env bash
# host-contract.sh — probe + self-heal for docs/host-contract.md
# (PRD-build-host-contract).
#
# Six outages on 2026-09-18 had one shape: a component relied on an
# ambient default of the RedBaron host and the default silently changed
# or ran out (the auth file, the dispatch lock protocol, PATH order of
# two cargo shims, whether a systemd-run unit inherits the tick's env,
# TMPDIR). This script is the probe half of the fix: it reads the KEYS
# table below (kept in sync with docs/host-contract.md's human-readable
# copy — see that file's own header) and reports drift; the `apply` half
# fixes only the rows docs/host-contract.md marks `self-heal` (env,
# timers, TMPDIR) and otherwise prints the operator command and changes
# nothing.
#
# Usage:
#   host-contract.sh check [--fast]
#       One line per key, "<key>=ok" or "<key>=drift(<observed>)
#       severity=<critical|warn> owner=<operator|self-heal>". --fast
#       skips the auth-file probe (the one row that spends a `claude -p`
#       call) — used by extend-gate.sh at gate start. Journals one
#       `host-contract  <key>  drift|recovered  (observed=…)` line per
#       transition (state/host-contract/last-status.json tracks the
#       previous run so an unchanged key is never re-journaled).
#   host-contract.sh apply <key>
#       Self-heal key: performs the fix, exit 0 (or 1 on failure).
#       Operator key: prints the exact command, changes nothing, exit 3.
#       Unknown key: exit 2.
#   host-contract.sh history
#       Prints the last 7 days' `host-contract  ...  drift|recovered`
#       journal lines, oldest first.
#
# Exit (check): 0 all ok/skip | 1 worst drift is warn | 2 worst drift is
# critical. Exit (apply): 0 fixed | 1 fix failed | 2 unknown key | 3
# operator-owned, no mutation. Exit (history): 0 always.
#
# Env overrides (testing/isolation): HOST_CONTRACT_DF, HOST_CONTRACT_
# SYSTEMCTL, HOST_CONTRACT_SYSTEMD_RUN, HOST_CONTRACT_FUSER,
# HOST_CONTRACT_TMPDIR_EXPECTED, HOST_CONTRACT_AUTH_TTL_S, HOST_CONTRACT_
# AUTH_PROBE_CMD, HOST_CONTRACT_CLAUDE_BIN, HOST_CONTRACT_ENV_D_DIR,
# HOST_CONTRACT_MOUNTS_FILE, REVIEWER_AUTH_FILE, BUILD_STATE_DIR,
# BUILD_JOURNAL_ROOT (see lib/journal.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
CONTRACT_STATE_DIR="$STATE_DIR/host-contract"
LAST_STATUS_FILE="$CONTRACT_STATE_DIR/last-status.json"
AUTH_CACHE_FILE="$CONTRACT_STATE_DIR/auth.json"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

JQ="${JQ:-jq}"
DF="${HOST_CONTRACT_DF:-df}"
SYSTEMCTL="${HOST_CONTRACT_SYSTEMCTL:-systemctl}"
SYSTEMD_RUN="${HOST_CONTRACT_SYSTEMD_RUN:-systemd-run}"
FUSER="${HOST_CONTRACT_FUSER:-fuser}"
ENV_D_DIR="${HOST_CONTRACT_ENV_D_DIR:-$HOME/.config/environment.d}"
HOST_CONTRACT_TMPDIR_EXPECTED="${HOST_CONTRACT_TMPDIR_EXPECTED:-/mnt/data/tmp}"
HOST_CONTRACT_AUTH_TTL_S="${HOST_CONTRACT_AUTH_TTL_S:-21600}"

die() { echo "host-contract: $2" >&2; exit "$1"; }
command -v "$JQ" >/dev/null 2>&1 || die 2 "jq not on \$PATH"

usage() { echo "usage: host-contract.sh {check [--fast]|apply <key>|history}" >&2; }

# ---------------------------------------------------------------------
# KEYS table (parallel arrays, bash-3-compatible — see gate-red-tick.sh's
# phase_names/phase_vals for the same convention). Any change here must
# be mirrored in docs/host-contract.md's table.
# ---------------------------------------------------------------------
KEY_NAMES=(
  "manager-env:CLAUDE_CODE_OAUTH_TOKEN"
  "manager-env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"
  "manager-env:TMPDIR"
  "tmp-usage:/tmp"
  "timer:tmp-scratch-reap.timer"
  "auth-file:90-claude-oauth.conf"
  "path:autobuilder"
  "path:cargo-shims"
  "unit-env-inheritance"
  "lock-protocol"
  "disk:/"
  "disk:/mnt/data"
  "mount:/tmp"
)
KEY_SEVERITY=(critical critical critical critical critical critical warn critical critical critical critical critical warn)
KEY_OWNER=(operator self-heal self-heal operator self-heal operator operator operator self-heal operator operator operator operator)

# ---------------------------------------------------------------------
# Predicates. Each sets RESULT (ok|drift) and OBSERVED (drift detail).
# ---------------------------------------------------------------------
RESULT=""
OBSERVED=""

get_manager_env_val() {
  "$SYSTEMCTL" --user show-environment 2>/dev/null | sed -n "s/^$1=//p" | tail -n1
}

check_manager_env_token() {
  local v; v="$(get_manager_env_val CLAUDE_CODE_OAUTH_TOKEN)"
  if [ -z "$v" ]; then RESULT=drift; OBSERVED="unset"; else RESULT=ok; fi
}

check_manager_env_ceiling() {
  local v; v="$(get_manager_env_val CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS)"
  if [ "$v" = "0" ]; then RESULT=ok; else RESULT=drift; OBSERVED="${v:-unset}"; fi
}

check_manager_env_tmpdir() {
  local v; v="$(get_manager_env_val TMPDIR)"
  if [ -z "$v" ]; then RESULT=drift; OBSERVED="unset"; return; fi
  if [ "$v" != "$HOST_CONTRACT_TMPDIR_EXPECTED" ]; then RESULT=drift; OBSERVED="$v"; return; fi
  if [ ! -d "$v" ]; then RESULT=drift; OBSERVED="missing-dir:$v"; return; fi
  if [ ! -w "$v" ]; then RESULT=drift; OBSERVED="not-writable:$v"; return; fi
  local avail_kb avail_g
  avail_kb="$("$DF" --output=avail -k "$v" 2>/dev/null | tail -n1 | tr -d ' ')"
  case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac
  avail_g=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_g" -lt 50 ]; then RESULT=drift; OBSERVED="${avail_g}G-free"; else RESULT=ok; fi
}

check_tmp_usage() {
  local pct; pct="$("$DF" --output=pcent /tmp 2>/dev/null | tail -n1 | tr -d ' %')"
  case "$pct" in ''|*[!0-9]*) RESULT=ok; return ;; esac
  if [ "$pct" -ge 70 ]; then RESULT=drift; OBSERVED="${pct}%"; else RESULT=ok; fi
}

check_timer() {
  local st; st="$("$SYSTEMCTL" --user is-active tmp-scratch-reap.timer 2>/dev/null)"
  if [ "$st" = "active" ]; then RESULT=ok; else RESULT=drift; OBSERVED="${st:-inactive}"; fi
}

resolve_auth_token() {  # sets AUTH_TOKEN/AUTH_SOURCE — same order as
  # extend-gate.sh's resolve_reviewer_auth (directive 13): env, then
  # REVIEWER_AUTH_FILE, then `systemctl --user show-environment`.
  AUTH_TOKEN=""; AUTH_SOURCE=""
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    AUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"; AUTH_SOURCE="env"; return 0
  fi
  local f="${REVIEWER_AUTH_FILE:-$HOME/.config/environment.d/90-claude-oauth.conf}"
  if [ -f "$f" ]; then
    local tok; tok="$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$f" 2>/dev/null | tail -n1)"
    if [ -n "$tok" ]; then AUTH_TOKEN="$tok"; AUTH_SOURCE="environment.d"; return 0; fi
  fi
  if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    local tok; tok="$(get_manager_env_val CLAUDE_CODE_OAUTH_TOKEN)"
    if [ -n "$tok" ]; then AUTH_TOKEN="$tok"; AUTH_SOURCE="systemctl"; return 0; fi
  fi
  return 1
}

check_auth_file() {
  mkdir -p "$CONTRACT_STATE_DIR" 2>/dev/null || true
  local now_epoch; now_epoch=$(date -u +%s)
  if [ -r "$AUTH_CACHE_FILE" ]; then
    local cached_epoch cached_ok
    cached_epoch="$("$JQ" -r '.checked_epoch // 0' "$AUTH_CACHE_FILE" 2>/dev/null)"
    cached_ok="$("$JQ" -r '.ok // false' "$AUTH_CACHE_FILE" 2>/dev/null)"
    case "$cached_epoch" in ''|*[!0-9]*) cached_epoch=0 ;; esac
    if [ $(( now_epoch - cached_epoch )) -lt "$HOST_CONTRACT_AUTH_TTL_S" ]; then
      if [ "$cached_ok" = "true" ]; then
        RESULT=ok
      else
        RESULT=drift; OBSERVED="$("$JQ" -r '.reason // "auth-missing"' "$AUTH_CACHE_FILE" 2>/dev/null)"
      fi
      return
    fi
  fi
  if ! resolve_auth_token; then
    RESULT=drift; OBSERVED="auth-missing:env,environment.d,systemctl"
    "$JQ" -n --argjson e "$now_epoch" --arg r "$OBSERVED" \
      '{checked_epoch:$e, ok:false, reason:$r}' > "$AUTH_CACHE_FILE" 2>/dev/null || true
    return
  fi
  local probe_rc
  if [ -n "${HOST_CONTRACT_AUTH_PROBE_CMD:-}" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$AUTH_TOKEN" timeout 60 bash -c "$HOST_CONTRACT_AUTH_PROBE_CMD" >/dev/null 2>&1
    probe_rc=$?
  else
    CLAUDE_CODE_OAUTH_TOKEN="$AUTH_TOKEN" timeout 60 "${HOST_CONTRACT_CLAUDE_BIN:-claude}" \
      -p "reply with the single word ok" >/dev/null 2>&1
    probe_rc=$?
  fi
  if [ "$probe_rc" -eq 0 ]; then
    RESULT=ok
    "$JQ" -n --argjson e "$now_epoch" '{checked_epoch:$e, ok:true, reason:""}' > "$AUTH_CACHE_FILE" 2>/dev/null || true
  else
    RESULT=drift; OBSERVED="probe-failed:rc=$probe_rc:source=$AUTH_SOURCE"
    "$JQ" -n --argjson e "$now_epoch" --arg r "$OBSERVED" \
      '{checked_epoch:$e, ok:false, reason:$r}' > "$AUTH_CACHE_FILE" 2>/dev/null || true
  fi
}

check_path_autobuilder() {
  local n; n=$(command -v -a autobuilder 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 1 ]; then RESULT=drift; OBSERVED="${n}-on-PATH"; else RESULT=ok; fi
}

check_path_cargo_shims() {
  local budget_idx=-1 rustbuild_idx=-1 i=0 dir
  local IFS=':'
  for dir in $PATH; do
    case "$dir" in
      */build/scripts/cargo-budget-bin) [ "$budget_idx" -eq -1 ] && budget_idx=$i ;;
      */rustbuild/bin) [ "$rustbuild_idx" -eq -1 ] && rustbuild_idx=$i ;;
    esac
    i=$((i+1))
  done
  if [ "$budget_idx" -eq -1 ] || [ "$rustbuild_idx" -eq -1 ]; then RESULT=ok; return; fi
  if [ "$budget_idx" -lt "$rustbuild_idx" ]; then RESULT=ok; else RESULT=drift; OBSERVED="rustbuild-before-budget"; fi
}

check_unit_env_inheritance() {
  local out
  out="$("$SYSTEMD_RUN" --user --wait --collect -p Type=oneshot /bin/sh -c \
    'echo "TOK=${CLAUDE_CODE_OAUTH_TOKEN:-}"; echo "CEIL=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-}"; echo "TMP=${TMPDIR:-}"' \
    2>/dev/null)"
  local missing=()
  grep -q '^TOK=.\+' <<<"$out" || missing+=("CLAUDE_CODE_OAUTH_TOKEN")
  grep -q '^CEIL=.\+' <<<"$out" || missing+=("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS")
  grep -q '^TMP=.\+' <<<"$out" || missing+=("TMPDIR")
  if [ "${#missing[@]}" -eq 0 ]; then
    RESULT=ok
  else
    RESULT=drift
    local IFS=','; OBSERVED="missing:${missing[*]}"
  fi
}

check_lock_protocol() {
  local bad=() lockfile pid holders comm ccomm child_pid child_ok
  shopt -s nullglob
  for lockfile in "$STATE_DIR"/prd-*.lock; do
    holders="$("$FUSER" "$lockfile" 2>/dev/null)"
    for pid in $holders; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
      if [ "$comm" != "flock" ]; then
        bad+=("$(basename "$lockfile"):pid=$pid:comm=${comm:-none}")
        continue
      fi
      child_ok=false
      for child_pid in $(pgrep -P "$pid" 2>/dev/null); do
        ccomm="$(ps -o comm= -p "$child_pid" 2>/dev/null)"
        case "$ccomm" in claude*) child_ok=true ;; esac
      done
      $child_ok || bad+=("$(basename "$lockfile"):pid=$pid:no-live-claude-child")
    done
  done
  shopt -u nullglob
  if [ "${#bad[@]}" -eq 0 ]; then
    RESULT=ok
  else
    RESULT=drift
    local IFS=','; OBSERVED="${bad[*]}"
  fi
}

check_disk_pct() {  # $1=path $2=critical-threshold-pct
  local pct; pct="$("$DF" --output=pcent "$1" 2>/dev/null | tail -n1 | tr -d ' %')"
  case "$pct" in ''|*[!0-9]*) RESULT=ok; return ;; esac
  if [ "$pct" -ge "$2" ]; then RESULT=drift; OBSERVED="${pct}%"; else RESULT=ok; fi
}

check_disk_avail_g() {  # $1=path $2=min-free-GiB
  local avail_kb avail_g
  avail_kb="$("$DF" --output=avail -k "$1" 2>/dev/null | tail -n1 | tr -d ' ')"
  case "$avail_kb" in ''|*[!0-9]*) RESULT=ok; return ;; esac
  avail_g=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_g" -lt "$2" ]; then RESULT=drift; OBSERVED="${avail_g}G-free"; else RESULT=ok; fi
}

check_disk_root() { check_disk_pct / 90; }
check_disk_mnt_data() { check_disk_avail_g /mnt/data 200; }

check_mount_tmp() {
  local mounts_file="${HOST_CONTRACT_MOUNTS_FILE:-/proc/mounts}"
  if [ -r "$mounts_file" ] && awk '$2=="/tmp"{print $1}' "$mounts_file" | grep -q '/mnt/data/tmp'; then
    RESULT=ok
  else
    RESULT=drift; OBSERVED="not-bind-mounted"
  fi
}

run_predicate() {
  RESULT=""; OBSERVED=""
  case "$1" in
    "manager-env:CLAUDE_CODE_OAUTH_TOKEN") check_manager_env_token ;;
    "manager-env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS") check_manager_env_ceiling ;;
    "manager-env:TMPDIR") check_manager_env_tmpdir ;;
    "tmp-usage:/tmp") check_tmp_usage ;;
    "timer:tmp-scratch-reap.timer") check_timer ;;
    "auth-file:90-claude-oauth.conf") check_auth_file ;;
    "path:autobuilder") check_path_autobuilder ;;
    "path:cargo-shims") check_path_cargo_shims ;;
    "unit-env-inheritance") check_unit_env_inheritance ;;
    "lock-protocol") check_lock_protocol ;;
    "disk:/") check_disk_root ;;
    "disk:/mnt/data") check_disk_mnt_data ;;
    "mount:/tmp") check_mount_tmp ;;
    *) RESULT=ok ;;
  esac
}

# ---------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------
operator_command_for() {
  case "$1" in
    "manager-env:CLAUDE_CODE_OAUTH_TOKEN") echo "rotate/re-export the token, then: systemctl --user set-environment CLAUDE_CODE_OAUTH_TOKEN=<token>" ;;
    "tmp-usage:/tmp") echo "clear space on /tmp, or run: systemctl --user enable --now tmp-scratch-reap.timer" ;;
    "auth-file:90-claude-oauth.conf") echo "rotate/re-export the token into $ENV_D_DIR/90-claude-oauth.conf" ;;
    "path:autobuilder") echo "remove the ~/.cargo/bin 0.9.0 autobuilder shadow binary from PATH" ;;
    "path:cargo-shims") echo "fix PATH so cargo-budget-bin precedes rustbuild/bin" ;;
    "lock-protocol") echo "investigate and kill the stale lock holder named in the drift observation" ;;
    "disk:/") echo "free space on / (>= 90% used)" ;;
    "disk:/mnt/data") echo "free space on /mnt/data (< 200G free)" ;;
    "mount:/tmp") echo "bind-mount /tmp onto /mnt/data/tmp in /etc/fstab" ;;
    *) echo "(no documented operator command for $1 — see docs/host-contract.md)" ;;
  esac
}

write_environment_d_and_set() {  # $1=name $2=value $3=filename
  mkdir -p "$ENV_D_DIR" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" > "$ENV_D_DIR/$3"
  "$SYSTEMCTL" --user set-environment "$1=$2" 2>/dev/null
}

apply_key() {
  local key="$1" owner="" i
  for i in "${!KEY_NAMES[@]}"; do
    [ "${KEY_NAMES[$i]}" = "$key" ] && owner="${KEY_OWNER[$i]}"
  done
  if [ -z "$owner" ]; then echo "host-contract: apply: unknown key: $key" >&2; return 2; fi
  if [ "$owner" = "operator" ]; then
    echo "host-contract: $key is operator-owned; apply changes nothing. Run:"
    echo "  $(operator_command_for "$key")"
    return 3
  fi
  case "$key" in
    "manager-env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS")
      write_environment_d_and_set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS 0 92-claude-bgwait.conf
      ;;
    "manager-env:TMPDIR")
      mkdir -p "$HOST_CONTRACT_TMPDIR_EXPECTED" 2>/dev/null
      write_environment_d_and_set TMPDIR "$HOST_CONTRACT_TMPDIR_EXPECTED" 92-tmpdir.conf
      ;;
    "timer:tmp-scratch-reap.timer")
      "$SYSTEMCTL" --user enable --now tmp-scratch-reap.timer >/dev/null 2>&1
      ;;
    "unit-env-inheritance")
      write_environment_d_and_set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS 0 92-claude-bgwait.conf
      write_environment_d_and_set TMPDIR "$HOST_CONTRACT_TMPDIR_EXPECTED" 92-tmpdir.conf
      ;;
    *)
      echo "host-contract: apply: no self-heal action wired for $key" >&2
      return 2
      ;;
  esac
  run_predicate "$key"
  [ "$RESULT" = ok ] && return 0
  echo "host-contract: apply: $key still drift($OBSERVED) after fix" >&2
  return 1
}

# ---------------------------------------------------------------------
# check
# ---------------------------------------------------------------------
cmd_check() {
  local fast=false
  while [ "$#" -gt 0 ]; do
    case "$1" in --fast) fast=true ;; esac
    shift
  done
  mkdir -p "$CONTRACT_STATE_DIR" 2>/dev/null || true
  local prev_json="{}"
  [ -r "$LAST_STATUS_FILE" ] && prev_json="$(cat "$LAST_STATUS_FILE" 2>/dev/null)"
  [ -n "$prev_json" ] || prev_json="{}"
  local new_status_json="{}"
  local worst=0 i key sev owner prev_status now_ts
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in "${!KEY_NAMES[@]}"; do
    key="${KEY_NAMES[$i]}"; sev="${KEY_SEVERITY[$i]}"; owner="${KEY_OWNER[$i]}"
    if $fast && [ "$key" = "auth-file:90-claude-oauth.conf" ]; then
      echo "$key=skip(fast)"
      continue
    fi
    run_predicate "$key"
    if [ "$RESULT" = ok ]; then
      echo "$key=ok"
    else
      echo "$key=drift($OBSERVED) severity=$sev owner=$owner"
      if [ "$sev" = critical ]; then
        worst=2
      elif [ "$worst" -lt 1 ]; then
        worst=1
      fi
    fi
    prev_status="$("$JQ" -r --arg k "$key" '.[$k] // "ok"' <<<"$prev_json" 2>/dev/null)"
    if [ "$RESULT" != "$prev_status" ]; then
      if [ "$RESULT" = drift ]; then
        journal_line "$now_ts  host-contract  $key  drift  (observed=$OBSERVED)"
      else
        journal_line "$now_ts  host-contract  $key  recovered  (observed=ok)"
      fi
    fi
    new_status_json="$("$JQ" -c --arg k "$key" --arg v "$RESULT" '. + {($k):$v}' <<<"$new_status_json")"
  done
  new_status_json="$(printf '%s\n%s\n' "$prev_json" "$new_status_json" | "$JQ" -s '.[0] * .[1]' 2>/dev/null)"
  [ -n "$new_status_json" ] || new_status_json="{}"
  local tmp; tmp="$(mktemp "$CONTRACT_STATE_DIR/.last-status.XXXXXX" 2>/dev/null || true)"
  if [ -n "$tmp" ]; then
    printf '%s\n' "$new_status_json" > "$tmp" && mv -f "$tmp" "$LAST_STATUS_FILE"
  fi
  case "$worst" in
    2) exit 2 ;;
    1) exit 1 ;;
    *) exit 0 ;;
  esac
}

cmd_history() {
  local root d file
  root="$(journal_root)"
  for d in 6 5 4 3 2 1 0; do
    file="$root/$(date -u -d "-${d} days" +%F).md"
    [ -r "$file" ] && grep '  host-contract  ' "$file"
  done
  return 0
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    check) cmd_check "$@" ;;
    apply)
      local key="${1:-}"
      [ -z "$key" ] && { echo "usage: host-contract.sh apply <key>" >&2; exit 2; }
      apply_key "$key"
      ;;
    history) cmd_history ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
exit $?
