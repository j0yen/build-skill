#!/usr/bin/env bash
# opauth_ac1_contract_table_row.sh —
# PRD-build-operator-authorization-contract AC1.
#
# Given build-contract.md's frontmatter key table, When it is read, Then it
# lists `Operator-authorization` with its value shape, required column, and
# a one-line note that it is binding within scope and enforced by Dispatch
# + verdict-receipts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACT="$HERE/../build-contract.md"

row="$(grep -E '^\| `Operator-authorization`' "$CONTRACT")"
fail=0

[ -n "$row" ] && echo "ok  AC1: build-contract.md has an Operator-authorization row" \
  || { echo "FAIL: no Operator-authorization row in $CONTRACT" >&2; fail=1; }

grep -qF '<who> <ISO-8601 ts> "<verbatim words>" scope: <what it permits>' <<<"$row" \
  && echo "ok  AC1: row states the value shape" \
  || { echo "FAIL: row missing the documented value shape" >&2; fail=1; }

# required column is "no" (third pipe-delimited field: $1 empty, $2 key,
# $3 value shape, $4 required, $5 notes)
required_col="$(awk -F'|' '{print $4}' <<<"$row" | tr -d ' ')"
[ "$required_col" = "no" ] && echo "ok  AC1: required column = no" \
  || { echo "FAIL: required column = '$required_col' (want 'no')" >&2; fail=1; }

grep -qF 'binding within the stated scope only' <<<"$row" \
  && echo "ok  AC1: note states binding-within-scope" \
  || { echo "FAIL: note missing binding-within-scope language" >&2; fail=1; }

grep -qF 'injected verbatim into the branch-agent prompt by Dispatch' <<<"$row" \
  && echo "ok  AC1: note names Dispatch enforcement" \
  || { echo "FAIL: note missing Dispatch enforcement" >&2; fail=1; }

grep -qF 'checked by `verdict-receipts.sh`' <<<"$row" \
  && echo "ok  AC1: note names verdict-receipts enforcement" \
  || { echo "FAIL: note missing verdict-receipts enforcement" >&2; fail=1; }

exit $fail
