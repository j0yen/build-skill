#!/usr/bin/env bash
# live-ac-reality-check.sh — PRD-build-live-ac-no-defer R6/R7.
#
# Operator-note 2026-09-17T19:25Z (Joe: "6h") resolved this PRD's own open
# question: LIVE_AC_MAX_WALL, a wall-clock bound, replaces the originally
# undecided LIVE_AC_MAX_TICKS (ticks run 1h30 and overlap-skip, so a tick
# count was never a duration).
#
# archive-live-ac-refusal.sh (R5) already refuses a loop-tooling PRD whose
# `(Live` AC is unproven or deferred, leaving it `built` (not `shipped`)
# with last_error=live-ac-unproven:<N>/live-ac-deferred:<N>, still sitting
# in build-queue/. This script is the retry loop that eventually finishes
# the job: called once per tick against a `built` loop-tooling PRD, it
# re-derives every `(Live` AC's own evidence the same way R4/R5 already do
# (verified-completed.sh --derive, rule h), and:
#
#   - when every `(Live` AC — AND every other AC on the PRD — is now
#     paired or legitimately deferred, it finishes the archive for real:
#     archive-trailer.sh validates + emits the "Verified-completed:"
#     trailer (records the (Live evidence path/receipt/journal-line
#     alongside every other AC's own evidence), a durable
#     `Live-AC-evidence:` frontmatter line is written onto the PRD before
#     it moves (so the archived copy in built-prds/ carries the record
#     forever, independent of any git-log archaeology), and
#     archive-commit.sh does the actual git-mv + Status/Built/Receipts
#     header + MANIFEST.md flip to shipped, one atomic commit+push (R6:
#     "the PRD becomes shipped ... the file moves to built-prds").
#
#   - when at least one `(Live` AC is still unproven, the PRD is left
#     exactly where it is (no mutation) and how long that AC has been
#     unproven is tracked in state/live-ac-pending/<slug>.json
#     (first_seen_unproven_at, set once, on the first tick this script
#     observes it). Once LIVE_AC_MAX_WALL (default 6h; env override,
#     <N>s/<N>m/<N>h/<N>d) has elapsed since that first observation, it
#     opens exactly one operator decision per still-unproven AC
#     (decisions.sh open — idempotent by question-hash, so a later tick
#     re-checking the SAME still-missing evidence never opens a second
#     one) naming the PRD, the AC number, and the missing evidence form.
#
#   - when every `(Live` AC is proven but some OTHER (non-live) AC is
#     still MISSING/ac-number-collision, this script declines to ship
#     (that gap belongs to the ordinary archive gate, not this PRD) and
#     does not touch the pending-state bookkeeping above — there is no
#     unproven `(Live` AC to track a clock against.
#
# Usage:
#   live-ac-reality-check.sh check <PRD-path>
#       Runs the above once for one `built` loop-tooling PRD. Always
#       exits 0 once setup succeeds (the verdict is on stderr as
#       `[live-ac-reality-verdict] <slug>: <verdict>`, and in the journal)
#       — this command's job is to ADVANCE or RECORD state, not to gate a
#       caller's own exit code; a real blocking condition inside a step
#       it depends on (archive-trailer/archive-commit failing) is logged
#       and simply leaves the PRD exactly where it already was, to be
#       retried next tick. Exit 2 is reserved for usage/setup errors
#       (bad PRD path, a required sibling script missing), matching this
#       repo's other reality-check-shaped scripts.
#
# Env (all overridable for hermetic selftests, same convention as the
# scripts this one composes):
#   LIVE_AC_MAX_WALL          default 6h.
#   LIVE_AC_PENDING_DIR       default $SKILL_DIR/state/live-ac-pending.
#   LIVE_AC_RULINGS_DIR       passed through to verified-completed.sh —
#                             operator `(Live` AC pairing rulings; see
#                             scripts/live-ac-ruling.sh.
#   LOOP_TOOLING_REPOS_FILE   passed through to verified-completed.sh.
#   VC_JOURNAL_DIR            passed through (journal:<regex> evidence).
#   PRD_DIR / BUILD_MANIFEST  passed through to archive-commit.sh.
#   DECISIONS_FILE            passed through to decisions.sh.
#   BUILD_JOURNAL_ROOT (etc.) passed through to lib/journal.sh.
#
# Exit codes:
#   0  ran (see the verdict on stderr/journal — a per-AC gap is reflected
#      there, not in this exit code, same posture as reality-check.sh's
#      own `run`).
#   2  usage / setup error.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
VC="$HERE/verified-completed.sh"
TRAILER="$HERE/archive-trailer.sh"
ARCHIVE_COMMIT="$HERE/archive-commit.sh"
DECISIONS="$HERE/decisions.sh"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"
PENDING_DIR="${LIVE_AC_PENDING_DIR:-$SKILL_DIR/state/live-ac-pending}"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c "user.name=Joe Yen")
# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

log() { printf 'live-ac-reality-check: %s\n' "$*" >&2; }
die() { printf 'live-ac-reality-check: %s\n' "$*" >&2; exit "${2:-2}"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

usage() { sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# parse_wall <spec> -> seconds on stdout, rc 1 on a spec this can't read.
# Accepts a bare integer (seconds) or <N><unit> with unit in s/m/h/d
# (systemd-span-ish — this PRD only ever names s/m/h/d values; the full
# systemd grammar, e.g. "1h30m", is out of scope for what R6 needs).
parse_wall() {
  local spec="$1" n unit
  case "$spec" in
    ''|*[!0-9smhd]*) return 1 ;;
  esac
  case "$spec" in
    *[0-9]) n="$spec"; unit=s ;;
    *) n="${spec%?}"; unit="${spec: -1}" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    s) echo "$n" ;;
    m) echo "$(( n * 60 ))" ;;
    h) echo "$(( n * 3600 ))" ;;
    d) echo "$(( n * 86400 ))" ;;
    *) return 1 ;;
  esac
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
[ "$cmd" = check ] || usage

prd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    *) prd="$1"; shift ;;
  esac
done
[ -n "$prd" ] && [ -r "$prd" ] || die "PRD path required and must be readable: '$prd'"
for req in "$VC" "$TRAILER" "$ARCHIVE_COMMIT" "$DECISIONS"; do
  [ -x "$req" ] || die "required sibling script not executable: $req"
done
[ -x "$JQ" ] || die "jq not at $JQ"

base="$(basename "$prd")"
slug="${base#PRD-}"; slug="${slug%.md}"

max_wall_spec="${LIVE_AC_MAX_WALL:-6h}"
max_wall_s="$(parse_wall "$max_wall_spec")" || die "LIVE_AC_MAX_WALL='$max_wall_spec' is not a valid span (want <N>[smhd])"

payload="$("$VC" "$prd" --derive --format json 2>/dev/null)" || true
[ -n "$payload" ] || die "verified-completed.sh produced no output for $prd"

# A `(Live` AC is one whose classification came from verified-completed.sh
# rule h: either its own derived evidence matched (`live:<clause>`) or an
# operator ruling paired it (`live-operator-ruling:<who>@<when>`, see
# scripts/live-ac-ruling.sh), or it is still unproven/deferred. The
# operator-ruling form must be counted here too: miss it and a PRD whose
# only (Live AC was ruled paired looks like a PRD with NO (Live AC at all,
# and this script exits `no-live-ac` without ever shipping it.
live_acs="$("$JQ" -r '[.classifications[] | select((.rule // "" | startswith("live:")) or (.rule // "" | startswith("live-operator-ruling:")) or .status=="live-ac-unproven" or .status=="live-ac-deferred") | .ac] | unique | sort | join(",")' <<<"$payload")"
unproven_acs="$("$JQ" -r '[.classifications[] | select(.status=="live-ac-unproven") | .ac] | join(",")' <<<"$payload")"
deferred_acs_live="$("$JQ" -r '[.classifications[] | select(.status=="live-ac-deferred") | .ac] | join(",")' <<<"$payload")"
other_gaps="$("$JQ" -r '(.missing + .collisions) | length' <<<"$payload")"

if [ -z "$live_acs" ]; then
  log "no (Live AC found on $slug — nothing for R6 to evaluate"
  printf '[live-ac-reality-verdict] %s: no-live-ac\n' "$slug" >&2
  exit 0
fi

if [ -n "$unproven_acs" ] || [ -n "$deferred_acs_live" ]; then
  # ---- still not ready: at least one (Live AC unproven/deferred --------
  mkdir -p "$PENDING_DIR"
  pending_f="$PENDING_DIR/${slug}.json"
  now_ts="$(now_iso)"
  first_seen=""
  if [ -f "$pending_f" ]; then
    first_seen="$("$JQ" -r '.first_seen_unproven_at // empty' "$pending_f" 2>/dev/null)"
  fi
  [ -n "$first_seen" ] || first_seen="$now_ts"

  python3 - "$pending_f" "$slug" "$prd" "$first_seen" "$now_ts" "$unproven_acs" "$deferred_acs_live" <<'PY'
import json, sys
f, slug, prd, first_seen, now_ts, unproven, deferred = sys.argv[1:8]
data = {
    "slug": slug, "prd": prd,
    "first_seen_unproven_at": first_seen, "last_checked_at": now_ts,
    "unproven_acs": [a for a in unproven.split(",") if a],
    "deferred_acs": [a for a in deferred.split(",") if a],
}
with open(f, "w") as fh:
    json.dump(data, fh, indent=2)
PY

  first_epoch="$(date -u -d "$first_seen" +%s 2>/dev/null || now_epoch)"
  elapsed=$(( $(now_epoch) - first_epoch ))

  journal_line "$(now_iso)  reality-check  $slug  live-ac-unproven  (lane=$(hostname) unproven=[${unproven_acs}] deferred=[${deferred_acs_live}] elapsed_s=$elapsed max_wall_s=$max_wall_s)"

  if [ "$elapsed" -lt "$max_wall_s" ]; then
    printf '[live-ac-reality-verdict] %s: pending (elapsed=%ss of %ss)\n' "$slug" "$elapsed" "$max_wall_s" >&2
    exit 0
  fi

  # LIVE_AC_MAX_WALL elapsed -- open exactly one decision per still-
  # unproven AC. decisions.sh's own id-of-question hash makes a repeat
  # call for the SAME ac+missing-evidence text a no-op, so re-running
  # this check every tick after the bound is crossed never opens a
  # second decision for the same gap.
  doctor_out="$("$VC" "$prd" --derive --doctor 2>/dev/null)"
  IFS=',' read -ra unproven_arr <<<"$unproven_acs"
  for ac in "${unproven_arr[@]}"; do
    [ -n "$ac" ] || continue
    missing="$(printf '%s\n' "$doctor_out" | grep -E "^AC${ac}: live-ac-unproven" | sed -E 's/^AC[0-9]+: live-ac-unproven +— evidence not yet found: //')"
    [ -n "$missing" ] || missing="(no evidence: clause on the AC line)"
    question="PRD-${slug} AC${ac} (Live) unproven for LIVE_AC_MAX_WALL=${max_wall_spec}: missing evidence ${missing}"
    did="$("$DECISIONS" open "$question" --owner joe --repo build-skill --blocks "$slug" 2>&1)"
    journal_line "$(now_iso)  reality-check  $slug  decision-opened  (lane=$(hostname) ac=$ac id=${did})"
  done

  printf '[live-ac-reality-verdict] %s: decision-opened (elapsed=%ss >= %ss)\n' "$slug" "$elapsed" "$max_wall_s" >&2
  exit 0
fi

if [ "${other_gaps:-0}" -gt 0 ]; then
  log "every (Live AC on $slug is proven, but $other_gaps other AC(s) are still MISSING/collision -- not this script's gate, declining to ship"
  printf '[live-ac-reality-verdict] %s: not-ready (other-ac-gap)\n' "$slug" >&2
  exit 0
fi

# ---- every (Live AC (and every other AC) is paired or deferred: ship --
paired_flags=()
live_evidence_lines=()
# Same two live rule forms as above. An operator-ruled pairing is written
# into the durable `Live-AC-evidence:` frontmatter line WITH its rule, so
# the archived PRD says out loud that this AC was ruled rather than
# derived -- the whole point of the record is that a reader a month later
# can tell the two apart without re-deriving anything.
while IFS=$'\t' read -r ac rule path; do
  [ -n "$ac" ] || continue
  paired_flags+=(--paired "${ac}=${path}")
  case "$rule" in
    live-operator-ruling:*) live_evidence_lines+=("AC${ac}: ${path} (${rule})") ;;
    *) live_evidence_lines+=("AC${ac}: ${path}") ;;
  esac
done < <("$JQ" -r '.classifications[] | select((.rule // "" | startswith("live:")) or (.rule // "" | startswith("live-operator-ruling:"))) | "\(.ac)\t\(.rule)\t\(.path)"' <<<"$payload")

while IFS=$'\t' read -r ac path; do
  [ -n "$ac" ] || continue
  case "$path" in ""|null) continue ;; esac
  paired_flags+=(--paired "${ac}=${path}")
done < <("$JQ" -r '.classifications[] | select(((.rule // "") != "") and ((.rule // "") | startswith("live:") | not) and ((.rule // "") | startswith("live-operator-ruling:") | not)) | "\(.ac)\t\(.path // "")"' <<<"$payload")

trailer_out="$("$TRAILER" "$prd" "${paired_flags[@]+"${paired_flags[@]}"}" 2>&1)"
trailer_rc=$?
if [ "$trailer_rc" -ne 0 ]; then
  log "live AC(s) proven but archive-trailer.sh still finds a gap -- not archiving yet:"
  printf '%s\n' "$trailer_out" >&2
  printf '[live-ac-reality-verdict] %s: not-ready (trailer-gap)\n' "$slug" >&2
  exit 0
fi

evidence_joined="$(IFS='; '; echo "${live_evidence_lines[*]}")"

# Durable evidence record on the PRD itself before it moves, so the
# archived copy in built-prds/ carries it forever (R6: "records the
# evidence paths in the archive trailer") -- same head-rewrite shape as
# reality-check.sh's write_frontmatter_keys, kept local here since this
# is the only field this script ever writes.
python3 - "$prd" "$evidence_joined" <<'PY'
import re, sys
f, val = sys.argv[1], sys.argv[2]
with open(f) as fh:
    lines = fh.readlines()
head, rest = lines[:80], lines[80:]
key_re = re.compile(r'^(?:-\s*Live-AC-evidence:|Live-AC-evidence:).*$')
line = f"- Live-AC-evidence: {val}\n"
idx = next((i for i, ln in enumerate(head) if key_re.match(ln.rstrip('\n'))), None)
if idx is not None:
    head[idx] = line
else:
    status_idx = next((i for i, ln in enumerate(head) if re.match(r'^-\s*Status:', ln)), None)
    head.insert((status_idx + 1) if status_idx is not None else 1, line)
with open(f, "w") as fh:
    fh.writelines(head + rest)
PY

# That frontmatter edit must land as its own committed-and-pushed change
# BEFORE archive-commit.sh runs: archive-commit.sh refuses (exit 4) on a
# dirty build-queue/PRD-<slug>.md, by design (PRD-build-archive-atomic-
# commit) -- so the evidence line rides in on its own small commit first,
# same rebase-retry-once shape as reality-check.sh's own commit_and_push.
root="$(git -C "$(dirname "$prd")" rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$root" ]; then
  rel="$(realpath --relative-to="$root" "$prd")"
  git -C "$root" add -- "$rel"
  if ! git -C "$root" diff --cached --quiet -- "$rel"; then
    git -C "$root" "${GIT_ID[@]}" commit -q -m "$slug: record (Live AC evidence (pre-archive)" -- "$rel"
    branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)"
    if [ -n "$branch" ] && ! git -C "$root" push origin "$branch" -q 2>/tmp/live-ac-reality-check.push.err; then
      if git -C "$root" fetch origin -q 2>/dev/null && git -C "$root" rebase "origin/$branch" -q 2>/dev/null; then
        git -C "$root" push origin "$branch" -q 2>/tmp/live-ac-reality-check.push2.err \
          || log "evidence-line push failed after rebase (staying local): $(cat /tmp/live-ac-reality-check.push2.err 2>/dev/null)"
      else
        git -C "$root" rebase --abort >/dev/null 2>&1 || true
        log "evidence-line push failed, rebase failed (staying local): $(cat /tmp/live-ac-reality-check.push.err 2>/dev/null)"
      fi
    fi
  fi
fi

ac_out="$("$ARCHIVE_COMMIT" "$slug" 2>&1)"
ac_rc=$?
if [ "$ac_rc" -ne 0 ]; then
  log "archive-commit.sh failed (rc=$ac_rc) for $slug after every (Live AC was proven:"
  printf '%s\n' "$ac_out" >&2
  printf '[live-ac-reality-verdict] %s: not-ready (archive-commit rc=%s)\n' "$slug" "$ac_rc" >&2
  exit 0
fi

rm -f "$PENDING_DIR/${slug}.json" 2>/dev/null || true
journal_line "$(now_iso)  reality-check  $slug  shipped  (lane=$(hostname) live_acs=[${live_acs}] evidence=\"${evidence_joined}\")"
printf '[live-ac-reality-verdict] %s: shipped (live_acs=[%s])\n' "$slug" "$live_acs" >&2
exit 0
