#!/usr/bin/env bash
# reviewer-misfile-digest.sh — PRD-build-gate-finalize-verdict-split P2
# requirement 8 (AC10): prints `reviewer-block-misfiled: <n>` over the
# last N days of journal, matching the PRD's primary success metric
# ("gates where a reviewer block is filed as infra:finalize-rejected
# while a valid block receipt exists"). Reads ONLY the journal (same
# convention as gate-phase-digest.sh — no receipts, which do not persist
# across a week).
#
# A misfile is two journal lines for the SAME repo within 60s of each
# other: one carrying `infra=reviewer-agent:finalize-rejected` (the gate
# summary line) and one carrying `reviewer-agent verdict=block` (run_
# reviewer()'s own line, which has no head= field to key on directly).
# extend-gate.sh's classify_finalize_exit (R1/R6) makes the two lines
# mutually exclusive for a single finalize call — a verdict exit returns
# before _mark_finalize_refusal ever runs, so _reviewer_infra_kind stays
# unset and the summary line never gets the finalize-rejected tag — so
# any nonzero count here, on journal dated after this PRD landed, is a
# classifier regression, not routine noise. n may be 0 (Joe,
# 2026-09-18T13:15Z iter_log: "a week of journal is the WINDOW the
# digest reads, not a wait").
#
# Usage: reviewer-misfile-digest.sh [--days N]
#
# Env overrides (test-only hooks; production defaults unchanged):
#   REVIEWER_MISFILE_DIGEST_JOURNAL_DIR  (<skill-dir's brain journal>, i.e.
#                                         $HOME/brain/journal/build)
#   REVIEWER_MISFILE_DIGEST_DAYS         (7)
#   REVIEWER_MISFILE_DIGEST_NOW          (date -u +%FT%TZ) — window's end
set -uo pipefail

JOURNAL_DIR="${REVIEWER_MISFILE_DIGEST_JOURNAL_DIR:-$HOME/brain/journal/build}"
days="${REVIEWER_MISFILE_DIGEST_DAYS:-7}"
now_iso="${REVIEWER_MISFILE_DIGEST_NOW:-$(date -u +%FT%TZ)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="${2:?reviewer-misfile-digest: --days needs a value}"; shift 2 ;;
    -h|--help) echo "usage: reviewer-misfile-digest.sh [--days N]"; exit 0 ;;
    *) echo "reviewer-misfile-digest: unknown argument: $1" >&2; exit 2 ;;
  esac
done

end_epoch="$(date -u -d "${now_iso}" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$now_iso" +%s 2>/dev/null)"
if [ -z "$end_epoch" ]; then
  echo "reviewer-misfile-digest: could not parse --now value '$now_iso'" >&2
  exit 2
fi

lines_file="$(mktemp "${TMPDIR:-/tmp}/reviewer-misfile-digest.XXXXXX")"
trap 'rm -f "$lines_file"' EXIT
: > "$lines_file"

i=$(( days - 1 ))
while [ "$i" -ge 0 ]; do
  d="$(date -u -d "@$(( end_epoch - i * 86400 ))" +%F 2>/dev/null || date -u -r "$(( end_epoch - i * 86400 ))" +%F 2>/dev/null)"
  f="$JOURNAL_DIR/$d.md"
  if [ -f "$f" ]; then
    grep -E '  gate  .*(infra=reviewer-agent:finalize-rejected|reviewer-agent verdict=block)' "$f" >> "$lines_file"
  fi
  i=$((i - 1))
done

if [ ! -s "$lines_file" ]; then
  echo "reviewer-block-misfiled: 0"
  exit 0
fi

python3 - "$lines_file" <<'PYEOF'
import re, sys
from datetime import datetime, timezone

path = sys.argv[1]
line_re = re.compile(r'^(\S+)\s+gate\s+(\S+)\s+')
PROXIMITY_S = 60

finalize_rejected = {}   # repo -> [epoch, ...]
verdict_block = {}       # repo -> [epoch, ...]

def parse_ts(ts):
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None

with open(path) as fh:
    for line in fh:
        m = line_re.match(line)
        if not m:
            continue
        ts, repo = m.group(1), m.group(2)
        epoch = parse_ts(ts)
        if epoch is None:
            continue
        if 'infra=reviewer-agent:finalize-rejected' in line:
            finalize_rejected.setdefault(repo, []).append(epoch)
        if 'reviewer-agent verdict=block' in line:
            verdict_block.setdefault(repo, []).append(epoch)

# Greedy nearest-match within PROXIMITY_S, per repo — each finalize-
# rejected reading pairs with at most one verdict=block reading and
# vice versa, so a repo with several unrelated gates in the window
# doesn't multiply-count one real pair.
misfiled = 0
for repo, fr_times in finalize_rejected.items():
    vb_times = list(verdict_block.get(repo, []))
    used = [False] * len(vb_times)
    for t in fr_times:
        best_i, best_d = None, None
        for i, vt in enumerate(vb_times):
            if used[i]:
                continue
            d = abs(vt - t)
            if d <= PROXIMITY_S and (best_d is None or d < best_d):
                best_i, best_d = i, d
        if best_i is not None:
            used[best_i] = True
            misfiled += 1

print('reviewer-block-misfiled: %d' % misfiled)
PYEOF
