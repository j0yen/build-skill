#!/usr/bin/env bash
# prd-slug-check.sh <slug> — the shared writer check every in-repo PRD
# writer calls before minting `build-queue/PRD-<slug>.md` (PRD-build-prd-
# slug-uniqueness, "weakest link 5"). A slug is used as a primary key
# across the manifest, claims, receipts, and test_prefix pairing, but
# nothing enforced that it names exactly one PRD -- gate-debt.sh and a
# hand-drafted /dream follow-on both minted `PRD-build-post-ship-reality-
# check.md` without either one knowing the other's copy existed.
#
# Usage:
#   prd-slug-check.sh <slug>
#
# Env:
#   PRD_DIR   PRD workspace root (default $HOME/Documents/PRDs).
#
# Exit 0, no stdout: the slug is free in build-queue/, built-prds/, AND
#   parked/ -- safe to write build-queue/PRD-<slug>.md.
# Exit 1, stdout names the existing location(s) and (when one can be found)
#   a free candidate slug: the slug is already taken by at least one file
#   anywhere in the corpus.
# Exit 2: usage error.
set -uo pipefail

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"

slug="${1:-}"
if [ -z "$slug" ]; then
  echo "usage: prd-slug-check.sh <slug>" >&2
  exit 2
fi
# Tolerate being handed a filename or a `PRD-`-prefixed slug by mistake.
slug="$(basename "$slug")"
slug="${slug#PRD-}"
slug="${slug%.md}"

fname="PRD-$slug.md"
existing=()
for d in build-queue built-prds parked; do
  p="$PRD_DIR/$d/$fname"
  [ -f "$p" ] && existing+=("$p")
done

if [ "${#existing[@]}" -eq 0 ]; then
  exit 0
fi

is_free() {
  local cand="$1" d
  for d in build-queue built-prds parked; do
    [ -f "$PRD_DIR/$d/PRD-$cand.md" ] && return 1
  done
  return 0
}

proposed=""
for cand in "${slug}-v2" "${slug}-v3" "${slug}-v4" "${slug}-followup"; do
  if is_free "$cand"; then
    proposed="$cand"
    break
  fi
done

echo "prd-slug-check: slug '$slug' is already taken: ${existing[*]}"
if [ -n "$proposed" ]; then
  echo "prd-slug-check: proposed free slug: $proposed"
else
  echo "prd-slug-check: no free suffix found among -v2/-v3/-v4/-followup; choose a new slug by hand"
fi
exit 1
