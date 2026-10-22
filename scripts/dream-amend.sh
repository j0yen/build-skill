#!/usr/bin/env bash
# dream-amend.sh — /dream hook `dream.amend` (before any amend): may this PRD be
# amended in place, or does an open run mean "cordon, or draft a successor"?
#
# Read-only. Two reads, both named in the output:
#   1. open run  — `wm-build runs` (the read-only list verb; it never creates a
#      run) on every daemon host, in order: local carbon (only when wm-build is on
#      PATH AND ~/.config/wm-build/config.toml exists, i.e. a real state dir),
#      then `ssh redbaron`, then `ssh ryzen7` (non-login ssh: the PATH export is
#      part of the remote command). A host that cannot be reached is reported
#      `unverified`, never assumed empty. (~/.cache/fleet-dash/status.json carries
#      queue counts only, not a run list, so it is not used.)
#   2. status + dispatch iter_log — from the PRD file itself (build-queue/, then
#      parked/, then built-prds/ under $PRD_DIR): its first `Status:` key and
#      whether any `iter_log:` line is a dispatch line (anything but
#      amended|created|premise|PARKED).
#
# Usage:
#   dream-amend.sh <slug> <comma-keys>      keys the amendment would add/change
#   dream-amend.sh --selftest
#
# Prints:
#   open-run: <id|none> host=<h> stage=<s>   (read: wm-build runs @<host>)
#   status=<s> dispatch-iter_log=<yes|no>    (read: <PRD file>)
#   <gate verdict>                           (allow | deny: ...), from
#                                            ~/.claude/skills/dream/scripts/amend-key-gate.sh
# Exit: 0 allow | 2 refused (open run, or the gate denies) | 1 usage / PRD not found
#
# Env: PRD_DIR (default ~/Documents/PRDs); DREAM_AMEND_HOSTS (default "local redbaron ryzen7");
#      DREAM_AMEND_WM_BUILD (default wm-build); DREAM_AMEND_SSH (default `ssh -o ConnectTimeout=8`);
#      DREAM_AMEND_GATE (default ~/.claude/skills/dream/scripts/amend-key-gate.sh).
set -uo pipefail

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
HOSTS="${DREAM_AMEND_HOSTS:-local redbaron ryzen7}"
WB="${DREAM_AMEND_WM_BUILD:-wm-build}"
SSH="${DREAM_AMEND_SSH:-ssh -o ConnectTimeout=8}"
GATE="${DREAM_AMEND_GATE:-$HOME/.claude/skills/dream/scripts/amend-key-gate.sh}"
PATHX='export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH;'

# runs_on <host> -> prints `wm-build runs` output; returns 3 when the host is not
# usable (unreachable, or local without a daemon state dir)
runs_on() {
  if [ "$1" = "local" ]; then
    command -v "$WB" >/dev/null 2>&1 || [ -x "$WB" ] || return 3
    [ -n "${DREAM_AMEND_ASSUME_LOCAL_CONFIG:-}" ] || [ -f "$HOME/.config/wm-build/config.toml" ] || return 3
    "$WB" runs 2>&1
  else
    $SSH "$1" "$PATHX wm-build runs" 2>&1
  fi
}

prd_file() {
  local d
  for d in build-queue parked built-prds; do
    [ -f "$PRD_DIR/$d/PRD-$1.md" ] && { echo "$PRD_DIR/$d/PRD-$1.md"; return 0; }
  done
  return 1
}

run_main() {
  local slug="${1:-}" keys="${2:-}"
  if [ -z "$slug" ] || [ -z "$keys" ]; then
    echo "usage: dream-amend.sh <slug> <comma-keys>" >&2; return 1
  fi
  slug="$(basename "$slug")"; slug="${slug#PRD-}"; slug="${slug%.md}"
  local file
  file="$(prd_file "$slug")" || { echo "dream-amend: no PRD-$slug.md under $PRD_DIR/{build-queue,parked,built-prds}" >&2; return 1; }

  local h out rc open_id="none" open_host="-" open_stage="-" unverified=""
  for h in $HOSTS; do
    out="$(runs_on "$h")"; rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '^runs:' <<<"$out"; then
      [ "$h" = "local" ] && [ "$rc" -eq 3 ] && continue   # carbon without a daemon: not a host to verify
      unverified="$unverified $h"; continue
    fi
    local line
    line="$(grep -E "^r[0-9]+ ${slug} " <<<"$out" | head -1)"
    if [ -n "$line" ]; then
      open_id="$(awk '{print substr($1,2)}' <<<"$line")"; open_host="$h"; open_stage="$(awk '{print $3}' <<<"$line")"
      break
    fi
  done
  echo "open-run: $open_id host=$open_host stage=$open_stage   (read: wm-build runs @${HOSTS// /,}${unverified:+; unverified:${unverified}})"
  if [ "$open_id" != "none" ]; then
    echo "REFUSED: run $open_id is open on $open_host ($open_stage): cordon then redrive --from inner after the amend, or draft a successor"
    return 2
  fi

  local status disp
  status="$(python3 - "$file" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()[:80]
status, disp, fence = "", "no", False
for ln in lines:
    if ln.strip().startswith("```"):
        fence = not fence; continue
    if fence: continue
    k = re.sub(r"^[-*+]\s+", "", ln)
    k = re.sub(r"^\*\*([A-Za-z_ -]+):\*\*", r"\1:", k)
    m = re.match(r"^([A-Za-z_][A-Za-z_ -]*):\s*(.*)$", k)
    if not m: continue
    key, val = m.group(1).strip().lower(), m.group(2).strip()
    if key == "status" and not status:
        status = (val.split() or ["unknown"])[0].lower()
    if key == "iter_log":
        w = re.match(r"\S+\s+(\S+)", val)
        if not (w and w.group(1).lower() in ("amended", "created", "premise", "parked")):
            disp = "yes"
print(status or "unknown", disp)
PY
)"
  disp="${status#* }"; status="${status%% *}"
  echo "status=$status dispatch-iter_log=$disp   (read: $file)"
  if [ -x "$GATE" ]; then
    "$GATE" "$status" "$disp" "$keys"; return $?
  fi
  echo "dream-amend: amend-key-gate.sh not found at $GATE; applying the minimum rule (queued, no dispatch iter_log)" >&2
  if [ "$status" = "queued" ] && [ "$disp" = "no" ]; then echo allow; return 0; fi
  echo "deny: $status with dispatch-iter_log=$disp is not amendable in place; draft a successor"; return 2
}

selftest() {
  local t fails=0 total=0 out rc
  t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  mkdir -p "$t/prds/build-queue" "$t/prds/parked"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-01T00:00:00Z amended by /dream (x) — y\n' > "$t/prds/build-queue/PRD-q-clean.md"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-01T00:00:00Z run 12 dispatched\n' > "$t/prds/build-queue/PRD-q-disp.md"
  printf '# PRD\n\n- Status: building\n' > "$t/prds/build-queue/PRD-b-open.md"
  printf '# PRD\n\nStatus: queued\n' > "$t/prds/build-queue/PRD-bare.md"
  printf '#!/usr/bin/env bash\ncat <<X\nruns: 2 total\nr77 b-open inner 10m box=- tokens=0\nr78 other land 3m\nX\n' > "$t/wb"
  printf '#!/usr/bin/env bash\necho "runs: 0 total"; echo "runs: none in flight"\n' > "$t/wb-empty"
  printf '#!/usr/bin/env bash\nshift; h="$1"; shift\nif [ "$h" = down ]; then exit 255; fi\nif [ "$h" = rb ]; then cat <<X\nruns: 1 total\nr90 q-clean inner 5m\nX\nelse echo "runs: 0 total"; fi\n' > "$t/ssh"
  printf '#!/usr/bin/env bash\necho allow\n' > "$t/gate-allow"
  chmod +x "$t/wb" "$t/wb-empty" "$t/ssh" "$t/gate-allow"
  export PRD_DIR="$t/prds" DREAM_AMEND_ASSUME_LOCAL_CONFIG=1 DREAM_AMEND_SSH="$t/ssh x"
  PRD_DIR="$t/prds"
  ck() { # $1=label $2=want-rc $3=pattern ; env set by caller via vars; $4.. args
    total=$((total+1))
    out="$(run_main "${@:4}" 2>&1)"; rc=$?
    if [ "$rc" -eq "$2" ] && grep -q -- "$3" <<<"$out"; then echo "ok: $1"; else echo "FAIL: $1 exit=$rc want $2 /$3/ :: $out"; fails=$((fails+1)); fi
  }
  HOSTS="local"; WB="$t/wb"
  ck "open run -> refused, names the cordon/successor path" 2 "cordon then redrive --from inner after the amend, or draft a successor" b-open keys
  ck "open run line names id/host/stage" 2 "open-run: 77 host=local stage=inner" b-open keys
  WB="$t/wb-empty"
  # the real gate (when installed) decides; the fixtures below also hold under the fallback
  GATE="$t/none"
  ck "queued, no dispatch iter_log -> allow (names the read)" 0 "read: .*PRD-q-clean.md" q-clean Falsifier
  ck "queued, no dispatch iter_log -> allow verdict" 0 "^allow" q-clean Falsifier
  ck "bare 'Status:' key parsed" 0 "status=queued" bare Falsifier
  ck "queued WITH dispatch iter_log -> deny" 2 "dispatch-iter_log=yes" q-disp Falsifier
  ck "unknown slug -> exit 1" 1 "no PRD-nope.md" nope Falsifier
  ck "missing keys arg -> exit 1" 1 "usage" q-clean
  if [ -x "$HOME/.claude/skills/dream/scripts/amend-key-gate.sh" ]; then
    GATE="$HOME/.claude/skills/dream/scripts/amend-key-gate.sh"
    ck "real amend-key-gate passes its verdict through (allow)" 0 "^allow" q-clean Falsifier
    ck "real amend-key-gate passes its verdict through (deny)" 2 "^deny" q-disp Falsifier
  fi
  # remote host: local has no daemon (skipped), rb has the run, down is unverified
  GATE="$t/gate-allow"; WB="$t/wb-empty"
  HOSTS="local rb"; DREAM_AMEND_SSH="$t/ssh x"; SSH="$t/ssh x"
  ck "remote host run found -> refused with host" 2 "open-run: 90 host=rb stage=inner" q-clean Falsifier
  HOSTS="down"; SSH="$t/ssh x"
  ck "unreachable host -> unverified, not assumed empty" 0 "unverified: down" q-clean Falsifier
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
esac
run_main "$@"
