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
#      whether any `iter_log:` line is a dispatch line. Dispatch is
#      classified POSITIVELY (DISPATCH_HEAD / DISPATCH_ANY in the python below: run=<id>, decision
#      <id> answered, dispatch <id>, resume-check, ... ); amended|created|premise|PARKED lines and any
#      line of no dispatch form (e.g. the review line `amended by /dream (review) — Fable FIX ...`,
#      or an operator note) are `other` and do not deny.
#
# Usage:
#   dream-amend.sh <slug> <comma-keys>      keys the amendment would add/change
#   dream-amend.sh --selftest
#
# Prints:
#   open-run: <id|none> host=<h> stage=<s>   (read: wm-build runs @<host>)
#   status=<s> dispatch-iter_log=<yes|no>    (read: <PRD file>)
#                                            a `shipped`/`built` PRD under parked/ prints
#                                            `status=parked (file Status: shipped, in parked/)` and the
#                                            gate is passed `parked` (lineage keys only, see the gate)
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
# forms found in the PRDs repo history + wm-build src (daemon/verdict.rs, daemon/decision.rs):
#   run=<id> <stage> code cause=...   decision <id> answered: ...   dispatch <id> (<host>, ...
#   Direct-build dispatched by the operator   <host> dispatch / build dispatch / build tick
#   resume-check|verify-blocker|verify-unchanged|reverify|blocked-encode (own-claim ...)   building (unchanged ...)   claimed by ...
#   requeued ...   gate-retry|gate-recheck|gate-red ...   landed|hand-landed|r<id> ...
DISPATCH_HEAD = re.compile(
    r"(run=\d+|run \d+ dispatched|decision \d+ answered|dispatch(ed)?\b|\S+ dispatch\b|"
    r"direct-build dispatched|build (tick|dispatch)|tick \(|resume-check|verify-(blocker|unchanged)|"
    r"reverify|[\w-]+ \(own-claim|building \(|claimed by|requeued|gate-(retry|recheck|red|then-land)|landed\b|r\d+\b|needs_classification)",
    re.I)
DISPATCH_ANY = re.compile(r"run \d+ dispatched|dispatched (to|on) |wm-build run|admitted by|run=\d+ \w+ code cause=", re.I)
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
        # POSITIVE classification: an iter_log line is `dispatch` only when it matches a form the
        # daemon / operators write when a run touched the PRD; `amended|created|premise|parked` lines
        # are /dream's or the premise timer's; anything else is `other` and does not deny.
        w = re.match(r"\S+\s+(\S+)", val)
        if w and w.group(1).lower() in ("amended", "created", "premise", "parked"):
            continue
        rest = (re.match(r"\S+\s+(.*)$", val) or [None, ""])[1]
        if DISPATCH_HEAD.match(rest) or DISPATCH_ANY.search(rest):
            disp = "yes"
print(status or "unknown", disp)
PY
)"
  disp="${status#* }"; status="${status%% *}"
  if [ "$file" = "$PRD_DIR/parked/PRD-$slug.md" ] && { [ "$status" = "shipped" ] || [ "$status" = "built" ]; }; then
    # a shipped/built PRD that sits in parked/ is parked work (its successor carries the build): the gate
    # must see `parked` so the lineage keys (Superseded-by, transferred_acs) are accepted
    echo "status=parked (file Status: $status, in parked/) dispatch-iter_log=$disp   (read: $file)"
    status="parked"
  else
    echo "status=$status dispatch-iter_log=$disp   (read: $file)"
  fi
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
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-22T22:4xZ Fable FIX applied before persist (8 binding: a, b); kept x\n' > "$t/prds/build-queue/PRD-q-rev-old.md"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-22T22:4xZ amended by /dream (review) — Fable FIX applied before persist: (8 binding: a, b)\n' > "$t/prds/build-queue/PRD-q-rev-new.md"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-15T13:21:05.218566697+00:00 run=834 gate code cause=block: ["risk-gate"] blocker=rollback-plan\n' > "$t/prds/build-queue/PRD-q-run.md"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-22T22:4xZ amended by /dream (review) — Fable FIX applied before persist: (x)\n- iter_log: 2026-10-23T01:00:00Z decision 298 answered: housekeeping\n' > "$t/prds/build-queue/PRD-q-mixed.md"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-01T07:45Z Direct-build dispatched by the operator\n' > "$t/prds/build-queue/PRD-q-direct.md"
  printf '# PRD\n\n- Status: queued\n- iter_log: 2026-10-20T10:00Z operator note (Joe via carbon session) — reworded AC 3\n' > "$t/prds/build-queue/PRD-q-note.md"
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
  ck "queued, OLD review iter_log form (Fable FIX applied before persist) -> allow" 0 "dispatch-iter_log=no" q-rev-old Falsifier
  ck "queued, NEW review iter_log form (amended by /dream (review) — …) -> allow" 0 "dispatch-iter_log=no" q-rev-new Falsifier
  ck "queued, real daemon run= form -> deny" 2 "dispatch-iter_log=yes" q-run Falsifier
  ck "queued, 'Direct-build dispatched by the operator' -> deny" 2 "dispatch-iter_log=yes" q-direct Falsifier
  ck "queued, mixed (review line + decision-answered dispatch line) -> deny" 2 "dispatch-iter_log=yes" q-mixed Falsifier
  ck "queued, operator-note iter_log (no dispatch form) -> allow" 0 "dispatch-iter_log=no" q-note Falsifier
  ck "unknown slug -> exit 1" 1 "no PRD-nope.md" nope Falsifier
  ck "missing keys arg -> exit 1" 1 "usage" q-clean
  if [ -x "$HOME/.claude/skills/dream/scripts/amend-key-gate.sh" ]; then
    GATE="$HOME/.claude/skills/dream/scripts/amend-key-gate.sh"
    ck "real amend-key-gate passes its verdict through (allow)" 0 "^allow" q-clean Falsifier
    ck "real amend-key-gate passes its verdict through (deny)" 2 "^deny" q-disp Falsifier
    # shipped-in-parked/: the gate sees `parked`. A COPY of the gate inside the throwaway root decides.
    mkdir -p "$t/prds/built-prds"
    cp "$GATE" "$t/gate-copy.sh"; chmod +x "$t/gate-copy.sh"; GATE="$t/gate-copy.sh"
    printf '# PRD\n\n- Status: shipped\n- iter_log: 2026-10-01T00:00:00Z run 12 dispatched\n' > "$t/prds/parked/PRD-p-ship.md"
    printf '# PRD\n\n- Status: built\n- iter_log: 2026-10-01T00:00:00Z run=12 land code cause=ok\n' > "$t/prds/parked/PRD-p-built.md"
    printf '# PRD\n\n- Status: shipped\n- iter_log: 2026-10-01T00:00:00Z run 12 dispatched\n' > "$t/prds/built-prds/PRD-s-built.md"
    printf '# PRD\n\n- Status: queued\n' > "$t/prds/parked/PRD-p-queued.md"
    ck "shipped PRD in parked/ + Superseded-by -> status=parked read printed, allow (exit 0)" 0 "^status=parked (file Status: shipped, in parked/)
^allow" p-ship Superseded-by
    ck "shipped PRD in parked/ + Superseded-by,transferred_acs -> allow" 0 "^allow" p-ship Superseded-by,transferred_acs
    ck "built PRD in parked/ + Superseded-by -> status=parked read printed, allow" 0 "^status=parked (file Status: built, in parked/)
^allow" p-built Superseded-by
    ck "shipped PRD in parked/ + Superseded-by,acceptance_criteria -> deny (exit 2)" 2 "^deny" p-ship Superseded-by,acceptance_criteria
    ck "shipped PRD in parked/ + Status key -> deny" 2 "^deny" p-ship Status
    ck "shipped PRD in parked/ + Depends-on key -> deny" 2 "^deny" p-ship Depends-on
    ck "shipped PRD in built-prds/ + Superseded-by -> deny unchanged (gate sees shipped)" 2 "^deny: shipped is not amendable in place" s-built Superseded-by
    ck "queued PRD in parked/, no dispatch log -> status=queued, allow unchanged" 0 "^status=queued dispatch-iter_log=no
^allow" p-queued Falsifier
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
  -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d'; exit 0 ;;
esac
run_main "$@"
