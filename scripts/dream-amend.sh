#!/usr/bin/env bash
# dream-amend.sh — /dream hook `dream.amend` (before any amend; open runs from fleet-dash status.json): may this PRD be
# amended in place, or does an open run mean "cordon, or draft a successor"?
#
# Read-only. Two reads, both named in the output:
#   1. open run  — the fleet-dash status file (FLEET_STATUS, default
#      ~/.cache/fleet-dash/status.json when present, else FLEET_STATUS_URL via
#      curl): `.ts` + `.hosts.{redbaron,ryzen7}.open_runs[]` ({id,slug,stage,...}).
#      No wm-build and no ssh, ever: a raw `wm-build runs` on a build host is a
#      whole-journal read that froze ryzen7 (10-24). FAIL CLOSED: an unreadable,
#      unparseable, host-less or stale (> FLEET_STATUS_MAX_AGE s) status is
#      `REFUSED: fleet status unreadable or stale (...)`, exit 2, no fallback.
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
#   open-run: <id|none> host=<h> stage=<s>   (read: <status file or URL>)
#   status=<s> dispatch-iter_log=<yes|no>    (read: <PRD file>)
#                                            a `shipped`/`built` PRD under parked/ prints
#                                            `status=parked (file Status: shipped, in parked/)` and the
#                                            gate is passed `parked` (lineage keys only, see the gate); its
#                                            dispatch-iter_log is then `yes (implied by Status: shipped)`,
#                                            since that Status is itself proof of dispatch
#   <gate verdict>                           (allow | deny: ...), from
#                                            ~/.claude/skills/dream/scripts/amend-key-gate.sh
# Exit: 0 allow | 2 refused (open run, or the gate denies) | 1 usage / PRD not found
#
# Env: PRD_DIR (default ~/Documents/PRDs); FLEET_STATUS (file; default
#      ~/.cache/fleet-dash/status.json if it exists); FLEET_STATUS_URL (default
#      http://carbon:8787/status.json); FLEET_STATUS_MAX_AGE (default 300 s);
#      DREAM_AMEND_GATE (default ~/.claude/skills/dream/scripts/amend-key-gate.sh).
set -uo pipefail

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
GATE="${DREAM_AMEND_GATE:-$HOME/.claude/skills/dream/scripts/amend-key-gate.sh}"
FLEET_STATUS_URL="${FLEET_STATUS_URL:-http://carbon:8787/status.json}"
FLEET_STATUS_MAX_AGE="${FLEET_STATUS_MAX_AGE:-300}"

# open_run_of <slug> -> reads the fleet-dash status (file, else URL). Prints
#   `OPEN <id> <host> <stage>` | `NONE <source>` | `BAD <reason>`; always rc 0.
open_run_of() {
  local src="${FLEET_STATUS:-}" body="" reason=""
  if [ -z "$src" ] && [ -f "$HOME/.cache/fleet-dash/status.json" ]; then src="$HOME/.cache/fleet-dash/status.json"; fi
  if [ -n "$src" ]; then
    body="$(cat -- "$src" 2>/dev/null)" || { echo "BAD cannot read $src"; return 0; }
  else
    src="$FLEET_STATUS_URL"
    body="$(curl -fsS --max-time 8 "$src" 2>&1)" || { echo "BAD cannot fetch $src"; return 0; }
  fi
  python3 -c '
import json, sys, time
slug, src, maxage = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    d = json.loads(sys.stdin.read())
    ts = float(d["ts"])
    hosts = d["hosts"]
    assert isinstance(hosts, dict)
except Exception as e:
    print("BAD unparseable or missing .ts/.hosts (%s)" % type(e).__name__); sys.exit(0)
age = time.time() - ts
if age > maxage:
    print("BAD stale: ts is %ds old, max %ds" % (age, maxage)); sys.exit(0)
for h in ("redbaron", "ryzen7"):
    hd = hosts.get(h)
    if not isinstance(hd, dict) or not isinstance(hd.get("open_runs"), list):
        print("BAD host %s has no open_runs" % h); sys.exit(0)
for h in ("redbaron", "ryzen7"):
    for r in hosts[h]["open_runs"]:
        if isinstance(r, dict) and r.get("slug") == slug:
            print("OPEN %s %s %s" % (r.get("id"), h, r.get("stage") or "-")); sys.exit(0)
print("NONE " + src)
' "$1" "$src" "$FLEET_STATUS_MAX_AGE" <<<"$body"
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

  local res kind open_id open_host open_stage rest
  res="$(open_run_of "$slug")"
  kind="${res%% *}"; rest="${res#* }"
  case "$kind" in
    OPEN)
      read -r open_id open_host open_stage <<<"$rest"
      echo "open-run: $open_id host=$open_host stage=$open_stage   (read: fleet-dash status.json)"
      echo "REFUSED: run $open_id is open on $open_host ($open_stage): cordon then redrive --from inner after the amend, or draft a successor"
      return 2 ;;
    NONE) echo "open-run: none host=- stage=-   (read: $rest)" ;;
    *)    echo "REFUSED: fleet status unreadable or stale ($rest); no wm-build fallback"; return 2 ;;
  esac

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
DISPATCH_ANY = re.compile(r"run \d+ dispatched|dispatched (to|on) |wm-build[ ]run|admitted by|run=\d+ \w+ code cause=", re.I)
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
    # and a shipped/built Status is itself proof the PRD was dispatched, even with no iter_log line
    # (the gate's parked case needs has-dispatch-iter-log=yes)
    echo "status=parked (file Status: $status, in parked/) dispatch-iter_log=yes (implied by Status: $status)   (read: $file)"
    status="parked"; disp="yes"
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
  now="$(date +%s)"
  mk() { printf '{"ts": %s, "hosts": {"redbaron": {"open_runs": %s}, "ryzen7": {"open_runs": %s}}}\n' "$1" "$2" "$3" > "$4"; }
  mk "$now" '[{"id": 77, "slug": "b-open", "stage": "inner"}]' '[]' "$t/st-match"
  mk "$now" '[{"id": 90, "slug": "q-clean", "stage": "inner"}]' '[]' "$t/st-match-rb"
  mk "$now" '[]' '[{"id": 91, "slug": "b-open", "stage": "land"}]' "$t/st-match-r7"
  mk "$now" '[{"id": 78, "slug": "other", "stage": "land"}]' '[]' "$t/st-nomatch"
  mk "$((now-9999))" '[]' '[]' "$t/st-stale"
  printf '{"ts": %s, "hosts": {' "$now" > "$t/st-bad"
  printf '{"ts": %s}\n' "$now" > "$t/st-nohosts"
  printf '#!/usr/bin/env bash\necho allow\n' > "$t/gate-allow"
  chmod +x "$t/gate-allow"
  export PRD_DIR="$t/prds"
  PRD_DIR="$t/prds"
  ck() { # $1=label $2=want-rc $3=pattern ; env set by caller via vars; $4.. args
    total=$((total+1))
    out="$(run_main "${@:4}" 2>&1)"; rc=$?
    if [ "$rc" -eq "$2" ] && grep -q -- "$3" <<<"$out"; then echo "ok: $1"; else echo "FAIL: $1 exit=$rc want $2 /$3/ :: $out"; fails=$((fails+1)); fi
  }
  FLEET_STATUS="$t/st-match"
  ck "open run -> refused, names the cordon/successor path" 2 "cordon then redrive --from inner after the amend, or draft a successor" b-open keys
  ck "open run line names id/host/stage" 2 "open-run: 77 host=redbaron stage=inner" b-open keys
  FLEET_STATUS="$t/st-nomatch"
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
    # a shipped/built Status is itself proof of dispatch: no iter_log line needed (the real parked/ shipped PRD has none)
    printf '# PRD\n\n- Status: shipped\n- iter_log: 2026-10-01T00:00:00Z created by dream\n' > "$t/prds/parked/PRD-p-ship-nolog.md"
    ck "(g) shipped PRD in parked/, NO dispatch iter_log + Superseded-by -> dispatch-iter_log=yes implied, allow (exit 0)" 0 "^status=parked (file Status: shipped, in parked/) dispatch-iter_log=yes (implied by Status: shipped)
^allow" p-ship-nolog Superseded-by
    ck "(h) same + acceptance_criteria -> deny (exit 2)" 2 "^deny" p-ship-nolog Superseded-by,acceptance_criteria
    ck "(i) queued PRD in parked/, no log + Superseded-by,Status -> unchanged (status=queued dispatch-iter_log=no, allow)" 0 "^status=queued dispatch-iter_log=no
^allow" p-queued Superseded-by,Status
  fi
  GATE="$t/gate-allow"
  FLEET_STATUS="$t/st-match-r7"
  ck "ryzen7 run found -> refused naming id and host" 2 "REFUSED: run 91 is open on ryzen7 (land)" b-open keys
  FLEET_STATUS="$t/st-match-rb"
  ck "redbaron run found -> refused naming id and host" 2 "REFUSED: run 90 is open on redbaron (inner)" q-clean Falsifier
  FLEET_STATUS="$t/st-stale"
  ck "stale ts -> fail closed" 2 "REFUSED: fleet status unreadable or stale (stale.*no wm-build fallback" q-clean Falsifier
  FLEET_STATUS="$t/st-bad"
  ck "malformed json -> fail closed" 2 "REFUSED: fleet status unreadable or stale (unparseable" q-clean Falsifier
  FLEET_STATUS="$t/st-nohosts"
  ck "missing .hosts -> fail closed" 2 "REFUSED: fleet status unreadable or stale" q-clean Falsifier
  FLEET_STATUS="$t/absent"
  ck "unreadable file -> fail closed" 2 "REFUSED: fleet status unreadable or stale (cannot read" q-clean Falsifier
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d'; exit 0 ;;
esac
run_main "$@"
