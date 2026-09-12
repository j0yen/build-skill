#!/usr/bin/env bash
# gate-phase-digest.sh — per-repo median/last gate phase seconds over the
# last N days (PRD-build-gate-phase-timing P1 requirement). Reads ONLY the
# journal (never receipts, so a repo with no last-verdict.json — a fresh
# clone, a repo the current box never gated — still shows, as long as
# SOME box journaled a gate for it in the window; Technical
# considerations: "Digest reads the journal, not receipts").
#
# Usage: gate-phase-digest.sh [--days N]
#
# For every repo (crate name — extend-gate.sh's journal line's 3rd field)
# with at least one `  gate  ...  phases=...` line in the window, prints:
#   gate phases (median, last): ci-checks 400/410 · gate 1500/1490 · ...
# one line per repo, phases in the order first seen for that repo (stable,
# not sorted — a rename or new step just appends, never reshuffles).
# `skip` readings are excluded from both stats (no time spent, not a data
# point); a `<name>:<s>!` failed reading's seconds still count (time WAS
# spent) — same convention extend-gate.sh's own 5%-tolerance sum uses.
# A repo whose entire window is `skip` for a given phase omits that phase
# from its line rather than printing a false 0/0.
#
# Median of an even-sized sample is the plain average of the two middle
# values (standard definition — this is a reporting aid, not a stats
# library). "last" is the most recent (by journal order, which is already
# chronological — files are named by UTC date and lines are appended)
# reading for that phase, independent of whether the median sample
# excludes anything (a `skip` still updates recency to "no reading here",
# i.e. `last` also skips a skip and keeps the most recent NON-skip value).
#
# Env overrides (test-only hooks; production defaults unchanged):
#   GATE_PHASE_DIGEST_JOURNAL_DIR   (<skill-dir's brain journal>, i.e.
#                                    $HOME/brain/journal/build)
#   GATE_PHASE_DIGEST_DAYS          (7)
#   GATE_PHASE_DIGEST_NOW           (date -u +%FT%TZ) — the window's end
#                                    date; overridable so a fixture journal
#                                    dated in the past is still "recent"
#                                    from the test's point of view.
set -uo pipefail

JOURNAL_DIR="${GATE_PHASE_DIGEST_JOURNAL_DIR:-$HOME/brain/journal/build}"
days="${GATE_PHASE_DIGEST_DAYS:-7}"
now_iso="${GATE_PHASE_DIGEST_NOW:-$(date -u +%FT%TZ)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="${2:?gate-phase-digest: --days needs a value}"; shift 2 ;;
    -h|--help) echo "usage: gate-phase-digest.sh [--days N]"; exit 0 ;;
    *) echo "gate-phase-digest: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Collect journal lines from every date file in the window that exists —
# a missing day (box was off, or predates the window) is silently skipped,
# never an error (Migration note: "a repo with no receipts still shows",
# same spirit for a quiet day).
lines_file="$(mktemp "${TMPDIR:-/tmp}/gate-phase-digest.XXXXXX")"
trap 'rm -f "$lines_file"' EXIT
end_epoch="$(date -u -d "${now_iso}" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$now_iso" +%s 2>/dev/null)"
if [ -z "$end_epoch" ]; then
  echo "gate-phase-digest: could not parse --now value '$now_iso'" >&2
  exit 2
fi
: > "$lines_file"
# Oldest day first, today last, so the digest's own line-order-is-
# chronological assumption (used below to pick "last") holds — appending
# newest-first would make an EARLIER day's last line outrank a LATER day's
# in the max-index "most recent reading" comparison.
i=$(( days - 1 ))
while [ "$i" -ge 0 ]; do
  d="$(date -u -d "@$(( end_epoch - i * 86400 ))" +%F 2>/dev/null || date -u -r "$(( end_epoch - i * 86400 ))" +%F 2>/dev/null)"
  f="$JOURNAL_DIR/$d.md"
  if [ -f "$f" ]; then
    grep -E '  gate  .*phases=' "$f" | grep -v '  gate  route-mismatch  ' >> "$lines_file"
  fi
  i=$((i - 1))
done

if [ ! -s "$lines_file" ]; then
  exit 0
fi

python3 - "$lines_file" <<'PYEOF'
import re, sys, statistics

path = sys.argv[1]
line_re = re.compile(r'^\S+\s+gate\s+(\S+)\s+\S+\s+\(.*?\bphases=([^\s)]+)')

# repo -> phase -> list of (order_index, seconds_int_or_None_if_skip)
repos = {}
order_of_phase = {}  # repo -> [phase names in first-seen order]
idx = 0
with open(path) as fh:
    for raw in fh:
        m = line_re.match(raw)
        if not m:
            continue
        repo, phases_blob = m.group(1), m.group(2)
        repo_phases = repos.setdefault(repo, {})
        repo_order = order_of_phase.setdefault(repo, [])
        for tok in phases_blob.split(','):
            if ':' not in tok:
                continue
            name, val = tok.split(':', 1)
            if name not in repo_phases:
                repo_phases[name] = []
                repo_order.append(name)
            if val == 'skip':
                continue
            val = val[:-1] if val.endswith('!') else val
            try:
                seconds = int(val)
            except ValueError:
                continue
            repo_phases[name].append((idx, seconds))
        idx += 1

for repo in sorted(repos):
    parts = []
    for name in order_of_phase[repo]:
        readings = repos[repo][name]
        if not readings:
            continue
        values = [s for _, s in readings]
        med = statistics.median(values)
        med_str = ('%d' % med) if med == int(med) else ('%.1f' % med)
        last = max(readings, key=lambda t: t[0])[1]
        parts.append('%s %s/%d' % (name, med_str, last))
    if parts:
        print('gate phases (median, last): %s · %s' % (repo, ' · '.join(parts)))
PYEOF
