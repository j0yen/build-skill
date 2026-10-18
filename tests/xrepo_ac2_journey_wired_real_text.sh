#!/usr/bin/env bash
# xrepo_ac2_journey_wired_real_text.sh — PRD-build-prd-lint-cross-repo-ac AC2.
#
# Given the real PRD text of journey-wired at 8ee67982 (AC 6 "When `synthorg
# mtproof` renders the digest") with build_into = a mcphost-deploy-shaped repo,
# When linted with the local fleet map, Then it fails naming AC 6 and
# `synthorg`; the same text with AC 6 removed is clean.
#
# Hermetic form: AC 6 is the verbatim line from that commit, the two repos are
# fixtures shaped like the real ones (synthorg: script `synthorg` + module
# src/synthorg/mtproof.py; mcphost-deploy: script `mcphost-deploy`). Set
# XREPO_PRDS_CLONE (a j0yen/PRDs clone), XREPO_SYNTHORG and XREPO_DEPLOY (real
# clones) to run the same assertions on the real artefacts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
SURF="$HERE/../scripts/repo-surface.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }
[ -x "$SURF" ] || { echo "FAIL: $SURF not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
export PRD_LINT_CACHE="$d/cache"
mkdir -p "$d/corpus/build-queue" "$d/corpus/built-prds" "$d/corpus/parked" "$d/corpus/visions"
echo "plain vision." > "$d/corpus/visions/plain.md"
q="$d/corpus/build-queue"

# Fixture repos: A (pyproject script alpha, module alpha/digest.py), B (script beta).
mkdir -p "$d/A/alpha" "$d/B/beta"
printf '[project.scripts]\nalpha = "alpha.cli:main"\n' > "$d/A/pyproject.toml"
: > "$d/A/alpha/__init__.py"; : > "$d/A/alpha/digest.py"
printf '[project.scripts]\nbeta = "beta.cli:main"\n' > "$d/B/pyproject.toml"
: > "$d/B/beta/__init__.py"
# The corpus names both repos as build_into (that is the fleet map).
printf -- '- Status: built\n- build_target: python-cli\n- build_into: %s\n- Vision: visions/plain.md\n' "$d/B" > "$d/corpus/built-prds/PRD-corpus-b.md"

# mkprd <file> <AC 2 body> [extra frontmatter...]
mkprd() {
  local f="$1" ac2="$2"; shift 2
  { printf -- '- Status: queued\n- build_target: python-cli\n- build_into: %s\n- Vision: visions/plain.md\n- Grounding: failure-derived (fixture)\n' "$d/A"
    for l in "$@"; do printf -- '%s\n' "$l"; done
    printf '\n## Acceptance criteria\n\n1. P0 — Given a fixture, When `alpha run` is invoked, Then it exits 0.\n2. P0 — %s\n' "$ac2"
  } > "$f"
}

AC6='6. P1 — Given a deploy journal newer than the last `tag=post-deploy` ledger row, When `synthorg mtproof` renders the digest, Then it prints `post-deploy journey NOT RUN for <version>` instead of `n/a`.'
mkdir -p "$d/syn/src/synthorg" "$d/dep/src/mcphost_deploy"
printf '[project.scripts]\nsynthorg = "synthorg.cli:main"\n' > "$d/syn/pyproject.toml"
: > "$d/syn/src/synthorg/__init__.py"; : > "$d/syn/src/synthorg/mtproof.py"
printf '[project.scripts]\nmcphost-deploy = "mcphost_deploy.cli:app"\n' > "$d/dep/pyproject.toml"
: > "$d/dep/src/mcphost_deploy/__init__.py"; : > "$d/dep/src/mcphost_deploy/redeploy.py"
SYN="$d/syn"; DEP="$d/dep"; PRD_TEXT=""
if [ -n "${XREPO_PRDS_CLONE:-}" ] && [ -d "${XREPO_SYNTHORG:-}" ] && [ -d "${XREPO_DEPLOY:-}" ]; then
  SYN="$XREPO_SYNTHORG"; DEP="$XREPO_DEPLOY"
  PRD_TEXT="$(git -C "$XREPO_PRDS_CLONE" show 8ee67982:build-queue/PRD-mcphost-deploy-postdeploy-journey-wired.md)"
  git -C "$XREPO_PRDS_CLONE" show 8ee67982:visions/discovery-chain-nominal.md > "$d/corpus/visions/discovery-chain-nominal.md"
  git -C "$XREPO_PRDS_CLONE" show 8ee67982:built-prds/PRD-synthorg-journey-postdeploy-field-contract.md > "$d/corpus/built-prds/PRD-synthorg-journey-postdeploy-field-contract.md"
  echo "(real artefacts: $XREPO_PRDS_CLONE @ 8ee67982, $SYN, $DEP)"
fi
printf -- '- Status: built\n- build_target: python-cli\n- build_into: %s\n- Vision: visions/plain.md\n' "$SYN" > "$d/corpus/built-prds/PRD-corpus-synthorg.md"
if [ -z "$PRD_TEXT" ]; then
  PRD_TEXT="$(printf -- '- Status: blocked\n- build_target: python-cli\n- build_into: /x\n- Vision: visions/plain.md\n- Grounding: grounded\n\n## Acceptance criteria\n\n1. P0 — Given a fixture shim, When `redeploy` succeeds, Then the unit starts.\n%s\n' "$AC6")"
fi
f="$q/PRD-mcphost-deploy-postdeploy-journey-wired.md"
printf '%s\n' "$PRD_TEXT" | sed "s#^- build_into: .*#- build_into: $DEP#" > "$f"
out="$("$LINT" --format pass-fail "$f" 2>&1)"; rc=$?
expect "AC2: real AC 6 text fails ac-names-foreign-surface" "[ $rc -eq 1 ] && grep -q 'ac-names-foreign-surface' <<<\"\$out\""
expect "AC2: names AC 6" "grep -q 'AC 6 names' <<<\"\$out\""
expect "AC2: names synthorg" "grep -q \"'synthorg'\" <<<\"\$out\""
grep -v '^6\. P1 ' "$f" > "$f.new" && mv "$f.new" "$f"
out="$("$LINT" --format pass-fail "$f" 2>&1)"; rc=$?
expect "AC2: same text with AC 6 removed -> no foreign-surface finding" "! grep -q 'ac-names-foreign-surface' <<<\"\$out\""
expect "AC2: ... and exit 0" "[ $rc -eq 0 ]"

exit $fail
