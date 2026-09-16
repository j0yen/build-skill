#!/usr/bin/env bash
# repo-health-seed-prd.sh — seed one fix PRD per (rule, repo, day)
# (PRD-build-repo-health-invariants requirement 5).
#
# Usage:
#   repo-health-seed-prd.sh <rule> <repo> <evidence-file>
#                            [--prd-dir <dir>] [--template <path>]
#
# Writes build-queue/PRD-<repo>-health-<rule>-<yyyymmdd>.md from
# templates/repo-health-fix.md with the evidence file's content inlined
# under `## Evidence`. Runs `scripts/prd-slug-check.sh` first — a taken
# slug (this rule already seeded one for this repo today, from a
# concurrent lane, or a human already drafted a same-named fix) is a
# silent skip (exit 0, journal line only), never an overwrite. The
# written file is validated with `scripts/prd-lint.sh` before being
# committed; a lint failure removes the file and exits 1 rather than
# leaving an unlintable PRD in build-queue/ (mirrors gate-debt.sh's own
# draft-then-lint-then-commit sequence).
#
# Commits + pushes the new file itself (same "durable the instant it's
# reached" convention as lane-claim.sh claim / mark-needs-classification.sh
# — SKILL.md Phase 3) with the Joe Yen identity.
#
# Exit: 0 seeded (or skipped: slug taken) | 1 lint failure | 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
TEMPLATE="${REPO_HEALTH_TEMPLATE:-$SKILL_DIR/templates/repo-health-fix.md}"
DECISIONS="${DECISIONS:-$HERE/decisions.sh}"
PRD_LINT="${PRD_LINT:-$HERE/prd-lint.sh}"
PRD_SLUG_CHECK="${PRD_SLUG_CHECK:-$HERE/prd-slug-check.sh}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

log() { printf 'repo-health-seed-prd: %s\n' "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

rule="${1:-}"; repo="${2:-}"; evidence_file="${3:-}"
[ -n "$rule" ] && [ -n "$repo" ] && [ -n "$evidence_file" ] || \
  die "usage: repo-health-seed-prd.sh <rule> <repo> <evidence-file> [--prd-dir <dir>] [--template <path>]" 2
shift 3

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prd-dir)  PRD_DIR="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

day="$(date -u +%Y%m%d)"
slug="${repo}-health-${rule}-${day}"
fname="PRD-${slug}.md"
dest="$PRD_DIR/build-queue/$fname"

if [ -x "$PRD_SLUG_CHECK" ]; then
  if ! PRD_DIR="$PRD_DIR" "$PRD_SLUG_CHECK" "$slug" >/tmp/repo-health-seed-slugcheck.$$ 2>&1; then
    log "slug already taken, skipping seed: $(cat /tmp/repo-health-seed-slugcheck.$$)"
    rm -f /tmp/repo-health-seed-slugcheck.$$
    journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $repo  seed-prd  skip-slug-taken  (rule=$rule slug=$slug)"
    exit 0
  fi
  rm -f /tmp/repo-health-seed-slugcheck.$$
elif [ -f "$dest" ]; then
  log "already exists, skipping seed: $dest"
  exit 0
fi

evidence_body="$(cat "$evidence_file" 2>/dev/null || echo "(evidence file unreadable: $evidence_file)")"

# PRD-build-open-decision-escalation requirement 8: fold this repo's open
# decisions into the seeded fix PRD's own Evidence section — a fix PRD
# blocked on an operator call should show the call right where the fix
# PRD is read, not force a second lookup.
if [ -x "$DECISIONS" ]; then
  dec_list="$("$DECISIONS" list --repo "$repo" 2>/dev/null || true)"
  if [ -n "$dec_list" ]; then
    evidence_body="$evidence_body

### Open decisions for $repo

$dec_list"
  fi
fi
grounding="repo-health rule=$rule repo=$repo fired $(date -u +%FT%TZ) — $(head -1 "$evidence_file" 2>/dev/null)"
build_into="$HOME/wintermute/$repo"

mkdir -p "$PRD_DIR/build-queue"
python3 - "$TEMPLATE" "$dest" "$slug" "$rule" "$repo" "$(date -u +%F)" "$grounding" "$evidence_body" "$build_into" <<'PYEOF'
import sys
template_path, dest, slug, rule, repo, date, grounding, evidence, build_into = sys.argv[1:10]
text = open(template_path).read()
text = (text.replace("{{SLUG}}", slug)
            .replace("{{TITLE}}", f"fix {rule} on {repo}")
            .replace("{{RULE}}", rule)
            .replace("{{REPO}}", repo)
            .replace("{{DATE}}", date)
            .replace("{{GROUNDING}}", grounding)
            .replace("{{EVIDENCE}}", evidence)
            .replace("{{BUILD_INTO}}", build_into))
open(dest, "w").write(text)
PYEOF

if ! "$PRD_LINT" "$dest" >/tmp/repo-health-seed-lint.$$.out 2>&1; then
  log "seeded PRD failed prd-lint.sh: $(cat /tmp/repo-health-seed-lint.$$.out)"
  rm -f "$dest" /tmp/repo-health-seed-lint.$$.out
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $repo  seed-prd  lint-failed  (rule=$rule slug=$slug)"
  exit 1
fi
rm -f /tmp/repo-health-seed-lint.$$.out

( cd "$PRD_DIR" \
  && git add "build-queue/$fname" \
  && git -c user.name="Joe Yen" -c user.email="jyen.tech@gmail.com" \
       commit -q -m "build: seed $fname (repo-health $rule on $repo)" \
  && git push -q origin HEAD 2>/tmp/repo-health-seed-push.$$.out ) \
  || log "seeded PRD written to $dest but commit/push failed (left in place for a retry): $(cat /tmp/repo-health-seed-push.$$.out 2>/dev/null)"
rm -f /tmp/repo-health-seed-push.$$.out

journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $repo  seed-prd  seeded  (rule=$rule slug=$slug)"
echo "$fname"
exit 0
