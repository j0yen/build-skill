#!/usr/bin/env bash
# secretcont_ac1_skill_doc_names_secrets_convention.sh —
# PRD-build-tenant-secret-continuity AC1: given SKILL.md's state-layout
# section, when read, then it names the state/secrets/<slug>/<name>.json
# runtime-secret convention (location, permissions, git-exclusion) as
# explicitly as it names state/prd-<slug>.lock.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"
GITIGNORE="$HERE/../.gitignore"

fails=0

check() { # $1=pattern $2=file $3=label
  if grep -qE "$1" "$2"; then
    echo "ok  SECRETCONT AC1: $3"
  else
    echo "FAIL SECRETCONT AC1: $3 (pattern not found: $1 in $2)"
    fails=$((fails + 1))
  fi
}

check '### Runtime secrets' "$SKILL_MD" "SKILL.md has a Runtime secrets section"
check 'state/secrets/<slug>/<name>\.json' "$SKILL_MD" "SKILL.md names the state/secrets/<slug>/<name>.json path"
check 'mode .?700' "$SKILL_MD" "SKILL.md names the 700 directory mode"
check 'mode .?600' "$SKILL_MD" "SKILL.md names the 600 file mode"
check 'Never git-tracked' "$SKILL_MD" "SKILL.md states secrets are never git-tracked"
check '^state/secrets/$' "$GITIGNORE" ".gitignore explicitly excludes state/secrets/"

if [ "$fails" -eq 0 ]; then
  echo "ok  SECRETCONT AC1: ALL PASS"
  exit 0
else
  echo "FAIL SECRETCONT AC1: $fails check(s) failed"
  exit 1
fi
